mod LiveServer {
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use Features.Catalog.CatalogStore
    use Features.Checkout.OrderStore
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Cache
    use weft::Weft.Db
    use weft::Weft.Db.PoolStats
    use weft::Weft.Db.Sqlite
    use weft::Weft.Db.SqliteDb
    use weft::Weft.DbError
    use weft::Weft.HttpError
    use weft::Weft.JobQueue
    use weft::Weft.Json
    use weft::Weft.Method
    use weft::Weft.Random
    use weft::Weft.RateLimiter
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.SessionStore
    use weft::Weft.StaticStore
    use weft::Weft.Status

    ///
    /// Composition boundary that binds all domain store effects (`CatalogStore`, `CartStore`,
    /// `UserStore`, `OrderStore`) and Weft infrastructure effects (`SessionStore`, `JobQueue`,
    /// `Cache`, `RateLimiter`, `StaticStore`) to pooled WAL SQLite and the local filesystem,
    /// plus exposes a live `/health` endpoint reporting DB liveness and WAL reader pool stats.
    ///
    pub def wire(db: SqliteDb, publicDir: String, app: App[ShopApp.ShopEffects]): App[IO] = req -> {
        if (Request.method(req) == Method.Get and Request.path(req) == "/health") {
            healthResponse(db)
        } else {
            let s1: Unit -> Response \ {UserStore, OrderStore, SessionStore, Cache, RateLimiter, Db, DbError, Random, Clock, StaticStore, Logger} = () ->
                run {
                    app(req)
                } with CatalogStore.runWithDb
                  with CartStore.runWithDb;

            let s2: Unit -> Response \ {SessionStore, JobQueue, Cache, RateLimiter, Db, DbError, Random, Clock, StaticStore, Logger} = () ->
                run {
                    s1()
                } with UserStore.runWithDb
                  with OrderStore.runWithDb;

            let s3: Unit -> Response \ {Db, DbError, Random, Clock, StaticStore, Logger} = () ->
                run {
                    s2()
                } with SessionStore.runWithDb
                  with JobQueue.runWithDb
                  with Cache.runWithDb
                  with RateLimiter.runWithDb;

            let s4: Unit -> Response \ {Random, Clock, Logger, IO} = () ->
                run {
                    s3()
                } with StaticStore.runFromDir(publicDir)
                  with Sqlite.runWith(db)
                  with DbError.runToHttpErrorSafe
                  with HttpError.runAsHtml;

            run {
                s4()
            } with Random.runWithSecureRandom
              with Clock.runWithIO
              with Logger.runWithIO
        }
    }

    pub def healthResponse(db: SqliteDb): Response \ IO = {
        let pingRes = Sqlite.ping(db);
        let poolJson = match Sqlite.readerPoolStats(db) {
            case Some(st) => PoolStats.toJson(st)
            case None     => Json.nullValue()
        };
        match pingRes {
            case Ok(()) =>
                Json.toResponse(Json.obj(
                    ("status", Json.str("ok")) ::
                    ("database", Json.str("sqlite-wal")) ::
                    ("readerPool", poolJson) ::
                    Nil
                ))
            case Err(msg) =>
                Json.toResponseWithStatus(
                    Status.serviceUnavailable(),
                    Json.obj(
                        ("status", Json.str("unhealthy")) ::
                        ("error", Json.str(msg)) ::
                        ("readerPool", poolJson) ::
                        Nil
                    )
                )
        }
    }

}

def main(): Unit \ IO = {
    use Shared.Schema;
    use Time.Clock;
    use weft::Weft.Cache;
    use weft::Weft.Crypto;
    use weft::Weft.Db.PoolStats;
    use weft::Weft.Db.Sqlite;
    use weft::Weft.Db.SqliteConfig;
    use weft::Weft.DbError;
    use weft::Weft.Env;
    use weft::Weft.HttpClient;
    use weft::Weft.JobStore;
    use weft::Weft.JobWorker;
    use weft::Weft.Mailer;
    use weft::Weft.Random;
    use weft::Weft.RateLimiter;
    use weft::Weft.Scheduler;
    use weft::Weft.ScheduleStore;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;
    use weft::Weft.SessionStore;
    use weft::Weft.WorkerConfig;
    use weft::Weft.WorkerHandle;

    let (port, dbPath, readPoolSize, secret, publicDir, resendKeyOpt) = Env.runWithSystem(() -> (
        Env.getIntOrDefault("PORT", 8080),
        Env.getOrDefault("DB_PATH", "weft_roasters.db"),
        Env.getIntOrDefault("DB_READ_POOL_SIZE", 4),
        Env.getOrDefault("SESSION_SECRET", "dev-only-change-me-in-production"),
        Env.getOrDefault("PUBLIC_DIR", "public"),
        Env.get("RESEND_API_KEY") |> Option.filter(s -> not String.isEmpty(String.trim(s)))
    ));

    let sqliteCfg = SqliteConfig.file(dbPath)
        |> SqliteConfig.withReadPoolSize(readPoolSize);

    match Sqlite.open(sqliteCfg) {
        case Err(msg) =>
            println("Failed to open SQLite database '${dbPath}': ${msg}")
        case Ok(db) =>
            let initRes = run {
                Schema.initAndSeed(Crypto.defaultPasswordIterations())
            } with Sqlite.runWith(db)
              with DbError.runToResult
              with Random.runWithSecureRandom;

            match initRes {
                case Err((kind, msg)) =>
                    println("Database initialization failed (${kind}): ${msg}");
                    Sqlite.close(db)
                case Ok(()) =>
                    // 1. Start virtual-thread background job worker (using Weft.Mailer: Resend or Logger)
                    let jobReg = ShopApp.jobRegistry();
                    let workerCfg = WorkerConfig.default() |> WorkerConfig.withConcurrency(2);
                    let workerHandle = JobWorker.startBackground(workerCfg, () -> {
                        let stepRes = match resendKeyOpt {
                            case Some(apiKey) =>
                                run {
                                    JobWorker.runNext(workerCfg, jobReg)
                                } with JobStore.runWithDb
                                  with Sqlite.runWith(db)
                                  with DbError.runToResult
                                  with Mailer.runWithResend(apiKey)
                                  with HttpClient.runWithJdk
                                  with Clock.runWithIO
                                  with Logger.runWithIO
                            case None =>
                                run {
                                    JobWorker.runNext(workerCfg, jobReg)
                                } with JobStore.runWithDb
                                  with Sqlite.runWith(db)
                                  with DbError.runToResult
                                  with Mailer.runLogging
                                  with Clock.runWithIO
                                  with Logger.runWithIO
                        };
                        match stepRes {
                            case Ok(didWork) => didWork
                            case Err(_)      => false
                        }
                    });

                    // 2. Start virtual-thread maintenance scheduler (session/cache/rate-limit pruning + stale job recovery)
                    let sched = ShopApp.maintenanceScheduler();
                    let schedulerHandle = Scheduler.startBackground(60000i64, () -> {
                        let tickRes = run {
                            Scheduler.tick(sched)
                        } with ScheduleStore.runWithDb
                          with SessionStore.runWithDb
                          with Cache.runWithDb
                          with RateLimiter.runWithDb
                          with JobStore.runWithDb
                          with Sqlite.runWith(db)
                          with DbError.runToResult
                          with Clock.runWithIO
                          with Logger.runWithIO;
                        match tickRes {
                            case Ok(ran) => ran
                            case Err(_)  => Nil
                        }
                    });

                    let app = ShopApp.build(secret, Crypto.defaultPasswordIterations());
                    let ioApp = LiveServer.wire(db, publicDir, app);
                    let srvCfg = ServerConfig.local(port)
                        |> ServerConfig.withReadTimeoutMs(15000i64)
                        |> ServerConfig.withHandlerTimeoutMs(30000i64)
                        |> ServerConfig.withShutdownGraceSeconds(5);

                    let poolDesc = match Sqlite.readerPoolStats(db) {
                        case Some(st) => "${PoolStats.maxConnections(st)} WAL reader connections"
                        case None     => "single connection"
                    };
                    let mailDesc = match resendKeyOpt {
                        case Some(_) => "Resend HTTP API"
                        case None    => "Logger (dev mode)"
                    };

                    println("Weft Roasters e-commerce server (Weft v0.10.0) running at http://127.0.0.1:${port}");
                    println("  Database:    ${dbPath} (${poolDesc})");
                    println("  Mailer:      ${mailDesc}");
                    println("  Health:      http://127.0.0.1:${port}/health");
                    println("  Storefront:  http://127.0.0.1:${port}/");
                    println("  Cart:        http://127.0.0.1:${port}/cart");
                    println("  Admin:       http://127.0.0.1:${port}/admin  (admin@weftroasters.com / admin123)");
                    println("  Customer:    ada@example.com / coffee123");
                    println("  Catalog API: http://127.0.0.1:${port}/api/products");
                    println("  SSE Stream:  http://127.0.0.1:${port}/api/events/catalog");

                    // 3. Hardened server with coordinated graceful shutdown draining HTTP, Scheduler, Worker & SQLite pool
                    let shutdownHooks =
                        (() -> WorkerHandle.stop(schedulerHandle)) ::
                        (() -> WorkerHandle.stop(workerHandle)) ::
                        (() -> Sqlite.close(db)) ::
                        Nil;

                    match Server.serveWithShutdown(srvCfg, shutdownHooks, ioApp) {
                        case Ok(())   => ()
                        case Err(msg) =>
                            println("Server error: ${msg}");
                            WorkerHandle.stop(schedulerHandle);
                            WorkerHandle.stop(workerHandle);
                            Sqlite.close(db)
                    }
            }
    }
}
