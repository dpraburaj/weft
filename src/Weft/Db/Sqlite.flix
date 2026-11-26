pub mod Weft.Db.Sqlite {
    use Weft.Db
    use Weft.Db.SqliteConfig
    use Weft.Db.SqliteDb
    use Weft.DbError
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
    import java.util.Properties
    import java.util.concurrent.locks.ReentrantLock
    import org.sqlite.JDBC

    ///
    /// Opens a SQLite database connection and applies configured PRAGMAs
    /// (`foreign_keys`, `busy_timeout`, and optionally `journal_mode = WAL`).
    ///
    pub def open(cfg: SqliteConfig): Result[String, SqliteDb] \ IO =
        let SqliteConfig.SqliteConfig(c) = cfg;
        try {
            let driver = new JDBC();
            let conn = driver.connect(c#jdbcUrl, new Properties());
            if (Object.isNull(conn)) {
                Err("Invalid SQLite JDBC URL: ${c#jdbcUrl}")
            } else {
                let stmt = conn.createStatement();
                try {
                    if (c#foreignKeys) {
                        let _ = stmt.execute("PRAGMA foreign_keys = ON");
                        ()
                    } else ();
                    if (c#busyTimeoutMs > 0) {
                        let _ = stmt.execute("PRAGMA busy_timeout = ${c#busyTimeoutMs}");
                        ()
                    } else ();
                    if (c#walMode) {
                        let _ = stmt.execute("PRAGMA journal_mode = WAL");
                        ()
                    } else ();
                    safeCloseStmt(stmt);
                    Ok(SqliteDb.SqliteDb(new ReentrantLock(), conn, Ref.fresh(Static, 0)))
                } catch {
                    case ex: SQLException =>
                        safeCloseStmt(stmt);
                        Err("Failed to configure SQLite PRAGMAs (${c#jdbcUrl}): ${ex.getMessage()}")
                }
            }
        } catch {
            case ex: SQLException => Err("Failed to open SQLite database (${c#jdbcUrl}): ${ex.getMessage()}")
        }

    ///
    /// Closes the underlying SQLite JDBC connection.
    ///
    pub def close(db: SqliteDb): Unit \ IO =
        let SqliteDb.SqliteDb(lock, conn, _) = db;
        lock.lock();
        try {
            if (not conn.isClosed()) {
                conn.close()
            } else ();
            lock.unlock()
        } catch {
            case _: Exception => lock.unlock()
        }

    ///
    /// Opens a SQLite database, executes `f` with the `Db` effect handled by SQLite,
    /// and ensures the connection is closed afterward (even on `DbError`).
    ///
    pub def withDb(cfg: SqliteConfig, f: Unit -> a \ ef): Result[String, a] \ (ef - Db) + {DbError, IO} =
        match open(cfg) {
            case Err(msg) => Err(msg)
            case Ok(db) =>
                let res = run {
                    Ok(runWith(db, f))
                } with handler DbError {
                    def raise(kind, msg, _k) = {
                        close(db);
                        DbError.raise(kind, msg)
                    }
                };
                close(db);
                res
        }

    ///
    /// Handles the `Db` effect against the given `SqliteDb` connection.
    ///
    /// All operations are serialized safely via the connection's `ReentrantLock`.
    /// Nested `Db.transaction` / `Db.transactionHttp` calls use SQLite `SAVEPOINT`s
    /// so inner rollbacks isolate cleanly without aborting the outer transaction.
    ///
    pub def runWith(db: SqliteDb, f: Unit -> a \ ef): a \ (ef - Db) + IO =
        let SqliteDb.SqliteDb(lock, conn, txDepth) = db;
        run {
            f()
        } with handler Db {
            def rawQueryRows(sql, params, k) =
                k(execLocked(lock, () -> doQuery(conn, sql, params)))

            def rawExecute(sql, params, k) =
                k(execLocked(lock, () -> doExecute(conn, sql, params)))

            def rawInsertAndGetId(sql, params, k) =
                k(execLocked(lock, () -> doInsertAndGetId(conn, sql, params)))

            def rawBeginTx(k) = {
                lock.lock();
                let depth = Ref.get(txDepth);
                let beginRes = try {
                    if (depth == 0) {
                        conn.setAutoCommit(false);
                        Ref.put(1, txDepth);
                        Ok(())
                    } else {
                        execRaw(conn, "SAVEPOINT _weft_sp_${depth}");
                        Ref.put(depth + 1, txDepth);
                        Ok(())
                    }
                } catch {
                    case ex: SQLException =>
                        lock.unlock();
                        Err((DbErrorKind.TransactionFailed, "Failed to begin transaction: ${ex.getMessage()}"))
                };
                k(beginRes)
            }

            def rawCommitTx(k) = {
                let depth = Ref.get(txDepth);
                let commitRes = try {
                    if (depth <= 1) {
                        conn.commit();
                        conn.setAutoCommit(true);
                        Ref.put(0, txDepth);
                        lock.unlock();
                        Ok(())
                    } else {
                        let spLevel = depth - 1;
                        execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                        Ref.put(spLevel, txDepth);
                        lock.unlock();
                        Ok(())
                    }
                } catch {
                    case ex: SQLException =>
                        if (depth <= 1) {
                            safeRestoreAutoCommit(conn);
                            Ref.put(0, txDepth)
                        } else {
                            Ref.put(depth - 1, txDepth)
                        };
                        lock.unlock();
                        Err((DbErrorKind.TransactionFailed, "Failed to commit transaction: ${ex.getMessage()}"))
                };
                k(commitRes)
            }

            def rawRollbackTx(k) = {
                let depth = Ref.get(txDepth);
                try {
                    if (depth <= 1) {
                        conn.rollback();
                        conn.setAutoCommit(true);
                        Ref.put(0, txDepth);
                        lock.unlock()
                    } else {
                        let spLevel = depth - 1;
                        execRaw(conn, "ROLLBACK TO SAVEPOINT _weft_sp_${spLevel}");
                        execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                        Ref.put(spLevel, txDepth);
                        lock.unlock()
                    }
                } catch {
                    case _: Exception =>
                        if (depth <= 1) {
                            safeRestoreAutoCommit(conn);
                            Ref.put(0, txDepth)
                        } else {
                            Ref.put(depth - 1, txDepth)
                        };
                        lock.unlock()
                };
                k()
            }
        }

    // --- Internal JDBC Helpers ---

    def execLocked(lock: ReentrantLock, action: Unit -> Result[(DbErrorKind, String), a] \ IO): Result[(DbErrorKind, String), a] \ IO = {
        lock.lock();
        try {
            let r = action();
            lock.unlock();
            r
        } catch {
            case ex: Exception =>
                lock.unlock();
                Err((DbErrorKind.QueryFailed, ex.getMessage()))
        }
    }

    def execRaw(conn: Connection, sql: String): Unit \ IO = {
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

    def safeCloseStmt(stmt: Statement): Unit \ IO =
        try {
            stmt.close()
        } catch {
            case _: Exception => ()
        }

    def safeClosePs(ps: PreparedStatement): Unit \ IO =
        try {
            ps.close()
        } catch {
            case _: Exception => ()
        }

    def safeCloseRs(rs: ResultSet): Unit \ IO =
        try {
            rs.close()
        } catch {
            case _: Exception => ()
        }

    def safeRestoreAutoCommit(conn: Connection): Unit \ IO =
        try {
            conn.setAutoCommit(true)
        } catch {
            case _: Exception => ()
        }

    def doQuery(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), List[Row]] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(ps, params);
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

    def doExecute(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int32] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(ps, params);
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

    def doInsertAndGetId(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int64] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            try {
                bindParams(ps, params);
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

    def bindParams(ps: PreparedStatement, params: List[SqlValue]): Unit \ IO =
        def loop(idx: Int32, rest: List[SqlValue]): Unit \ IO = match rest {
            case Nil => ()
            case v :: tl =>
                match v {
                    case SqlValue.SqlNull     => ps.setNull(idx, Types.NULL)
                    case SqlValue.SqlInt(i)   => ps.setInt(idx, i)
                    case SqlValue.SqlInt64(i) => ps.setLong(idx, i)
                    case SqlValue.SqlFloat(f) => ps.setDouble(idx, f)
                    case SqlValue.SqlText(s)  => ps.setString(idx, s)
                    case SqlValue.SqlBool(b)  => ps.setInt(idx, if (b) 1 else 0)
                    case SqlValue.SqlBlob(bs) => ps.setBytes(idx, Vector.toArray(Static, bs))
                };
                loop(idx + 1, tl)
        };
        loop(1, params)

    def readAllRows(rs: ResultSet): List[Row] \ IO =
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

    def readSingleRow(rs: ResultSet, meta: ResultSetMetaData, colCount: Int32): Row \ IO =
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
                        case "java.lang.Integer" => SqlValue.SqlInt(rs.getInt(idx))
                        case "java.lang.Long"    => SqlValue.SqlInt64(rs.getLong(idx))
                        case "java.lang.Double"  => SqlValue.SqlFloat(rs.getDouble(idx))
                        case "java.lang.Float"   => SqlValue.SqlFloat(rs.getDouble(idx))
                        case "java.lang.Boolean" => SqlValue.SqlBool(rs.getBoolean(idx))
                        case "[B"                => SqlValue.SqlBlob(Array.toVector(rs.getBytes(idx)))
                        case _                   => SqlValue.SqlText(rs.getString(idx))
                    };
                loopCols(idx + 1, (colName, sqlVal) :: acc)
            }
        };
        Row.fromList(loopCols(1, Nil))

    def classifySqlException(ex: SQLException): (DbErrorKind, String) =
        let rawMsg = ex.getMessage();
        let msg = if (Object.isNull(rawMsg)) "SQLite error" else rawMsg;
        let upper = String.toUpperCase(msg);
        if (String.contains({substr = "CONSTRAINT"}, upper))
            (DbErrorKind.ConstraintViolation, msg)
        else
            (DbErrorKind.QueryFailed, msg)

}
