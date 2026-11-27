mod TestHarness {
    use Assert.assertTrue
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use Features.Catalog.CatalogStore
    use Features.Checkout.OrderStore
    use Shared.Mailer
    use Shared.Mailer.EmailMessage
    use Shared.Schema
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Body
    use weft::Weft.Db
    use weft::Weft.Db.Sqlite
    use weft::Weft.Db.SqliteConfig
    use weft::Weft.Db.SqliteDb
    use weft::Weft.DbError
    use weft::Weft.HttpError
    use weft::Weft.JobQueue
    use weft::Weft.JobStore
    use weft::Weft.JobWorker
    use weft::Weft.Random
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Row
    use weft::Weft.SessionStore
    use weft::Weft.SqlValue
    use weft::Weft.StaticStore
    use weft::Weft.TestEffects
    use weft::Weft.TestSession
    use weft::Weft.Url
    use weft::Weft.WorkerConfig

    ///
    /// Runs `f` against an isolated in-memory SQLite database seeded with demo data
    /// and a fully wired `App[IO]` (zero sockets, fast 1000-iteration PBKDF2).
    ///
    pub def withTestEnv(f: (SqliteDb, App[IO]) -> Unit \ {IO, Assert}): Unit \ {IO, Assert} =
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(msg) =>
                assertTrue(false);
                println("Failed to open in-memory SQLite: ${msg}")
            case Ok(db) =>
                let initRes = run {
                    Schema.initAndSeed(1000)
                } with Sqlite.runWith(db)
                  with DbError.runToResult
                  with Random.runWithSecureRandom;
                match initRes {
                    case Err((k, msg)) =>
                        Sqlite.close(db);
                        assertTrue(false);
                        println("Init failed (${k}): ${msg}")
                    case Ok(()) =>
                        let app = ShopApp.build("test-session-secret-0123456789", 1000);
                        let wired = wireTestApp(db, defaultStaticAssets(), app);
                        f(db, wired);
                        Sqlite.close(db)
                }
        }

    pub def defaultStaticAssets(): Map[String, Vector[Int8]] =
        Map#{
            "styles.css"     => Body.utf8Bytes("body { margin: 0; }"),
            "brand-mark.svg" => Body.utf8Bytes("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>")
        }

    pub def wireTestApp(
        db: SqliteDb,
        assets: Map[String, Vector[Int8]],
        app: App[ShopApp.ShopEffects]
    ): App[IO] = req -> {
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
            } with StaticStore.runPure(assets)
              with Sqlite.runWith(db)
              with DbError.runToHttpErrorSafe
              with HttpError.runAsHtml;

        run {
            s4()
        } with Random.runWithSecureRandom
          with Clock.runWithIO
          with TestEffects.runSilentLogger
    }

    ///
    /// Drains all pending jobs from `_weft_jobs` through `ShopApp.jobRegistry()` and
    /// returns every outbound `EmailMessage` captured by `Shared.Mailer.runRecording`.
    ///
    pub def drainJobs(db: SqliteDb): List[EmailMessage] \ IO = region rc {
        let emailsRef: Ref[List[EmailMessage], rc] = Ref.fresh(rc, Nil);
        let reg = ShopApp.jobRegistry();
        let cfg = WorkerConfig.default();
        def loop(remaining: Int32): Unit \ {IO, rc} = {
            if (remaining <= 0) ()
            else {
                let res = run {
                    JobWorker.runNext(cfg, reg)
                } with JobStore.runWithDb
                  with Sqlite.runWith(db)
                  with DbError.runToResult
                  with Mailer.runRecording(emailsRef)
                  with Clock.runWithIO
                  with TestEffects.runSilentLogger;
                match res {
                    case Ok(true) => loop(remaining - 1)
                    case _        => ()
                }
            }
        };
        loop(20);
        Ref.get(emailsRef)
    }

    // --- Direct SQLite Inspection Helpers (Outside `region rc` to keep effects minimal) ---

    pub def forceProductStock(db: SqliteDb, pid: Int64, newStock: Int32): Unit \ IO = {
        let _ = run {
            CatalogStore.updateStock(pid, newStock)
        } with CatalogStore.runWithDb
          with Sqlite.runWith(db)
          with DbError.runToResult;
        ()
    }

    pub def productStock(db: SqliteDb, pid: Int64): Int32 \ IO = {
        let res = run {
            CatalogStore.findById(pid)
        } with CatalogStore.runWithDb
          with Sqlite.runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(Some(p)) => p#stock
            case _           => -1
        }
    }

    pub def orderCount(db: SqliteDb): Int64 \ IO = {
        let res = run {
            Db.queryOneMap("SELECT COUNT(*) AS cnt FROM orders", Nil, Row.requireInt64("cnt"))
        } with Sqlite.runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(Some(n)) => n
            case _           => -1i64
        }
    }

    pub def latestOrderId(db: SqliteDb): Int64 \ IO = {
        let res = run {
            Db.queryOneMap("SELECT MAX(id) AS max_id FROM orders", Nil, Row.optionalInt64("max_id"))
        } with Sqlite.runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(Some(Some(id))) => id
            case _                  => -1i64
        }
    }

    pub def latestProductId(db: SqliteDb): Int64 \ IO = {
        let res = run {
            Db.queryOneMap("SELECT MAX(id) AS max_id FROM products", Nil, Row.optionalInt64("max_id"))
        } with Sqlite.runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(Some(Some(id))) => id
            case _                  => -1i64
        }
    }

    // --- HTTP / HTMX / Auth Helpers ---

    pub def extractCsrfOrFail(res: Response): String \ Assert =
        match TestSession.extractCsrfToken(res) {
            case Some(tok) => tok
            case None =>
                assertTrue(false);
                ""
        }

    pub def htmxPostForm(
        path: String,
        csrf: String,
        fields: List[(String, String)],
        app: App[IO],
        browser: TestSession[r]
    ): Response \ {IO, r} = {
        let req = Request.post(path)
            |> Request.withHeader("HX-Request", "true")
            |> Request.withHeader("X-CSRF-Token", csrf)
            |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
            |> Request.withBody(Url.encodeQuery(fields));
        TestSession.send(req, app, browser)
    }

    pub def htmxDelete(
        path: String,
        csrf: String,
        app: App[IO],
        browser: TestSession[r]
    ): Response \ {IO, r} = {
        let req = Request.delete(path)
            |> Request.withHeader("HX-Request", "true")
            |> Request.withHeader("X-CSRF-Token", csrf);
        TestSession.send(req, app, browser)
    }

    pub def loginAs(
        email: String,
        password: String,
        app: App[IO],
        browser: TestSession[r]
    ): Response \ {IO, Assert, r} = {
        let loginGet = TestSession.get("/login", app, browser);
        let csrf = extractCsrfOrFail(loginGet);
        TestSession.postForm(
            "/login",
            ("_csrf", csrf) :: ("email", email) :: ("password", password) :: Nil,
            app,
            browser
        )
    }

}
