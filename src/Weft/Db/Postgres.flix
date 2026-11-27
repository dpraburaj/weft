pub mod Weft.Db.Postgres {
    use Weft.Db
    use Weft.Db.ConnectionPool
    use Weft.Db.Jdbc
    use Weft.Db.PoolStats
    use Weft.Db.PostgresConfig
    use Weft.Db.PostgresDb
    use Weft.DbError

    import java.sql.Connection
    import java.sql.SQLException
    import java.util.Properties
    import org.postgresql.Driver

    ///
    /// Opens a pooled PostgreSQL database using `org.postgresql.Driver` and
    /// `Weft.Db.ConnectionPool` (pre-warming `PoolConfig.minIdle` connections).
    ///
    pub def open(cfg: PostgresConfig): Result[String, PostgresDb] \ IO = {
        let PostgresConfig.PostgresConfig(c) = cfg;
        match ConnectionPool.open(c#poolConfig, () -> openRawConnection(cfg)) {
            case Err(msg) => Err(msg)
            case Ok(pool) => Ok(PostgresDb.PostgresDb(pool, c#jdbcUrl))
        }
    }

    ///
    /// Closes the PostgreSQL connection pool and all idle connections.
    ///
    pub def close(db: PostgresDb): Unit \ IO = {
        let PostgresDb.PostgresDb(pool, _) = db;
        ConnectionPool.close(pool)
    }

    ///
    /// Returns live pool utilization statistics (`active`, `idle`, `max`, `totalCreated`).
    ///
    pub def stats(db: PostgresDb): PoolStats \ IO = {
        let PostgresDb.PostgresDb(pool, _) = db;
        ConnectionPool.stats(pool)
    }

    ///
    /// Executes a lightweight `SELECT 1` liveness check against the PostgreSQL pool
    /// (ideal for `/readyz` health endpoints).
    ///
    pub def ping(db: PostgresDb): Result[String, Unit] \ IO = {
        let res = run {
            let _ = Db.querySql("SELECT 1");
            ()
        } with runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(())        => Ok(())
            case Err((_, msg)) => Err(msg)
        }
    }

    ///
    /// Opens a pooled PostgreSQL connection, executes `f` with the `Db` effect handled by
    /// PostgreSQL, and guarantees the pool is closed afterward (even on `DbError`).
    ///
    pub def withDb(cfg: PostgresConfig, f: Unit -> a \ ef): Result[String, a] \ (ef - Db) + {DbError, IO} =
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
    /// Handles the driver-agnostic `Weft.Db` effect against a pooled `PostgresDb`.
    ///
    /// - Queries and writes outside transactions run concurrently across pooled connections.
    /// - `Db.transaction` / `Db.transactionHttp` pin a single connection for the duration of
    ///   the transaction, support nested `SAVEPOINT`s, and automatically roll back and return
    ///   the connection on error or abnormal exit.
    /// - `Db.insertAndGetId` supports both `INSERT ... RETURNING id` and `RETURN_GENERATED_KEYS`.
    /// - PostgreSQL SQLSTATE `23***` constraint violations map cleanly to
    ///   `DbErrorKind.ConstraintViolation` (`409 Conflict` via `Middleware.dbErrorToHttp`).
    ///
    pub def runWith(db: PostgresDb, f: Unit -> a \ ef): a \ (ef - Db) + IO = {
        let PostgresDb.PostgresDb(pool, _) = db;
        Jdbc.runPooledDb(false, Jdbc.doInsertAndGetIdPostgres, pool, f)
    }

    // --- Internal Driver Connection Factory ---

    def openRawConnection(cfg: PostgresConfig): Result[String, Connection] \ IO = {
        let PostgresConfig.PostgresConfig(c) = cfg;
        try {
            let props = new Properties();
            if (not String.isEmpty(c#username)) {
                let _ = props.setProperty("user", c#username);
                ()
            } else ();
            if (not String.isEmpty(c#password)) {
                let _ = props.setProperty("password", c#password);
                ()
            } else ();
            if (not String.isEmpty(c#applicationName)) {
                let _ = props.setProperty("ApplicationName", c#applicationName);
                ()
            } else ();
            let _ = props.setProperty("connectTimeout", "${c#connectTimeoutSec}");
            match c#sslMode {
                case Some(mode) =>
                    let _ = props.setProperty("sslmode", mode);
                    ()
                case None => ()
            };
            let driver = new Driver();
            let conn = driver.connect(c#jdbcUrl, props);
            if (Object.isNull(conn))
                Err("Invalid PostgreSQL JDBC URL: ${c#jdbcUrl}")
            else
                Ok(conn)
        } catch {
            case ex: SQLException =>
                let rawMsg = ex.getMessage();
                let msg = if (Object.isNull(rawMsg)) "PostgreSQL connection failed" else rawMsg;
                Err("Failed to connect to PostgreSQL (${c#jdbcUrl}): ${msg}")
        }
    }

}
