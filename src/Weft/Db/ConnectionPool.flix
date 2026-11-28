pub mod Weft.Db.ConnectionPool {
    use Weft.Db.ConnectionPool
    use Weft.Db.PoolConfig
    use Weft.Db.PoolStats
    use Weft.DbErrorKind

    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.{Long => JLong}
    import java.lang.System
    import java.sql.Connection
    import java.util.concurrent.ConcurrentHashMap
    import java.util.concurrent.LinkedBlockingDeque
    import java.util.concurrent.Semaphore
    import java.util.concurrent.TimeUnit
    import java.util.concurrent.atomic.AtomicBoolean
    import java.util.concurrent.atomic.AtomicInteger
    import java.util.concurrent.atomic.AtomicLong

    ///
    /// Bounded, thread-safe, virtual-thread-friendly JDBC connection pool.
    ///
    /// Shared across `Weft.Db.Postgres` (full read/write pool) and `Weft.Db.Sqlite`
    /// (concurrent WAL reader pool), or any custom JDBC driver.
    ///
    pub enum ConnectionPool {
        case ConnectionPool({
            config       = PoolConfig,
            factory      = Unit -> Result[String, Connection] \ IO,
            permits      = Semaphore,
            idle         = LinkedBlockingDeque[PooledConn],
            activeMeta   = ConcurrentHashMap[Connection, JLong],
            closed       = AtomicBoolean,
            activeCount  = AtomicInteger,
            totalCreated = AtomicLong
        })
    }

    enum PooledConn {
        case PooledConn(Connection, Int64, Int64)
    }

    ///
    /// Opens a new `ConnectionPool`, pre-warming `PoolConfig.minIdle(cfg)` connections
    /// so configuration or connectivity errors fail fast at startup.
    ///
    pub def open(
        cfg: PoolConfig,
        factory: Unit -> Result[String, Connection] \ IO
    ): Result[String, ConnectionPool] \ IO = {
        let maxConns = PoolConfig.maxConnections(cfg);
        let minIdle = PoolConfig.minIdle(cfg);
        let pool = ConnectionPool.ConnectionPool({
            config       = cfg,
            factory      = factory,
            permits      = new Semaphore(maxConns, true),
            idle         = new LinkedBlockingDeque(),
            activeMeta   = new ConcurrentHashMap(),
            closed       = new AtomicBoolean(false),
            activeCount  = new AtomicInteger(0),
            totalCreated = new AtomicLong(0i64)
        });
        match prewarm(minIdle, pool) {
            case Ok(()) => Ok(pool)
            case Err(msg) =>
                close(pool);
                Err(msg)
        }
    }

    def prewarm(remaining: Int32, pool: ConnectionPool): Result[String, Unit] \ IO =
        if (remaining <= 0)
            Ok(())
        else {
            let ConnectionPool.ConnectionPool(p) = pool;
            match (p#factory)() {
                case Err(msg) => Err(msg)
                case Ok(conn) =>
                    let now = System.currentTimeMillis();
                    let _ = p#totalCreated.incrementAndGet();
                    let _ = p#idle.offerFirst(PooledConn.PooledConn(conn, now, now));
                    prewarm(remaining - 1, pool)
            }
        }

    ///
    /// Borrows a healthy `java.sql.Connection` from `pool`, blocking the current virtual
    /// thread for up to `PoolConfig.acquireTimeoutMs` if all permits are currently active.
    ///
    pub def borrow(pool: ConnectionPool): Result[(DbErrorKind, String), Connection] \ IO = {
        let ConnectionPool.ConnectionPool(p) = pool;
        if (p#closed.get())
            Err((DbErrorKind.ConnectionFailed, "Database connection pool is closed"))
        else {
            let timeoutMs = PoolConfig.acquireTimeoutMs(p#config);
            let acquired = try {
                p#permits.tryAcquire(timeoutMs, TimeUnit.MILLISECONDS)
            } catch {
                case _: InterruptedException => false
            };
            if (not acquired)
                Err((DbErrorKind.ConnectionFailed, "Timed out waiting for a database connection after ${timeoutMs}ms"))
            else if (p#closed.get()) {
                p#permits.release();
                Err((DbErrorKind.ConnectionFailed, "Database connection pool is closed"))
            } else {
                let now = System.currentTimeMillis();
                match pollValidIdle(p#config, now, p#idle) {
                    case Some((conn, createdAtMs)) =>
                        let _ = p#activeMeta.put(conn, JLong.valueOf(createdAtMs));
                        let _ = p#activeCount.incrementAndGet();
                        Ok(conn)
                    case None =>
                        match (p#factory)() {
                            case Ok(conn) =>
                                let createdAt = System.currentTimeMillis();
                                let _ = p#activeMeta.put(conn, JLong.valueOf(createdAt));
                                let _ = p#totalCreated.incrementAndGet();
                                let _ = p#activeCount.incrementAndGet();
                                Ok(conn)
                            case Err(msg) =>
                                p#permits.release();
                                Err((DbErrorKind.ConnectionFailed, msg))
                        }
                }
            }
        }
    }

    ///
    /// Returns a healthy `conn` back to `pool` (or closes it if broken/closed/non-autocommit/past maxLifetime)
    /// and releases its semaphore permit.
    ///
    pub def release(pool: ConnectionPool, conn: Connection): Unit \ IO = {
        let ConnectionPool.ConnectionPool(p) = pool;
        let now = System.currentTimeMillis();
        let createdObj = p#activeMeta.remove(conn);
        let createdAtMs = if (Object.isNull(createdObj)) now else createdObj.longValue();
        let _ = p#activeCount.decrementAndGet();
        let maxLife = PoolConfig.maxLifetimeMs(p#config);
        let expired = maxLife > 0i64 and (now - createdAtMs) >= maxLife;
        let reusable = if (p#closed.get() or expired)
            false
        else
            try {
                not conn.isClosed() and conn.getAutoCommit()
            } catch {
                case _: Exception => false
            };
        if (reusable) {
            let offered = p#idle.offerFirst(PooledConn.PooledConn(conn, createdAtMs, now));
            if (not offered) safeClose(conn) else ()
        } else {
            safeClose(conn)
        };
        p#permits.release()
    }

    ///
    /// Permanently closes a broken `conn` without returning it to the idle queue,
    /// releasing its permit so future callers can open a fresh replacement.
    ///
    pub def evict(pool: ConnectionPool, conn: Connection): Unit \ IO = {
        let ConnectionPool.ConnectionPool(p) = pool;
        let _ = p#activeMeta.remove(conn);
        let _ = p#activeCount.decrementAndGet();
        safeClose(conn);
        p#permits.release()
    }

    ///
    /// Borrows a connection, executes `f`, and guarantees the connection is returned
    /// (or evicted on exception) before returning.
    ///
    pub def withConnection(
        pool: ConnectionPool,
        f: Connection -> Result[(DbErrorKind, String), a] \ IO
    ): Result[(DbErrorKind, String), a] \ IO =
        match borrow(pool) {
            case Err(e) => Err(e)
            case Ok(conn) =>
                try {
                    let res = f(conn);
                    release(pool, conn);
                    res
                } catch {
                    case ex: Exception =>
                        evict(pool, conn);
                        let rawMsg = ex.getMessage();
                        Err((DbErrorKind.QueryFailed, if (Object.isNull(rawMsg)) "Database operation failed" else rawMsg))
                }
        }

    ///
    /// Returns a live snapshot of pool utilization metrics.
    ///
    pub def stats(pool: ConnectionPool): PoolStats \ IO = {
        let ConnectionPool.ConnectionPool(p) = pool;
        PoolStats.make(
            PoolConfig.maxConnections(p#config),
            p#activeCount.get(),
            p#idle.size(),
            p#totalCreated.get(),
            p#closed.get()
        )
    }

    ///
    /// Marks the pool closed and closes all currently idle connections.
    /// Any currently borrowed connections will be closed automatically upon `release`.
    ///
    pub def close(pool: ConnectionPool): Unit \ IO = {
        let ConnectionPool.ConnectionPool(p) = pool;
        p#closed.set(true);
        drainAndClose(p#idle)
    }

    // --- Internal Helpers ---

    def pollValidIdle(
        cfg: PoolConfig,
        nowMs: Int64,
        deque: LinkedBlockingDeque[PooledConn]
    ): Option[(Connection, Int64)] \ IO = {
        let entry = deque.pollFirst();
        if (Object.isNull(entry))
            None
        else {
            let PooledConn.PooledConn(conn, createdAtMs, lastUsedAtMs) = entry;
            let maxLife = PoolConfig.maxLifetimeMs(cfg);
            let idleTimeout = PoolConfig.idleTimeoutMs(cfg);
            let pastMaxLife = maxLife > 0i64 and (nowMs - createdAtMs) >= maxLife;
            let pastIdle = idleTimeout > 0i64 and (nowMs - lastUsedAtMs) >= idleTimeout;
            if (pastMaxLife or pastIdle) {
                safeClose(conn);
                pollValidIdle(cfg, nowMs, deque)
            } else {
                let valSecs = PoolConfig.validationTimeoutSec(cfg);
                let valInterval = PoolConfig.validationIntervalMs(cfg);
                let needsValidation = valSecs > 0 and (valInterval <= 0i64 or (nowMs - lastUsedAtMs) >= valInterval);
                if (isHealthy(if (needsValidation) valSecs else 0, conn))
                    Some((conn, createdAtMs))
                else {
                    safeClose(conn);
                    pollValidIdle(cfg, nowMs, deque)
                }
            }
        }
    }

    def isHealthy(validationSecs: Int32, conn: Connection): Bool \ IO =
        try {
            if (conn.isClosed())
                false
            else if (validationSecs > 0)
                conn.isValid(validationSecs)
            else
                true
        } catch {
            case _: Exception => false
        }

    def drainAndClose(deque: LinkedBlockingDeque[PooledConn]): Unit \ IO = {
        let entry = deque.pollFirst();
        if (Object.isNull(entry))
            ()
        else {
            let PooledConn.PooledConn(conn, _, _) = entry;
            safeClose(conn);
            drainAndClose(deque)
        }
    }

    def safeClose(conn: Connection): Unit \ IO =
        try {
            if (not conn.isClosed()) conn.close() else ()
        } catch {
            case _: Exception => ()
        }

}
