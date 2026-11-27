pub mod Weft.Db.Jdbc {
    use Weft.Db
    use Weft.Db.ConnectionPool
    use Weft.DbErrorKind
    use Weft.Row
    use Weft.SqlValue

    import java.lang.Exception
    import java.sql.Connection
    import java.sql.PreparedStatement
    import java.sql.ResultSet
    import java.sql.ResultSetMetaData
    import java.sql.SQLException
    import java.sql.Statement
    import java.sql.Types

    ///
    /// Shared, driver-agnostic JDBC execution engine powering `Weft.Db.Sqlite`,
    /// `Weft.Db.Postgres`, and any custom pooled JDBC backend.
    ///
    /// Executes parameterized queries, updates, `INSERT` key retrieval, nested savepoint
    /// transactions with per-fiber connection pinning, and SQLSTATE error classification.
    ///

    ///
    /// Runs `f` with the `Weft.Db` effect handled by a pooled JDBC `ConnectionPool`.
    ///
    /// - Outside a transaction, every query/statement borrows a connection from `pool`,
    ///   executes in parallel with other virtual threads, and immediately returns it.
    /// - Inside `Db.transaction` / `Db.transactionHttp`, a dedicated connection is pinned
    ///   to the current execution scope for the duration of the transaction (with nested
    ///   `SAVEPOINT`s), and guaranteed to roll back and return to the pool even on abnormal exit.
    ///
    def runOnConn(
        pool: ConnectionPool,
        pinnedConn: Ref[Option[Connection], r],
        action: Connection -> Result[(DbErrorKind, String), b] \ IO
    ): Result[(DbErrorKind, String), b] \ {r, IO} =
        match Ref.get(pinnedConn) {
            case Some(conn) => action(conn)
            case None       => ConnectionPool.withConnection(pool, action)
        }

    pub def runPooledDb(
        boolAsInt: Bool,
        insertFn: (Connection, String, List[SqlValue]) -> Result[(DbErrorKind, String), Int64] \ IO,
        pool: ConnectionPool,
        f: Unit -> a \ ef
    ): a \ (ef - Db) + IO =
        region rc {
            let pinnedConn: Ref[Option[Connection], rc] = Ref.fresh(rc, None);
            let txDepth: Ref[Int32, rc] = Ref.fresh(rc, 0);

            def cleanupLeakedTx(): Unit \ {rc, IO} =
                match Ref.get(pinnedConn) {
                    case None => ()
                    case Some(conn) =>
                        Ref.put(None, pinnedConn);
                        Ref.put(0, txDepth);
                        try {
                            conn.rollback();
                            conn.setAutoCommit(true);
                            ConnectionPool.release(pool, conn)
                        } catch {
                            case _: Exception =>
                                ConnectionPool.evict(pool, conn)
                        }
                };

            let result = try {
                let out = run {
                    f()
                } with handler Db {
                    def rawQueryRows(sql, params, k) =
                        k(runOnConn(pool, pinnedConn, conn -> doQuery(boolAsInt, conn, sql, params)))

                    def rawExecute(sql, params, k) =
                        k(runOnConn(pool, pinnedConn, conn -> doExecute(boolAsInt, conn, sql, params)))

                    def rawInsertAndGetId(sql, params, k) =
                        k(runOnConn(pool, pinnedConn, conn -> insertFn(conn, sql, params)))

                    def rawBeginTx(k) = {
                        let depth = Ref.get(txDepth);
                        let res = if (depth == 0) {
                            match ConnectionPool.borrow(pool) {
                                case Err(e) => Err(e)
                                case Ok(conn) =>
                                    try {
                                        conn.setAutoCommit(false);
                                        Ref.put(Some(conn), pinnedConn);
                                        Ref.put(1, txDepth);
                                        Ok(())
                                    } catch {
                                        case ex: SQLException =>
                                            ConnectionPool.evict(pool, conn);
                                            Err((DbErrorKind.TransactionFailed, "Failed to begin transaction: ${ex.getMessage()}"))
                                    }
                            }
                        } else {
                            match Ref.get(pinnedConn) {
                                case None =>
                                    Err((DbErrorKind.TransactionFailed, "Nested transaction missing pinned connection"))
                                case Some(conn) =>
                                    try {
                                        execRaw(conn, "SAVEPOINT _weft_sp_${depth}");
                                        Ref.put(depth + 1, txDepth);
                                        Ok(())
                                    } catch {
                                        case ex: SQLException =>
                                            Err((DbErrorKind.TransactionFailed, "Failed to create savepoint: ${ex.getMessage()}"))
                                    }
                            }
                        };
                        k(res)
                    }

                    def rawCommitTx(k) = {
                        let depth = Ref.get(txDepth);
                        let res = match Ref.get(pinnedConn) {
                            case None =>
                                Err((DbErrorKind.TransactionFailed, "No active transaction to commit"))
                            case Some(conn) =>
                                try {
                                    if (depth <= 1) {
                                        conn.commit();
                                        conn.setAutoCommit(true);
                                        Ref.put(None, pinnedConn);
                                        Ref.put(0, txDepth);
                                        ConnectionPool.release(pool, conn);
                                        Ok(())
                                    } else {
                                        let spLevel = depth - 1;
                                        execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                                        Ref.put(spLevel, txDepth);
                                        Ok(())
                                    }
                                } catch {
                                    case ex: SQLException =>
                                        if (depth <= 1) {
                                            Ref.put(None, pinnedConn);
                                            Ref.put(0, txDepth);
                                            ConnectionPool.evict(pool, conn)
                                        } else {
                                            Ref.put(depth - 1, txDepth)
                                        };
                                        Err((DbErrorKind.TransactionFailed, "Failed to commit transaction: ${ex.getMessage()}"))
                                }
                        };
                        k(res)
                    }

                    def rawRollbackTx(k) = {
                        let depth = Ref.get(txDepth);
                        match Ref.get(pinnedConn) {
                            case None => ()
                            case Some(conn) =>
                                try {
                                    if (depth <= 1) {
                                        conn.rollback();
                                        conn.setAutoCommit(true);
                                        Ref.put(None, pinnedConn);
                                        Ref.put(0, txDepth);
                                        ConnectionPool.release(pool, conn)
                                    } else {
                                        let spLevel = depth - 1;
                                        execRaw(conn, "ROLLBACK TO SAVEPOINT _weft_sp_${spLevel}");
                                        execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                                        Ref.put(spLevel, txDepth)
                                    }
                                } catch {
                                    case _: Exception =>
                                        if (depth <= 1) {
                                            Ref.put(None, pinnedConn);
                                            Ref.put(0, txDepth);
                                            ConnectionPool.evict(pool, conn)
                                        } else {
                                            Ref.put(depth - 1, txDepth)
                                        }
                                }
                        };
                        k()
                    }
                };
                cleanupLeakedTx();
                out
            } catch {
                case ex: Exception =>
                    cleanupLeakedTx();
                    throw ex
            };
            result
        }

    // --- Statement & Query Execution ---

    pub def doQuery(
        boolAsInt: Bool,
        conn: Connection,
        sql: String,
        params: List[SqlValue]
    ): Result[(DbErrorKind, String), List[Row]] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(boolAsInt, ps, params);
                let rs = ps.executeQuery();
                try {
                    let rows = readAllRows(rs);
                    safeCloseRs(rs);
                    safeClosePs(ps);
                    Ok(rows)
                } catch {
                    case ex: SQLException =>
                        safeCloseRs(rs);
                        safeClosePs(ps);
                        Err(classifySqlException(ex))
                }
            } catch {
                case ex: SQLException =>
                    safeClosePs(ps);
                    Err(classifySqlException(ex))
            }
        } catch {
            case ex: SQLException => Err(classifySqlException(ex))
        }

    pub def doExecute(
        boolAsInt: Bool,
        conn: Connection,
        sql: String,
        params: List[SqlValue]
    ): Result[(DbErrorKind, String), Int32] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(boolAsInt, ps, params);
                let affected = ps.executeUpdate();
                safeClosePs(ps);
                Ok(affected)
            } catch {
                case ex: SQLException =>
                    safeClosePs(ps);
                    Err(classifySqlException(ex))
            }
        } catch {
            case ex: SQLException => Err(classifySqlException(ex))
        }

    pub def doInsertAndGetIdSqlite(
        conn: Connection,
        sql: String,
        params: List[SqlValue]
    ): Result[(DbErrorKind, String), Int64] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(true, ps, params);
                let _ = ps.executeUpdate();
                safeClosePs(ps)
            } catch {
                case ex: SQLException =>
                    safeClosePs(ps);
                    throw ex
            };
            let idStmt = conn.createStatement();
            try {
                let rs = idStmt.executeQuery("SELECT last_insert_rowid()");
                try {
                    let id = if (rs.next()) rs.getLong(1) else 0i64;
                    safeCloseRs(rs);
                    safeCloseStmt(idStmt);
                    Ok(id)
                } catch {
                    case ex: SQLException =>
                        safeCloseRs(rs);
                        safeCloseStmt(idStmt);
                        Err(classifySqlException(ex))
                }
            } catch {
                case ex: SQLException =>
                    safeCloseStmt(idStmt);
                    Err(classifySqlException(ex))
            }
        } catch {
            case ex: SQLException => Err(classifySqlException(ex))
        }

    ///
    /// PostgreSQL `insertAndGetId`: supports both explicit `INSERT ... RETURNING id`
    /// statements (via `executeQuery`) and standard `INSERT INTO ...` statements
    /// (via `Statement.RETURN_GENERATED_KEYS` / `getGeneratedKeys`).
    ///
    pub def doInsertAndGetIdPostgres(
        conn: Connection,
        sql: String,
        params: List[SqlValue]
    ): Result[(DbErrorKind, String), Int64] \ IO = {
        let upper = String.toUpperCase(sql);
        let hasReturning = String.contains({substr = " RETURNING "}, upper) or
            String.contains({substr = "\nRETURNING "}, upper);
        if (hasReturning) {
            try {
                let ps = conn.prepareStatement(sql);
                try {
                    bindParams(false, ps, params);
                    let rs = ps.executeQuery();
                    try {
                        let id = if (rs.next()) rs.getLong(1) else 0i64;
                        safeCloseRs(rs);
                        safeClosePs(ps);
                        Ok(id)
                    } catch {
                        case ex: SQLException =>
                            safeCloseRs(rs);
                            safeClosePs(ps);
                            Err(classifySqlException(ex))
                    }
                } catch {
                    case ex: SQLException =>
                        safeClosePs(ps);
                        Err(classifySqlException(ex))
                }
            } catch {
                case ex: SQLException => Err(classifySqlException(ex))
            }
        } else {
            try {
                let ps = conn.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS);
                try {
                    bindParams(false, ps, params);
                    let _ = ps.executeUpdate();
                    let rs = ps.getGeneratedKeys();
                    try {
                        let id = if (rs.next()) rs.getLong(1) else 0i64;
                        safeCloseRs(rs);
                        safeClosePs(ps);
                        Ok(id)
                    } catch {
                        case ex: SQLException =>
                            safeCloseRs(rs);
                            safeClosePs(ps);
                            Err(classifySqlException(ex))
                    }
                } catch {
                    case ex: SQLException =>
                        safeClosePs(ps);
                        Err(classifySqlException(ex))
                }
            } catch {
                case ex: SQLException => Err(classifySqlException(ex))
            }
        }
    }

    pub def execRaw(conn: Connection, sql: String): Unit \ IO = {
        let stmt = conn.createStatement();
        try {
            let _ = stmt.execute(sql);
            safeCloseStmt(stmt)
        } catch {
            case ex: SQLException =>
                safeCloseStmt(stmt);
                throw ex
        }
    }

    pub def safeCloseStmt(stmt: Statement): Unit \ IO =
        try { stmt.close() } catch { case _: Exception => () }

    pub def safeClosePs(ps: PreparedStatement): Unit \ IO =
        try { ps.close() } catch { case _: Exception => () }

    pub def safeCloseRs(rs: ResultSet): Unit \ IO =
        try { rs.close() } catch { case _: Exception => () }

    pub def safeRestoreAutoCommit(conn: Connection): Unit \ IO =
        try { conn.setAutoCommit(true) } catch { case _: Exception => () }

    pub def bindParams(boolAsInt: Bool, ps: PreparedStatement, params: List[SqlValue]): Unit \ IO = {
        def loop(idx: Int32, rest: List[SqlValue]): Unit \ IO = match rest {
            case Nil => ()
            case v :: tl =>
                match v {
                    case SqlValue.SqlNull     => ps.setNull(idx, Types.NULL)
                    case SqlValue.SqlInt(i)   => ps.setInt(idx, i)
                    case SqlValue.SqlInt64(i) => ps.setLong(idx, i)
                    case SqlValue.SqlFloat(f) => ps.setDouble(idx, f)
                    case SqlValue.SqlText(s)  => ps.setString(idx, s)
                    case SqlValue.SqlBool(b)  =>
                        if (boolAsInt) ps.setInt(idx, if (b) 1 else 0) else ps.setBoolean(idx, b)
                    case SqlValue.SqlBlob(bs) => ps.setBytes(idx, Vector.toArray(Static, bs))
                };
                loop(idx + 1, tl)
        };
        loop(1, params)
    }

    pub def readAllRows(rs: ResultSet): List[Row] \ IO = {
        let meta = rs.getMetaData();
        let colCount = meta.getColumnCount();
        def loopRows(acc: List[Row]): List[Row] \ IO = {
            if (rs.next()) {
                let row = readSingleRow(rs, meta, colCount);
                loopRows(row :: acc)
            } else {
                List.reverse(acc)
            }
        };
        loopRows(Nil)
    }

    def readSingleRow(rs: ResultSet, meta: ResultSetMetaData, colCount: Int32): Row \ IO = {
        def loopCols(idx: Int32, acc: List[(String, SqlValue)]): List[(String, SqlValue)] \ IO = {
            if (idx > colCount)
                acc
            else {
                let colName = meta.getColumnLabel(idx);
                let obj = rs.getObject(idx);
                let sqlVal = if (Object.isNull(obj))
                    SqlValue.SqlNull
                else
                    match obj.getClass().getName() {
                        case "java.lang.Short"      => SqlValue.SqlInt(rs.getInt(idx))
                        case "java.lang.Integer"    => SqlValue.SqlInt(rs.getInt(idx))
                        case "java.lang.Long"       => SqlValue.SqlInt64(rs.getLong(idx))
                        case "java.lang.Double"     => SqlValue.SqlFloat(rs.getDouble(idx))
                        case "java.lang.Float"      => SqlValue.SqlFloat(rs.getDouble(idx))
                        case "java.math.BigDecimal" => SqlValue.SqlFloat(rs.getDouble(idx))
                        case "java.lang.Boolean"    => SqlValue.SqlBool(rs.getBoolean(idx))
                        case "[B"                   => SqlValue.SqlBlob(Array.toVector(rs.getBytes(idx)))
                        case _                      => SqlValue.SqlText(rs.getString(idx))
                    };
                loopCols(idx + 1, (colName, sqlVal) :: acc)
            }
        };
        Row.fromList(loopCols(1, Nil))
    }

    ///
    /// Classifies JDBC `SQLException`s using standard SQLSTATE codes (PostgreSQL, MySQL, etc.)
    /// with message fallback for SQLite.
    ///
    pub def classifySqlException(ex: SQLException): (DbErrorKind, String) = {
        let rawMsg = ex.getMessage();
        let msg = if (Object.isNull(rawMsg)) "SQL error" else rawMsg;
        let stateObj = unsafe IO { ex.getSQLState() };
        let state = if (Object.isNull(stateObj)) "" else stateObj;
        let upper = String.toUpperCase(msg);
        if (String.startsWith({prefix = "23"}, state) or String.contains({substr = "CONSTRAINT"}, upper))
            (DbErrorKind.ConstraintViolation, msg)
        else if (String.startsWith({prefix = "08"}, state))
            (DbErrorKind.ConnectionFailed, msg)
        else if (String.startsWith({prefix = "40"}, state))
            (DbErrorKind.TransactionFailed, msg)
        else
            (DbErrorKind.QueryFailed, msg)
    }

}
