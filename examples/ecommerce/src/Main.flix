mod LiveServer {
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use Features.Catalog.CatalogStore
    use Features.Checkout.OrderStore
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Db
    use weft::Weft.Db.Sqlite
    use weft::Weft.Db.SqliteDb
    use weft::Weft.DbError
    use weft::Weft.HttpError
    use weft::Weft.JobQueue
    use weft::Weft.Random
    use weft::Weft.Response
    use weft::Weft.SessionStore
    use weft::Weft.StaticStore

    ///
    /// Composition boundary that binds all domain store effects (`CatalogStore`, `CartStore`,
    /// `UserStore`, `OrderStore`) and Weft stores (`SessionStore`, `JobQueue`, `StaticStore`)
    /// to SQLite and the local filesystem.
    ///
    pub def wire(db: SqliteDb, publicDir: String, app: App[ShopApp.ShopEffects]): App[IO] = req -> {
        let s1: Unit -> Response \ {UserStore, OrderStore, SessionStore, Db, DbError, Random, Clock, StaticStore, Logger} = () ->
            run {
                app(req)
            } with CatalogStore.runWithDb
              with CartStore.runWithDb;

        let s2: Unit -> Response \ {SessionStore, JobQueue, Db, DbError, Random, Clock, StaticStore, Logger} = () ->
            run {
                s1()
            } with UserStore.runWithDb
              with OrderStore.runWithDb;

        let s3: Unit -> Response \ {Db, DbError, Random, Clock, StaticStore, Logger} = () ->
            run {
                s2()
            } with SessionStore.runWithDb
              with JobQueue.runWithDb;

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

def main(): Unit \ IO = {
    use Shared.Mailer;
    use Shared.Schema;
    use Time.Clock;
    use weft::Weft.Crypto;
    use weft::Weft.Db.Sqlite;
    use weft::Weft.Db.SqliteConfig;
    use weft::Weft.DbError;
    use weft::Weft.Env;
    use weft::Weft.JobStore;
    use weft::Weft.JobWorker;
    use weft::Weft.Random;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;
    use weft::Weft.WorkerConfig;
    use weft::Weft.WorkerHandle;

    let (port, dbPath, secret, publicDir) = Env.runWithSystem(() -> (
        Env.getIntOrDefault("PORT", 8080),
        Env.getOrDefault("DB_PATH", "weft_roasters.db"),
        Env.getOrDefault("SESSION_SECRET", "dev-only-change-me-in-production"),
        Env.getOrDefault("PUBLIC_DIR", "public")
    ));

    match Sqlite.open(SqliteConfig.file(dbPath)) {
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
                    let jobReg = ShopApp.jobRegistry();
                    let workerCfg = WorkerConfig.default() |> WorkerConfig.withConcurrency(2);
                    let workerHandle = JobWorker.startBackground(workerCfg, () -> {
                        let stepRes = run {
                            JobWorker.runNext(workerCfg, jobReg)
                        } with JobStore.runWithDb
                          with Sqlite.runWith(db)
                          with DbError.runToResult
                          with Mailer.runWithLogger
                          with Clock.runWithIO
                          with Logger.runWithIO;
                        match stepRes {
                            case Ok(didWork) => didWork
                            case Err(_)      => false
                        }
                    });

                    let app = ShopApp.build(secret, Crypto.defaultPasswordIterations());
                    let ioApp = LiveServer.wire(db, publicDir, app);

                    println("Weft Roasters e-commerce server running at http://127.0.0.1:${port}");
                    println("  Storefront:  http://127.0.0.1:${port}/");
                    println("  Cart:        http://127.0.0.1:${port}/cart");
                    println("  Admin:       http://127.0.0.1:${port}/admin  (admin@weftroasters.com / admin123)");
                    println("  Customer:    ada@example.com / coffee123");
                    println("  Catalog API: http://127.0.0.1:${port}/api/products");

                    match Server.serve(ServerConfig.local(port), ioApp) {
                        case Ok(())   => ()
                        case Err(msg) => println("Server error: ${msg}")
                    };

                    WorkerHandle.stop(workerHandle);
                    Sqlite.close(db)
            }
    }
}
