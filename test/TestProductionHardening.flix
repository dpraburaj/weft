mod TestProductionHardening {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Time.Clock
    use Weft.Cache
    use Weft.Cookie
    use Weft.CorsConfig
    use Weft.Db
    use Weft.Db.ConnectionPool
    use Weft.Db.PoolConfig
    use Weft.Db.PoolStats
    use Weft.Db.Postgres
    use Weft.Db.PostgresConfig
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Headers
    use Weft.HttpClient
    use Weft.Job
    use Weft.JobSpec
    use Weft.JobStore
    use Weft.Json
    use Weft.Middleware
    use Weft.Migration
    use Weft.Multipart
    use Weft.Random
    use Weft.RateLimitConfig
    use Weft.RateLimiter
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.ServerConfig
    use Weft.SessionData
    use Weft.SessionStore
    use Weft.SqlValue
    use Weft.Status
    use Weft.TestEffects

    import java.io.{File => JFile}
    import java.lang.Exception
    import java.lang.Runnable
    import java.lang.RuntimeException
    import java.lang.System
    import java.lang.Thread
    import java.util.Properties
    import java.util.concurrent.CountDownLatch
    import java.util.concurrent.TimeUnit
    import java.util.concurrent.atomic.AtomicInteger
    import org.sqlite.JDBC

    @Test
    def testJsonMaxDepthAndMultipartMaxParts(): Unit \ Assert = {
        // Deeply nested JSON returns clean Err instead of StackOverflowError
        let deepArr = String.repeat(200, "[") + "1" + String.repeat(200, "]");
        match Json.parse(deepArr) {
            case Err(msg) => assertTrue(String.contains({substr = "nesting depth"}, msg))
            case Ok(_)    => Assert.fail("Expected nesting depth error for 200-deep array")
        };

        let deepObj = String.repeat(200, "{\"a\":") + "1" + String.repeat(200, "}");
        match Json.parse(deepObj) {
            case Err(msg) => assertTrue(String.contains({substr = "nesting depth"}, msg))
            case Ok(_)    => Assert.fail("Expected nesting depth error for 200-deep object")
        };

        // Custom depth limit respected accurately
        assertTrue(Result.isOk(Json.parseWithMaxDepth(3, "[[[1]]]")));
        assertTrue(Result.isErr(Json.parseWithMaxDepth(3, "[[[[1]]]]")));

        // Multipart max part count limit
        let boundary = "HardeningBoundary";
        let twoParts = Multipart.encode(boundary, ("a", "1") :: ("b", "2") :: Nil, Nil);
        let threeParts = Multipart.encode(boundary, ("a", "1") :: ("b", "2") :: ("c", "3") :: Nil, Nil);
        assertTrue(Result.isOk(Multipart.parseWithMaxParts(2, boundary, twoParts)));
        match Multipart.parseWithMaxParts(2, boundary, threeParts) {
            case Err(msg) => assertTrue(String.contains({substr = "maximum allowed part count"}, msg))
            case Ok(_)    => Assert.fail("Expected max part count error for 3 parts when limit is 2")
        }
    }

    @Test
    def testHttp2MultiCookieHeadersAndCookieHeaderSanitization(): Unit \ Assert = {
        // HTTP/2 splits cookies across multiple Cookie headers -> all must be parsed
        let hdrs = Headers.empty()
            |> Headers.add("Cookie", "sid=abc123")
            |> Headers.add("Cookie", "theme=dark; lang=en");
        let req = Request.get("/") |> Request.withHeaders(hdrs);
        assertEq(expected = Some("abc123"), Request.cookie("sid", req));
        assertEq(expected = Some("dark"), Request.cookie("theme", req));
        assertEq(expected = Some("en"), Request.cookie("lang", req));

        // CRLF / semicolon injection stripped from Set-Cookie output
        let evil = Cookie.make("a\r\nSet-Cookie: pwn=1", "v\n; HttpOnly")
            |> Cookie.withPath("/\r\nbad");
        let hdr = Cookie.toHeaderValue(evil);
        assertFalse(String.contains({substr = "\r"}, hdr));
        assertFalse(String.contains({substr = "\n"}, hdr));
        assertTrue(String.startsWith({prefix = "aSet-Cookie: pwn=1=v HttpOnly; Path=/bad"}, hdr))
    }

    @Test
    def testThrottleSpoofingProtectionAndTrustedProxy(): Unit \ Assert = {
        let appDirect = Router.empty()
            |> Router.get("/api", () -> "ok")
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.throttle(RateLimitConfig.make(1, 60000i64));

        // Direct throttle ignores forged X-Forwarded-For and keys on remoteAddr
        run {
            let r1 = appDirect(
                Request.get("/api")
                    |> Request.withRemoteAddr("203.0.113.10")
                    |> Request.withHeader("X-Forwarded-For", "1.1.1.1")
            );
            let r2 = appDirect(
                Request.get("/api")
                    |> Request.withRemoteAddr("203.0.113.10")
                    |> Request.withHeader("X-Forwarded-For", "2.2.2.2")
            );
            assertEq(expected = Status.ok(), Response.status(r1));
            assertEq(expected = Status.tooManyRequests(), Response.status(r2))
        } with RateLimiter.runPure
          with TestEffects.runFixedClock(1000i64);

        // Trusted proxy middleware trusts X-Forwarded-For ONLY when remoteAddr is a trusted proxy
        let appProxied = Router.empty()
            |> Router.get("/api", () -> "ok")
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.throttleTrustedProxy("10.0.0.1" :: Nil, RateLimitConfig.make(1, 60000i64));

        run {
            // From trusted proxy 10.0.0.1: two different XFF clients get separate buckets
            let p1 = appProxied(
                Request.get("/api")
                    |> Request.withRemoteAddr("10.0.0.1")
                    |> Request.withHeader("X-Forwarded-For", "198.51.100.1, 10.0.0.1")
            );
            let p2 = appProxied(
                Request.get("/api")
                    |> Request.withRemoteAddr("10.0.0.1")
                    |> Request.withHeader("X-Forwarded-For", "198.51.100.2, 10.0.0.1")
            );
            let p1Again = appProxied(
                Request.get("/api")
                    |> Request.withRemoteAddr("10.0.0.1")
                    |> Request.withHeader("X-Forwarded-For", "198.51.100.1")
            );
            assertEq(expected = Status.ok(), Response.status(p1));
            assertEq(expected = Status.ok(), Response.status(p2));
            assertEq(expected = Status.tooManyRequests(), Response.status(p1Again));

            // From untrusted peer 203.0.113.99: XFF is ignored and peer IP is throttled
            let u1 = appProxied(
                Request.get("/api")
                    |> Request.withRemoteAddr("203.0.113.99")
                    |> Request.withHeader("X-Forwarded-For", "9.9.9.1")
            );
            let u2 = appProxied(
                Request.get("/api")
                    |> Request.withRemoteAddr("203.0.113.99")
                    |> Request.withHeader("X-Forwarded-For", "9.9.9.2")
            );
            assertEq(expected = Status.ok(), Response.status(u1));
            assertEq(expected = Status.tooManyRequests(), Response.status(u2))
        } with RateLimiter.runPure
          with TestEffects.runFixedClock(1000i64)
    }

    @Test
    def testCorsAllowlistSecurityHeadersWithAndRequestId(): Unit \ Assert = {
        let strictCors = CorsConfig.origins("https://app.example.com" :: "https://admin.example.com" :: Nil)
            |> CorsConfig.withCredentials(true);

        let app = Router.empty()
            |> Router.get("/whoami", () -> Option.getWithDefault("none", Req.header("X-Request-Id")))
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.cors(strictCors)
            |> Middleware.securityHeadersWith(Some(31536000), Some("default-src 'self'"))
            |> Middleware.requestId;

        run {
            // Allowed origin gets echoed + Vary: Origin + credentials + HSTS + CSP + generated X-Request-Id
            let rOk = app(Request.get("/whoami") |> Request.withHeader("Origin", "https://app.example.com"));
            assertEq(expected = Status.ok(), Response.status(rOk));
            assertEq(expected = Some("https://app.example.com"), Response.header("Access-Control-Allow-Origin", rOk));
            assertEq(expected = Some("true"), Response.header("Access-Control-Allow-Credentials", rOk));
            assertEq(expected = Some("Origin"), Response.header("Vary", rOk));
            assertEq(expected = Some("max-age=31536000; includeSubDomains"), Response.header("Strict-Transport-Security", rOk));
            assertEq(expected = Some("default-src 'self'"), Response.header("Content-Security-Policy", rOk));
            assertTrue(Option.nonEmpty(Response.header("Permissions-Policy", rOk)));
            match Response.header("X-Request-Id", rOk) {
                case Some(rid) =>
                    assertTrue(not String.isEmpty(rid));
                    assertEq(expected = rid, Response.body(rOk))
                case None =>
                    Assert.fail("Expected generated X-Request-Id header")
            };

            // Disallowed origin gets Vary: Origin but NO Access-Control-Allow-Origin
            let rDenied = app(Request.get("/whoami") |> Request.withHeader("Origin", "https://evil.example.com"));
            assertEq(expected = None, Response.header("Access-Control-Allow-Origin", rDenied));
            assertEq(expected = Some("Origin"), Response.header("Vary", rDenied));

            // Valid inbound X-Request-Id is preserved; invalid/injected X-Request-Id is replaced
            let rProp = app(Request.get("/whoami") |> Request.withHeader("X-Request-Id", "req-abc_123.4"));
            assertEq(expected = Some("req-abc_123.4"), Response.header("X-Request-Id", rProp));
            assertEq(expected = "req-abc_123.4", Response.body(rProp));

            let rInject = app(Request.get("/whoami") |> Request.withHeader("X-Request-Id", "bad\r\ninjected"));
            assertTrue(Response.header("X-Request-Id", rInject) != Some("bad\r\ninjected"))
        } with Random.runDeterministic(7i64);

        // Wildcard CORS never combines "*" with Access-Control-Allow-Credentials: true
        let badWildcard = CorsConfig.permissive() |> CorsConfig.withCredentials(true);
        let wildApp = Router.empty()
            |> Router.get("/ping", () -> "ok")
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.cors(badWildcard);
        let rWild = wildApp(Request.get("/ping") |> Request.withHeader("Origin", "https://any.example"));
        assertEq(expected = Some("*"), Response.header("Access-Control-Allow-Origin", rWild));
        assertEq(expected = None, Response.header("Access-Control-Allow-Credentials", rWild))
    }

    @Test
    def testSqliteLeakedTxLockCleanupAndConcurrentAtomicJobs(): Unit \ {Assert, IO} = {
        let dir = System.getProperty("java.io.tmpdir");
        let dbFile = new JFile(dir, "weft-hardening-${System.nanoTime()}.db");
        let dbPath = dbFile.getAbsolutePath();

        match Sqlite.open(SqliteConfig.file(dbPath)) {
            case Err(msg) => Assert.fail("Failed to open SQLite DB: ${msg}")
            case Ok(db) =>
                let initRes = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                    let _ = Db.executeSql("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)");
                    JobStore.initSchema();
                    Cache.initSchema();
                    RateLimiter.initSchema()
                }));
                assertTrue(Result.isOk(initRes));

                // 1. Leaked beginTx via normal exit rolls back & releases writer lock
                let _ = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                    Db.beginTx();
                    let _ = Db.execute("INSERT INTO notes (body) VALUES (?)", SqlValue.text("uncommitted-1") :: Nil);
                    ()
                }));

                // 2. Leaked beginTx via thrown RuntimeException rolls back & releases writer lock (no deadlock!)
                let threw = try {
                    let _ = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                        Db.beginTx();
                        let _ = Db.execute("INSERT INTO notes (body) VALUES (?)", SqlValue.text("uncommitted-2") :: Nil);
                        throw new RuntimeException("simulated handler crash")
                    }));
                    false
                } catch {
                    case _: RuntimeException => true
                };
                assertTrue(threw);

                // Subsequent write on a DIFFERENT virtual thread succeeds immediately (proving lock was unlocked!)
                let otherDone = new CountDownLatch(1);
                let otherOk = Ref.fresh(Static, false);
                let _ = Thread.ofVirtual().start(new Runnable {
                    def $run(_r: Runnable): Unit \ IO = {
                        let r = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                            let _ = Db.execute("INSERT INTO notes (body) VALUES (?)", SqlValue.text("committed-ok") :: Nil);
                            ()
                        }));
                        if (Result.isOk(r)) Ref.put(true, otherOk) else ();
                        otherDone.countDown()
                    }
                });
                assertTrue(otherDone.await(5i64, TimeUnit.SECONDS));
                assertTrue(Ref.get(otherOk));

                let countRes = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                    Db.queryOneMap("SELECT COUNT(*) AS c FROM notes", Nil, Weft.Row.requireInt("c"))
                ));
                assertEq(expected = Ok(Some(1)), countRes);

                // 3. Concurrent multi-thread JobStore.claimNext claims each job strictly once (zero duplicates!)
                let enqRes = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                    JobStore.runWithDb(() -> {
                        List.forEach(i -> {
                            let _ = JobStore.insertJob(
                                JobSpec.make("task", Json.obj(("i", Json.int(i)) :: Nil))
                                    |> JobSpec.withUniqueKey("u-${i}"),
                                1000i64
                            );
                            ()
                        }, List.range(0, 12));
                        // Duplicate uniqueKey while pending returns existing job without inserting duplicate
                        let dup = JobStore.insertJob(
                            JobSpec.make("task", Json.obj(("i", Json.int(0)) :: Nil))
                                |> JobSpec.withUniqueKey("u-0"),
                            1000i64
                        );
                        assertEq(expected = 1i64, Job.id(dup))
                    })
                ));
                assertTrue(Result.isOk(enqRes));

                let claimedCount = new AtomicInteger(0);
                let workersLatch = new CountDownLatch(6);
                List.forEach(_ -> {
                    let _ = Thread.ofVirtual().start(new Runnable {
                        def $run(_r: Runnable): Unit \ IO = {
                            def drainWorker(): Unit \ IO = {
                                let res = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                                    JobStore.runWithDb(() -> JobStore.claimNext("default", 2000i64))
                                ));
                                match res {
                                    case Ok(Some(_)) =>
                                        let _ = claimedCount.incrementAndGet();
                                        drainWorker()
                                    case _ => ()
                                }
                            };
                            drainWorker();
                            workersLatch.countDown()
                        }
                    });
                    ()
                }, List.range(0, 6));
                assertTrue(workersLatch.await(10i64, TimeUnit.SECONDS));
                assertEq(expected = 12, claimedCount.get());

                // 4. Atomic DB Cache lock: owner-1 acquires, owner-2 blocked, owner-1 renews, expires -> owner-2 acquires
                let lockRes = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                    Cache.runWithDb(() -> {
                        assertTrue(Cache.acquireLock("k1", "o1", 5000i64, 1000i64));
                        assertFalse(Cache.acquireLock("k1", "o2", 5000i64, 2000i64));
                        assertTrue(Cache.acquireLock("k1", "o1", 6000i64, 2000i64));
                        assertTrue(Cache.acquireLock("k1", "o2", 9000i64, 6000i64))
                    })
                ));
                assertTrue(Result.isOk(lockRes));

                // 5. Atomic DB RateLimiter RETURNING upsert: exact window count & reset
                let rlRes = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                    RateLimiter.runWithDb(() -> {
                        let d1 = RateLimiter.hit("k", 2, 5000i64, 1000i64);
                        let d2 = RateLimiter.hit("k", 2, 5000i64, 1500i64);
                        let d3 = RateLimiter.hit("k", 2, 5000i64, 2000i64);
                        let d4 = RateLimiter.hit("k", 2, 5000i64, 7000i64);
                        assertTrue(Weft.RateLimitDecision.isAllowed(d1));
                        assertEq(expected = 1, Weft.RateLimitDecision.remaining(d1));
                        assertTrue(Weft.RateLimitDecision.isAllowed(d2));
                        assertEq(expected = 0, Weft.RateLimitDecision.remaining(d2));
                        assertTrue(Weft.RateLimitDecision.isBlocked(d3));
                        assertTrue(Weft.RateLimitDecision.isAllowed(d4));
                        assertEq(expected = 1, Weft.RateLimitDecision.remaining(d4))
                    })
                ));
                assertTrue(Result.isOk(rlRes));

                Sqlite.close(db);
                let _ = dbFile.delete();
                let _ = (new JFile("${dbPath}-wal")).delete();
                let _ = (new JFile("${dbPath}-shm")).delete();
                ()
        }
    }

    @Test
    def testConnectionPoolMaxLifetimeAndBoundedInMemoryStores(): Unit \ {Assert, IO} = {
        // 1. ConnectionPool maxLifetimeMs retires aged connections cleanly
        let dir = System.getProperty("java.io.tmpdir");
        let dbFile = new JFile(dir, "weft-pool-life-${System.nanoTime()}.db");
        let jdbcUrl = "jdbc:sqlite:${dbFile.getAbsolutePath()}";
        let factory = () -> {
            let driver = new JDBC();
            Ok(driver.connect(jdbcUrl, new Properties()))
        };
        let cfg = PoolConfig.make(2)
            |> PoolConfig.withMinIdle(1)
            |> PoolConfig.withValidationTimeoutSec(0)
            |> PoolConfig.withMaxLifetimeMs(30i64);

        match ConnectionPool.open(cfg, factory) {
            case Err(msg) => Assert.fail("Pool open failed: ${msg}")
            case Ok(pool) =>
                assertEq(expected = 1i64, PoolStats.totalCreated(ConnectionPool.stats(pool)));
                Thread.sleep(50i64);
                match ConnectionPool.borrow(pool) {
                    case Err((_, e)) => Assert.fail("Borrow failed: ${e}")
                    case Ok(conn) =>
                        // Aged prewarmed connection was evicted and replaced -> totalCreated == 2
                        assertEq(expected = 2i64, PoolStats.totalCreated(ConnectionPool.stats(pool)));
                        ConnectionPool.release(pool, conn)
                };
                ConnectionPool.close(pool);
                let _ = dbFile.delete();
                ()
        };

        // 2. Bounded InMemory stores evict oldest entries at capacity
        let cacheStore = Cache.makeInMemoryWithCapacity(2);
        run {
            Cache.put("a", "1", 1000i64);
            Cache.put("b", "2", 5000i64);
            Cache.put("c", "3", 9000i64);
            // "a" had earliest expiry so it was evicted
            assertEq(expected = None, Cache.get("a"));
            assertEq(expected = Some("2"), Cache.get("b"));
            assertEq(expected = Some("3"), Cache.get("c"))
        } with Cache.runInMemory(cacheStore)
          with TestEffects.runFixedClock(1000i64);

        let sessStore = SessionStore.makeInMemoryWithCapacity(2);
        SessionStore.runInMemory(sessStore, () -> {
            SessionStore.saveSession(SessionData.make("s1", Map.empty(), Map.empty(), 2000i64, 1000i64, 1000i64));
            SessionStore.saveSession(SessionData.make("s2", Map.empty(), Map.empty(), 5000i64, 1000i64, 1000i64));
            SessionStore.saveSession(SessionData.make("s3", Map.empty(), Map.empty(), 9000i64, 1000i64, 1000i64));
            assertEq(expected = None, SessionStore.loadSession("s1", 1500i64));
            assertTrue(Option.nonEmpty(SessionStore.loadSession("s2", 1500i64)));
            assertTrue(Option.nonEmpty(SessionStore.loadSession("s3", 1500i64)))
        });

        let rlStore = RateLimiter.makeInMemoryWithCapacity(2);
        RateLimiter.runInMemory(rlStore, () -> {
            let _ = RateLimiter.hit("k1", 5, 1000i64, 1000i64);
            let _ = RateLimiter.hit("k2", 5, 5000i64, 1000i64);
            let _ = RateLimiter.hit("k3", 5, 9000i64, 1000i64);
            // k1 had earliest reset -> evicted so peeking shows full allowance again
            assertEq(expected = 5, Weft.RateLimitDecision.remaining(RateLimiter.peek("k1", 5, 1000i64, 1500i64)))
        });

        // 3. ServerConfig protocol-hardening defaults & reusable JdkHttpClient lifecycle
        let srvCfg = ServerConfig.default();
        assertEq(expected = 60000, ServerConfig.idleTimeoutMs(srvCfg));
        assertEq(expected = 15000, ServerConfig.noRequestTimeoutMs(srvCfg));
        assertEq(expected = 16384, ServerConfig.maxHeaderSize(srvCfg));
        assertEq(expected = 100, ServerConfig.maxHeaders(srvCfg));

        let jdkClient = HttpClient.makeJdk();
        HttpClient.closeJdk(jdkClient)
    }

    @Test
    def testLivePostgresIntegrationWhenConfigured(): Unit \ {Assert, IO} = {
        let envUrl = System.getenv("WEFT_TEST_POSTGRES_URL");
        if (Object.isNull(envUrl) or String.isEmpty(String.trim(envUrl))) {
            // Skipped locally unless WEFT_TEST_POSTGRES_URL is provided (enabled in GitHub Actions CI)
            ()
        } else {
            match PostgresConfig.fromDatabaseUrl(envUrl) {
                case Err(e) => Assert.fail("Invalid WEFT_TEST_POSTGRES_URL: ${e}")
                case Ok(pgCfg) =>
                    match Postgres.open(pgCfg) {
                        case Err(e) => Assert.fail("Failed to connect to test Postgres: ${e}")
                        case Ok(pg) =>
                            assertEq(expected = Ok(()), Postgres.ping(pg));
                            let res = DbError.runToResult(() -> Postgres.runWith(pg, () -> {
                                let _ = Migration.runAllPostgres(
                                    List.append(
                                        List.append(JobStore.migrationsPostgres(), Cache.migrations()),
                                        List.append(RateLimiter.migrations(), SessionStore.migrations())
                                    )
                                );
                                Cache.runWithDb(() -> {
                                    assertTrue(Cache.acquireLock("pg-lock", "node-a", 9999999999999i64, 1000i64));
                                    assertFalse(Cache.acquireLock("pg-lock", "node-b", 9999999999999i64, 2000i64));
                                    assertTrue(Cache.releaseLock("pg-lock", "node-a"))
                                });
                                RateLimiter.runWithDb(() -> {
                                    let d1 = RateLimiter.hit("pg-rl-key", 1, 60000i64, 1000i64);
                                    let d2 = RateLimiter.hit("pg-rl-key", 1, 60000i64, 2000i64);
                                    assertTrue(Weft.RateLimitDecision.isAllowed(d1));
                                    assertTrue(Weft.RateLimitDecision.isBlocked(d2));
                                    RateLimiter.reset("pg-rl-key")
                                })
                            }));
                            Postgres.close(pg);
                            assertTrue(Result.isOk(res))
                    }
            }
        }
    }

}
