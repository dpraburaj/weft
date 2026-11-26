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
                stmt.close();
                Ok(SqliteDb.SqliteDb(new ReentrantLock(), conn))
            }
        } catch {
            case ex: SQLException => Err("Failed to open SQLite database (${c#jdbcUrl}): ${ex.getMessage()}")
        }

    ///
    /// Closes the underlying SQLite JDBC connection.
    ///
    pub def close(db: SqliteDb): Unit \ IO =
        let SqliteDb.SqliteDb(lock, conn) = db;
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
    /// and ensures the connection is closed afterward.
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
    /// All operations are serialized safely via the connection's `ReentrantLock`,
    /// and SQLite `SQLException`s are surfaced via the `DbError` algebraic effect.
    ///
    pub def runWith(db: SqliteDb, f: Unit -> a \ ef): a \ (ef - Db) + {DbError, IO} =
        let SqliteDb.SqliteDb(lock, conn) = db;
        run {
            f()
        } with handler Db {
            def queryRows(sql, params, k) =
                match execLocked(lock, () -> doQuery(conn, sql, params)) {
                    case Ok(rows)      => k(rows)
                    case Err((kd, m))  => DbError.raise(kd, m)
                }

            def execute(sql, params, k) =
                match execLocked(lock, () -> doExecute(conn, sql, params)) {
                    case Ok(count)     => k(count)
                    case Err((kd, m))  => DbError.raise(kd, m)
                }

            def insertAndGetId(sql, params, k) =
                match execLocked(lock, () -> doInsertAndGetId(conn, sql, params)) {
                    case Ok(id)        => k(id)
                    case Err((kd, m))  => DbError.raise(kd, m)
                }

            def beginTx(k) = {
                lock.lock();
                let beginRes = try {
                    conn.setAutoCommit(false);
                    Ok(())
                } catch {
                    case ex: SQLException =>
                        lock.unlock();
                        Err(ex.getMessage())
                };
                match beginRes {
                    case Ok(())   => k()
                    case Err(msg) => DbError.raise(DbErrorKind.TransactionFailed, "Failed to begin transaction: ${msg}")
                }
            }

            def commitTx(k) = {
                let commitRes = try {
                    conn.commit();
                    conn.setAutoCommit(true);
                    lock.unlock();
                    Ok(())
                } catch {
                    case ex: SQLException =>
                        safeRestoreAutoCommit(conn);
                        lock.unlock();
                        Err(ex.getMessage())
                };
                match commitRes {
                    case Ok(())   => k()
                    case Err(msg) => DbError.raise(DbErrorKind.TransactionFailed, "Failed to commit transaction: ${msg}")
                }
            }

            def rollbackTx(k) = {
                try {
                    conn.rollback();
                    conn.setAutoCommit(true);
                    lock.unlock()
                } catch {
                    case _: Exception =>
                        safeRestoreAutoCommit(conn);
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

    def safeRestoreAutoCommit(conn: Connection): Unit \ IO =
        try {
            conn.setAutoCommit(true)
        } catch {
            case _: Exception => ()
        }

    def doQuery(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), List[Row]] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            bindParams(ps, params);
            let rs = ps.executeQuery();
            let rows = readAllRows(rs);
            rs.close();
            ps.close();
            Ok(rows)
        } catch {
            case ex: SQLException => Err(classifySqlException(ex))
        }

    def doExecute(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int32] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            bindParams(ps, params);
            let affected = ps.executeUpdate();
            ps.close();
            Ok(affected)
        } catch {
            case ex: SQLException => Err(classifySqlException(ex))
        }

    def doInsertAndGetId(conn: Connection, sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int64] \ IO =
        try {
            let ps = conn.prepareStatement(sql);
            bindParams(ps, params);
            let _ = ps.executeUpdate();
            ps.close();
            let idStmt = conn.createStatement();
            let rs = idStmt.executeQuery("SELECT last_insert_rowid()");
            let id = if (rs.next()) rs.getLong(1) else 0i64;
            rs.close();
            idStmt.close();
            Ok(id)
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
