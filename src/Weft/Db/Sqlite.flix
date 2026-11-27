pub mod Weft.Db.Sqlite {
    use Weft.Db
    use Weft.Db.ConnectionPool
    use Weft.Db.Jdbc
    use Weft.Db.PoolConfig
    use Weft.Db.PoolStats
    use Weft.Db.SqliteConfig
    use Weft.Db.SqliteDb
    use Weft.DbError
    use Weft.DbErrorKind

    import java.lang.Exception
    import java.sql.Connection
    import java.sql.SQLException
    import java.util.Properties
    import java.util.concurrent.locks.ReentrantLock
    import org.sqlite.JDBC

    ///
    /// Opens a SQLite database connection and applies configured PRAGMAs
    /// (`foreign_keys`, `busy_timeout`, and optionally `journal_mode = WAL`).
    ///
    /// For file-backed WAL databases with `readPoolSize > 0`, also opens a concurrent
    /// read-only `ConnectionPool` (`PRAGMA query_only = ON`) so concurrent virtual threads
    /// run `SELECT` queries in parallel without blocking on the writer lock.
    ///
    pub def open(cfg: SqliteConfig): Result[String, SqliteDb] \ IO = {
        let SqliteConfig.SqliteConfig(c) = cfg;
        match openRawConnection(c#jdbcUrl, c#foreignKeys, c#busyTimeoutMs, c#walMode, false) {
            case Err(msg) => Err(msg)
            case Ok(writerConn) =>
                let isMemory = String.contains({substr = ":memory:"}, c#jdbcUrl);
                if (c#walMode and c#readPoolSize > 0 and not isMemory) {
                    let poolCfg = PoolConfig.make(c#readPoolSize)
                        |> PoolConfig.withMinIdle(Int32.min(2, c#readPoolSize))
                        |> PoolConfig.withValidationTimeoutSec(0);
                    match ConnectionPool.open(poolCfg, () ->
                        openRawConnection(c#jdbcUrl, c#foreignKeys, c#busyTimeoutMs, false, true)
                    ) {
                        case Ok(readerPool) =>
                            Ok(SqliteDb.SqliteDb(new ReentrantLock(), writerConn, Ref.fresh(Static, 0), Some(readerPool)))
                        case Err(poolErr) =>
                            safeCloseConn(writerConn);
                            Err("Failed to initialize SQLite WAL reader pool: ${poolErr}")
                    }
                } else {
                    Ok(SqliteDb.SqliteDb(new ReentrantLock(), writerConn, Ref.fresh(Static, 0), None))
                }
        }
    }

    ///
    /// Closes the SQLite writer connection and any WAL reader connection pool.
    ///
    pub def close(db: SqliteDb): Unit \ IO = {
        let SqliteDb.SqliteDb(lock, conn, _, readerPoolOpt) = db;
        match readerPoolOpt {
            case Some(rp) => ConnectionPool.close(rp)
            case None     => ()
        };
        lock.lock();
        try {
            if (not conn.isClosed()) {
                conn.close()
            } else ();
            lock.unlock()
        } catch {
            case _: Exception => lock.unlock()
        }
    }

    ///
    /// Returns live statistics for the WAL concurrent reader pool, if enabled.
    ///
    pub def readerPoolStats(db: SqliteDb): Option[PoolStats] \ IO = {
        let SqliteDb.SqliteDb(_, _, _, readerPoolOpt) = db;
        Option.map(ConnectionPool.stats, readerPoolOpt)
    }

    ///
    /// Executes a lightweight `SELECT 1` liveness check against `db`.
    ///
    pub def ping(db: SqliteDb): Result[String, Unit] \ IO = {
        let res = run {
            let _ = Db.querySql("SELECT 1");
            ()
        } with runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(())         => Ok(())
            case Err((_, msg))  => Err(msg)
        }
    }

    ///
    /// Opens a SQLite database, executes `f` with the `Db` effect handled by SQLite,
    /// and ensures connections are closed afterward (even on `DbError`).
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
    /// Handles the `Db` effect against the given `SqliteDb`.
    ///
    /// - Writes and transactions serialize safely on the dedicated writer connection
    ///   with nested `SAVEPOINT` support.
    /// - Outside a transaction, `queryRows` runs concurrently on the WAL reader pool
    ///   (when enabled) without waiting for the writer lock.
    /// - Inside a transaction, `queryRows` automatically routes to the pinned writer
    ///   connection so reads observe uncommitted writes within the same transaction.
    ///
    pub def runWith(db: SqliteDb, f: Unit -> a \ ef): a \ (ef - Db) + IO = {
        let SqliteDb.SqliteDb(lock, conn, txDepth, readerPoolOpt) = db;
        region rc {
            let inTx = Ref.fresh(rc, false);
            run {
                f()
            } with handler Db {
                def rawQueryRows(sql, params, k) = {
                    let res = match (Ref.get(inTx), readerPoolOpt) {
                        case (false, Some(rp)) =>
                            ConnectionPool.withConnection(rp, rConn -> Jdbc.doQuery(true, rConn, sql, params))
                        case _ =>
                            execLocked(lock, () -> Jdbc.doQuery(true, conn, sql, params))
                    };
                    k(res)
                }

                def rawExecute(sql, params, k) =
                    k(execLocked(lock, () -> Jdbc.doExecute(true, conn, sql, params)))

                def rawInsertAndGetId(sql, params, k) =
                    k(execLocked(lock, () -> Jdbc.doInsertAndGetIdSqlite(conn, sql, params)))

                def rawBeginTx(k) = {
                    lock.lock();
                    let depth = Ref.get(txDepth);
                    let beginRes = try {
                        if (depth == 0) {
                            conn.setAutoCommit(false);
                            Ref.put(1, txDepth);
                            Ref.put(true, inTx);
                            Ok(())
                        } else {
                            Jdbc.execRaw(conn, "SAVEPOINT _weft_sp_${depth}");
                            Ref.put(depth + 1, txDepth);
                            Ref.put(true, inTx);
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
                            Ref.put(false, inTx);
                            lock.unlock();
                            Ok(())
                        } else {
                            let spLevel = depth - 1;
                            Jdbc.execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                            Ref.put(spLevel, txDepth);
                            lock.unlock();
                            Ok(())
                        }
                    } catch {
                        case ex: SQLException =>
                            if (depth <= 1) {
                                Jdbc.safeRestoreAutoCommit(conn);
                                Ref.put(0, txDepth);
                                Ref.put(false, inTx)
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
                            Ref.put(false, inTx);
                            lock.unlock()
                        } else {
                            let spLevel = depth - 1;
                            Jdbc.execRaw(conn, "ROLLBACK TO SAVEPOINT _weft_sp_${spLevel}");
                            Jdbc.execRaw(conn, "RELEASE SAVEPOINT _weft_sp_${spLevel}");
                            Ref.put(spLevel, txDepth);
                            lock.unlock()
                        }
                    } catch {
                        case _: Exception =>
                            if (depth <= 1) {
                                Jdbc.safeRestoreAutoCommit(conn);
                                Ref.put(0, txDepth);
                                Ref.put(false, inTx)
                            } else {
                                Ref.put(depth - 1, txDepth)
                            };
                            lock.unlock()
                    };
                    k()
                }
            }
        }
    }

    // --- Internal Helpers ---

    def openRawConnection(
        jdbcUrl: String,
        foreignKeys: Bool,
        busyTimeoutMs: Int32,
        enableWal: Bool,
        queryOnly: Bool
    ): Result[String, Connection] \ IO =
        try {
            let driver = new JDBC();
            let conn = driver.connect(jdbcUrl, new Properties());
            if (Object.isNull(conn)) {
                Err("Invalid SQLite JDBC URL: ${jdbcUrl}")
            } else {
                let stmt = conn.createStatement();
                try {
                    if (foreignKeys) {
                        let _ = stmt.execute("PRAGMA foreign_keys = ON");
                        ()
                    } else ();
                    if (busyTimeoutMs > 0) {
                        let _ = stmt.execute("PRAGMA busy_timeout = ${busyTimeoutMs}");
                        ()
                    } else ();
                    if (enableWal) {
                        let _ = stmt.execute("PRAGMA journal_mode = WAL");
                        ()
                    } else ();
                    if (queryOnly) {
                        let _ = stmt.execute("PRAGMA query_only = ON");
                        ()
                    } else ();
                    Jdbc.safeCloseStmt(stmt);
                    Ok(conn)
                } catch {
                    case ex: SQLException =>
                        Jdbc.safeCloseStmt(stmt);
                        safeCloseConn(conn);
                        Err("Failed to configure SQLite PRAGMAs (${jdbcUrl}): ${ex.getMessage()}")
                }
            }
        } catch {
            case ex: SQLException => Err("Failed to open SQLite database (${jdbcUrl}): ${ex.getMessage()}")
        }

    def safeCloseConn(conn: Connection): Unit \ IO =
        try {
            if (not conn.isClosed()) conn.close() else ()
        } catch {
            case _: Exception => ()
        }

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

}
