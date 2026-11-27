mod TestInfraEffects {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Time.Clock
    use Weft.Body
    use Weft.Cache
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Db
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Email
    use Weft.Html
    use Weft.HttpClient
    use Weft.HttpError
    use Weft.Job
    use Weft.JobQueue
    use Weft.JobRegistry
    use Weft.JobStatus
    use Weft.JobStore
    use Weft.JobWorker
    use Weft.Json
    use Weft.Mailer
    use Weft.MailError
    use Weft.Method
    use Weft.Middleware
    use Weft.Random
    use Weft.RateLimitConfig
    use Weft.RateLimitDecision
    use Weft.RateLimiter
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Schedule
    use Weft.Scheduler
    use Weft.ScheduleStore
    use Weft.StaticConfig
    use Weft.StaticFiles
    use Weft.Status
    use Weft.Storage
    use Weft.StorageError
    use Weft.StorageErrorKind
    use Weft.StoredFile
    use Weft.TestClient
    use Weft.TestEffects
    use Weft.UploadedFile
    use Weft.WorkerConfig
    use Weft.WorkerHandle

    import java.io.{File => JFile}
    import java.lang.System
    import java.lang.Thread

    // =========================================================================
    // 1. RateLimiter Tests (Pure, Middleware, InMemory, SQLite)
    // =========================================================================

    @Test
    def testRateLimiterPureAndMiddleware(): Unit \ Assert = {
        let cfg = RateLimitConfig.make(2, 10000i64) |> RateLimitConfig.withPrefix("api");

        // Pure rate limiter with controllable clock
        region rc {
            let nowRef = Ref.fresh(rc, 1000i64);
            run {
                assertEq(expected = 2, RateLimiter.remaining(cfg, "ip:1.2.3.4"));

                let d1 = RateLimiter.check(cfg, "ip:1.2.3.4");
                assertTrue(RateLimitDecision.isAllowed(d1));
                assertEq(expected = 1, RateLimitDecision.remaining(d1));

                let d2 = RateLimiter.check(cfg, "ip:1.2.3.4");
                assertTrue(RateLimitDecision.isAllowed(d2));
                assertEq(expected = 0, RateLimitDecision.remaining(d2));

                // 3rd attempt in same window is blocked
                let d3 = RateLimiter.check(cfg, "ip:1.2.3.4");
                assertTrue(RateLimitDecision.isBlocked(d3));
                assertEq(expected = 10000i64, RateLimitDecision.retryAfterMs(d3));
                assertEq(expected = 10i64, RateLimitDecision.retryAfterSeconds(d3));

                // Different key is unaffected
                assertTrue(RateLimiter.attempt(cfg, "ip:5.6.7.8"));

                // Advance clock past window -> bucket resets automatically
                Ref.put(12000i64, nowRef);
                assertEq(expected = 2, RateLimiter.remaining(cfg, "ip:1.2.3.4"));
                assertTrue(RateLimiter.attempt(cfg, "ip:1.2.3.4"));

                // Enforce succeeds while under limit, raises 429 via HttpError once exceeded
                let okRes = HttpError.runAsJson(() -> {
                    let _ = RateLimiter.enforce(cfg, "ip:1.2.3.4");
                    Response.ok("allowed")
                });
                assertEq(expected = Status.ok(), Response.status(okRes));
                let errRes = HttpError.runAsJson(() -> {
                    let _ = RateLimiter.enforce(cfg, "ip:1.2.3.4");
                    Response.ok("unreachable")
                });
                assertEq(expected = Status.tooManyRequests(), Response.status(errRes));

                // Clear resets key immediately
                RateLimiter.clear(cfg, "ip:1.2.3.4");
                assertEq(expected = 2, RateLimiter.remaining(cfg, "ip:1.2.3.4"));

                // Prune expired removes stale buckets
                Ref.put(30000i64, nowRef);
                assertEq(expected = 1, RateLimiter.pruneExpired(30000i64))
            } with RateLimiter.runPure
              with handler Clock {
                  def currentTime(_, k) = k(Ref.get(nowRef))
              }
        };

        // Middleware.throttle & throttleRoute
        let routeLimited = Router.empty()
            |> Router.get("/secret", () -> "shh")
            |> Router.withMiddleware(Middleware.throttleRoute(
                RateLimitConfig.make(1, 60000i64) |> RateLimitConfig.withPrefix("secret"),
                () -> Option.getWithDefault("anon", Req.header("X-Api-Key"))
            ));

        let app = Router.empty()
            |> Router.get("/ping", () -> "pong")
            |> Router.merge(routeLimited)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.throttle(RateLimitConfig.make(2, 60000i64));

        run {
            let req1 = Request.get("/ping") |> Request.withHeader("X-Forwarded-For", "10.0.0.1, 10.0.0.2");
            let r1 = app(req1);
            assertEq(expected = Status.ok(), Response.status(r1));
            assertEq(expected = Some("2"), Response.header("X-RateLimit-Limit", r1));
            assertEq(expected = Some("1"), Response.header("X-RateLimit-Remaining", r1));

            let r2 = app(req1);
            assertEq(expected = Status.ok(), Response.status(r2));
            assertEq(expected = Some("0"), Response.header("X-RateLimit-Remaining", r2));

            // 3rd request from same IP -> 429 JSON with Retry-After
            let r3 = app(req1);
            assertEq(expected = Status.tooManyRequests(), Response.status(r3));
            assertEq(expected = Some("60"), Response.header("Retry-After", r3));

            // Browser Accept: text/html gets HTML 429
            let htmlReq = req1 |> Request.withHeader("Accept", "text/html");
            let r4 = app(htmlReq);
            assertEq(expected = Status.tooManyRequests(), Response.status(r4));
            assertTrue(String.contains({substr = "429 Too Many Requests"}, Response.body(r4)));

            // Route-level throttle on /secret with separate IP passes global limit, blocked on 2nd /secret call
            let sReq = Request.get("/secret")
                |> Request.withHeader("X-Real-IP", "10.0.0.99")
                |> Request.withHeader("X-Api-Key", "k1");
            assertEq(expected = Status.ok(), Response.status(app(sReq)));
            assertEq(expected = Status.tooManyRequests(), Response.status(app(sReq)))
        } with RateLimiter.runPure
          with TestEffects.runFixedClock(5000i64)
    }

    @Test
    def testRateLimiterInMemoryAndSqlite(): Unit \ {Assert, IO} = {
        let cfg = RateLimitConfig.make(2, 5000i64);

        // Concurrent InMemory store
        let mem = RateLimiter.makeInMemory();
        run {
            assertTrue(RateLimiter.attempt(cfg, "u1"));
            assertTrue(RateLimiter.attempt(cfg, "u1"));
            assertFalse(RateLimiter.attempt(cfg, "u1"));
            RateLimiter.clear(cfg, "u1");
            assertTrue(RateLimiter.attempt(cfg, "u1"))
        } with RateLimiter.runInMemory(mem)
          with TestEffects.runFixedClock(1000i64);

        // SQLite backend
        let dbRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            RateLimiter.initSchema();
            region rc {
                let nowRef = Ref.fresh(rc, 2000i64);
                run {
                    assertTrue(RateLimiter.attempt(cfg, "u1"));
                    assertTrue(RateLimiter.attempt(cfg, "u1"));
                    assertFalse(RateLimiter.attempt(cfg, "u1"));
                    assertEq(expected = 0, RateLimiter.remaining(cfg, "u1"));

                    // Advance past window
                    Ref.put(8000i64, nowRef);
                    assertEq(expected = 1, RateLimiter.pruneExpired(8000i64));
                    assertTrue(RateLimiter.attempt(cfg, "u1"))
                } with RateLimiter.runWithDb
                  with handler Clock {
                      def currentTime(_, k) = k(Ref.get(nowRef))
                  }
            }
        }));
        match dbRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("RateLimiter SQLite test failed")
        }
    }

    // =========================================================================
    // 2. Cache & Atomic Locks Tests (Pure, InMemory, SQLite)
    // =========================================================================

    @Test
    def testCachePureInMemoryAndSqlite(): Unit \ {Assert, IO} = {
        // Pure cache + TTL + remember + JSON + locks
        region rc {
            let nowRef = Ref.fresh(rc, 1000i64);
            let calls = Ref.fresh(rc, 0);
            run {
                assertEq(expected = None, Cache.get("missing"));
                assertFalse(Cache.has("missing"));

                let v1 = Cache.remember("greeting", 5000i64, () -> {
                    Ref.transform(n -> n + 1, calls);
                    "hello"
                });
                let v2 = Cache.remember("greeting", 5000i64, () -> {
                    Ref.transform(n -> n + 1, calls);
                    "should-not-compute"
                });
                assertEq(expected = "hello", v1);
                assertEq(expected = "hello", v2);
                assertEq(expected = 1, Ref.get(calls));

                // Expire TTL -> recomputes
                Ref.put(6500i64, nowRef);
                let v3 = Cache.remember("greeting", 5000i64, () -> {
                    Ref.transform(n -> n + 1, calls);
                    "recomputed"
                });
                assertEq(expected = "recomputed", v3);
                assertEq(expected = 2, Ref.get(calls));

                // Pull removes after read
                assertEq(expected = Some("recomputed"), Cache.pull("greeting"));
                assertEq(expected = None, Cache.get("greeting"));

                // Forever + JSON
                Cache.putForever("forever", "always");
                let j = Cache.rememberJson("stats", 2000i64, () -> Json.obj(("count", Json.int(42)) :: Nil));
                assertEq(expected = Some(j), Cache.getJson("stats"));
                Ref.put(50000i64, nowRef);
                assertEq(expected = Some("always"), Cache.get("forever"));
                assertEq(expected = None, Cache.getJson("stats"));

                // Atomic locks
                assertTrue(Cache.tryLock("job:invoice", "worker-A", 5000i64));
                assertFalse(Cache.tryLock("job:invoice", "worker-B", 5000i64));
                assertFalse(Cache.unlock("job:invoice", "worker-B"));
                assertTrue(Cache.unlock("job:invoice", "worker-A"));
                assertTrue(Cache.tryLock("job:invoice", "worker-B", 5000i64));

                // Lock expires automatically
                Ref.put(60000i64, nowRef);
                let ran = Cache.withLock("job:invoice", 5000i64, () -> "done");
                assertEq(expected = Some("done"), ran);

                Cache.clear();
                assertEq(expected = None, Cache.get("forever"))
            } with Cache.runPure
              with Random.runDeterministic(42i64)
              with handler Clock {
                  def currentTime(_, k) = k(Ref.get(nowRef))
              }
        };

        // Thread-safe InMemoryCache
        let mem = Cache.makeInMemory();
        run {
            Cache.put("k", "v", 10000i64);
            assertEq(expected = Some("v"), Cache.get("k"));
            assertTrue(Cache.tryLock("l", "o1", 5000i64));
            assertFalse(Cache.tryLock("l", "o2", 5000i64));
            assertTrue(Cache.unlock("l", "o1"))
        } with Cache.runInMemory(mem)
          with TestEffects.runFixedClock(1000i64);

        // SQLite Cache backend
        let dbRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            Cache.initSchema();
            region rc {
                let nowRef = Ref.fresh(rc, 1000i64);
                run {
                    Cache.put("temp", "abc", 3000i64);
                    Cache.putForever("perm", "xyz");
                    assertEq(expected = Some("abc"), Cache.get("temp"));
                    assertEq(expected = Some("xyz"), Cache.get("perm"));

                    assertTrue(Cache.tryLock("db-lock", "owner-1", 2000i64));
                    assertFalse(Cache.tryLock("db-lock", "owner-2", 2000i64));

                    // Expire both temp cache entry and lock
                    Ref.put(5000i64, nowRef);
                    assertEq(expected = 2, Cache.pruneExpired(5000i64));
                    assertEq(expected = None, Cache.get("temp"));
                    assertEq(expected = Some("xyz"), Cache.get("perm"));
                    assertTrue(Cache.tryLock("db-lock", "owner-2", 2000i64));
                    assertTrue(Cache.unlock("db-lock", "owner-2"))
                } with Cache.runWithDb
                  with handler Clock {
                      def currentTime(_, k) = k(Ref.get(nowRef))
                  }
            }
        }));
        match dbRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("Cache SQLite test failed")
        }
    }

    // =========================================================================
    // 3. Scheduler Tests (Cron, Intervals, Overlap Locks, JobQueue, SQLite, Virtual Thread)
    // =========================================================================

    @Test
    def testSchedulerCronIntervalsOverlapAndJobs(): Unit \ {Assert, IO} = {
        // Cron parsing & UTC matching
        // 1970-01-01 02:30:00 UTC is Thursday (dow=4): (2 * 3600 + 30 * 60) * 1000 = 9_000_000ms
        let thu0230 = 9000000i64;
        let thu0230Plus20s = thu0230 + 20000i64;
        let thu0231 = thu0230 + 60000i64;

        match Schedule.cron("30 2 * * 1-5") {
            case Err(e) => Assert.fail("Expected valid cron, got: ${e}")
            case Ok(s) =>
                assertTrue(Schedule.isDue(s, None, thu0230));
                // Already ran in the same minute bucket -> false
                assertFalse(Schedule.isDue(s, Some(thu0230), thu0230Plus20s));
                // Next minute (02:31) doesn't match minute=30 -> false
                assertFalse(Schedule.isDue(s, Some(thu0230), thu0231))
        };
        assertTrue(Result.isErr(Schedule.cron("bad cron")));
        assertTrue(Result.isErr(Schedule.cron("99 * * * *")));

        // Pure Scheduler.tick: intervals, abort isolation, overlap lock, and unique job dispatch
        region rc {
            let nowRef = Ref.fresh(rc, 1000i64);
            let heartbeats = Ref.fresh(rc, 0);
            let guardedRuns = Ref.fresh(rc, 0);

            let sched = Scheduler.empty()
                |> Scheduler.task("heartbeat", Schedule.everySeconds(10i64), () ->
                    Ref.transform(n -> n + 1, heartbeats)
                )
                |> Scheduler.task("flaky", Schedule.everySeconds(10i64), () ->
                    Abort.abortWithTrace("boom")
                )
                |> Scheduler.taskWithoutOverlapping("report", Schedule.everySeconds(5i64), 30000i64, () ->
                    Ref.transform(n -> n + 1, guardedRuns)
                )
                |> Scheduler.dispatchUniqueJob("cleanup", Schedule.everySeconds(10i64), "db.cleanup", Json.obj(Nil));

            assertEq(expected = 4, List.length(Scheduler.describe(sched)));

            let (_, logs) = run {
                // Pre-acquire lock for 'report' to verify withoutOverlapping skips it
                assertTrue(Cache.tryLock("_weft_sched_lock:report", "other-node", 20000i64));

                let ran1 = Scheduler.tick(sched);
                assertEq(expected = "heartbeat" :: "flaky" :: "report" :: "cleanup" :: Nil, ran1);
                assertEq(expected = 1, Ref.get(heartbeats));
                // 'report' skipped inner body because lock was held by other-node
                assertEq(expected = 0, Ref.get(guardedRuns));
                assertEq(expected = 1, List.length(JobStore.listJobs(None, None)));

                // 3 seconds later -> nothing due yet
                Ref.put(4000i64, nowRef);
                assertEq(expected = Nil, Scheduler.tick(sched));

                // Release external lock & advance 10s -> all run, 'report' now executes, unique job deduplicates!
                assertTrue(Cache.unlock("_weft_sched_lock:report", "other-node"));
                Ref.put(11000i64, nowRef);
                let ran2 = Scheduler.tick(sched);
                assertEq(expected = 4, List.length(ran2));
                assertEq(expected = 2, Ref.get(heartbeats));
                assertEq(expected = 1, Ref.get(guardedRuns));
                // Still only 1 pending job because dispatchUniqueJob deduplicated it!
                assertEq(expected = 1, List.length(JobStore.listJobs(None, None)))
            } with TestEffects.runCollectingLogger
              with ScheduleStore.runPure
              with Cache.runPure
              with JobQueue.runWithStore
              with JobStore.runPure
              with handler Clock {
                  def currentTime(_, k) = k(Ref.get(nowRef))
              };

            // Flaky task abort was logged cleanly
            assertTrue(List.exists(match (_, line) -> String.contains({substr = "flaky"}, line), logs))
        };

        // SQLite ScheduleStore persistence
        let dbRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            ScheduleStore.initSchema();
            run {
                assertEq(expected = None, ScheduleStore.getLastRun("nightly"));
                ScheduleStore.recordRun("nightly", 12345i64);
                assertEq(expected = Some(12345i64), ScheduleStore.getLastRun("nightly"));
                ScheduleStore.clearTask("nightly");
                assertEq(expected = None, ScheduleStore.getLastRun("nightly"))
            } with ScheduleStore.runWithDb
        }));
        match dbRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("ScheduleStore SQLite test failed")
        };

        // Background virtual-thread scheduler loop starts and stops cleanly
        let ticks = Ref.fresh(Static, 0);
        let handle = Scheduler.startBackground(15i64, () -> {
            Ref.transform(n -> n + 1, ticks);
            "bg" :: Nil
        });
        Thread.sleep(60i64);
        WorkerHandle.stop(handle);
        assertFalse(WorkerHandle.isRunning(handle));
        assertTrue(Ref.get(ticks) >= 1)
    }

    // =========================================================================
    // 4. Storage Tests (Pure, StaticStore Bridge, InMemory, LocalDir)
    // =========================================================================

    @Test
    def testStoragePureStaticBridgeInMemoryAndLocalDir(): Unit \ {Assert, IO} = {
        // Pure Storage + recording + UploadedFile + traversal protection
        let ((textOut, listed, deleted, badPathStatus, missingStatus), finalFiles) =
            Storage.runPureRecording(Map.empty(), () ->
                TestEffects.runFixedClock(5000i64, () -> {
                    let res = StorageError.runToResult(() -> {
                        Storage.putText("notes/welcome.txt", "hello weft");
                        let up = UploadedFile.make("avatar", "me.png", "image/png", Body.utf8Bytes("PNGDATA"));
                        Storage.putUploaded("uploads/avatars/me.png", up);
                        let t = Storage.getText("notes/welcome.txt");
                        let allUploads = Storage.list("uploads");
                        let del = Storage.delete("notes/welcome.txt");
                        (t, allUploads, del)
                    });
                    let (t, ups, del) = match res {
                        case Ok(triple) => triple
                        case Err((_, e)) =>
                            Assert.fail("Unexpected storage error: ${e}");
                            ("", Nil, false)
                    };

                    // Middleware.storageErrorToHttp maps InvalidPath -> 400 and NotFound -> 404
                    let app = Router.empty()
                        |> Router.get("/read", () -> {
                            let p = Option.getWithDefault("", Req.queryParam("p"));
                            Storage.getText(p)
                        })
                        |> Router.toApp
                        |> Middleware.storageErrorToHttp
                        |> Middleware.errorJson;

                    let badRes = TestClient.get("/read?p=../etc/passwd", app);
                    let missRes = TestClient.get("/read?p=does/not/exist.txt", app);
                    (t, ups, del, Response.status(badRes), Response.status(missRes))
                })
            );

        assertEq(expected = "hello weft", textOut);
        assertEq(expected = 1, List.length(listed));
        assertEq(expected = true, deleted);
        assertEq(expected = Status.badRequest(), badPathStatus);
        assertEq(expected = Status.notFound(), missingStatus);
        assertFalse(Map.memberOf("notes/welcome.txt", finalFiles));
        assertTrue(Map.memberOf("uploads/avatars/me.png", finalFiles));

        // Storage -> StaticStore bridge serves uploaded files with MIME + ETag + 304!
        let staticApp = StaticFiles.routes("/assets", StaticConfig.default())
            |> Router.toApp
            |> Middleware.errorJson;

        run {
            let _ = StorageError.runToResult(() -> Storage.putText("css/app.css", "body{color:red}"));
            let r1 = TestClient.get("/assets/css/app.css", staticApp);
            assertEq(expected = Status.ok(), Response.status(r1));
            assertEq(expected = Some("text/css; charset=utf-8"), Response.header("Content-Type", r1));
            assertEq(expected = "body{color:red}", Response.body(r1));
            match Response.header("ETag", r1) {
                case None => Assert.fail("Expected ETag header")
                case Some(etag) =>
                    let req304 = Request.get("/assets/css/app.css") |> Request.withHeader("If-None-Match", etag);
                    let r2 = staticApp(req304);
                    assertEq(expected = Status.notModified(), Response.status(r2))
            }
        } with Storage.runStaticStore
          with Storage.runPure(Map.empty())
          with TestEffects.runFixedClock(9000i64);

        // Concurrent InMemoryStorage
        let mem = Storage.makeInMemory();
        run {
            let r = StorageError.runToResult(() -> {
                Storage.putText("a/b.txt", "mem-data");
                assertTrue(Storage.exists("a/b.txt"));
                assertEq(expected = "mem-data", Storage.getText("a/b.txt"));
                assertEq(expected = 1, List.length(Storage.list("a")));
                assertTrue(Storage.delete("a/b.txt"));
                assertFalse(Storage.exists("a/b.txt"))
            });
            assertTrue(Result.isOk(r))
        } with Storage.runInMemory(mem)
          with TestEffects.runFixedClock(1000i64);

        // Local filesystem backend in a temporary directory
        let tmpRoot = System.getProperty("java.io.tmpdir");
        let tmpDirFile = new JFile(tmpRoot, "weft-storage-test-${System.nanoTime()}");
        let _ = tmpDirFile.mkdirs();
        let tmpDirStr = tmpDirFile.getAbsolutePath();
        run {
            let r = StorageError.runToResult(() -> {
                Storage.putText("nested/dir/hello.txt", "on-disk");
                assertTrue(Storage.exists("nested/dir/hello.txt"));
                assertEq(expected = "on-disk", Storage.getText("nested/dir/hello.txt"));
                let info = Storage.stat("nested/dir/hello.txt");
                assertEq(expected = 7i64, StoredFile.sizeBytes(info));
                assertEq(expected = "text/plain; charset=utf-8", StoredFile.contentType(info));
                let files = Storage.list("nested");
                assertEq(expected = 1, List.length(files));
                assertTrue(Storage.delete("nested/dir/hello.txt"));
                assertFalse(Storage.exists("nested/dir/hello.txt"))
            });
            assertTrue(Result.isOk(r));

            // Traversal rejected on local dir too
            let trav = StorageError.runToResult(() -> Storage.putText("../escape.txt", "nope"));
            match trav {
                case Err((StorageErrorKind.InvalidPath, _)) => ()
                case _ => Assert.fail("Expected InvalidPath for traversal on local dir")
            }
        } with Storage.runLocalDir(tmpDirStr)
          with TestEffects.runFixedClock(1000i64);
        deleteRecursive(tmpDirFile)
    }

    def deleteRecursive(f: JFile): Unit \ IO = {
        if (f.isDirectory()) {
            let kids: Array[JFile, IO] = f.listFiles();
            if (not Object.isNull(kids)) {
                let len = Array.length(kids);
                def loop(i: Int32): Unit \ IO =
                    if (i >= len) ()
                    else {
                        deleteRecursive(Array.get(i, kids));
                        loop(i + 1)
                    };
                loop(0)
            } else ()
        } else ();
        let _ = f.delete();
        ()
    }

    // =========================================================================
    // 5. Mailer Tests (Recording, Logging, Resend/HttpClient, MailError, JobQueue)
    // =========================================================================

    @Test
    def testMailerRecordingLoggingResendAndQueuedJobs(): Unit \ Assert = {
        let htmlDoc = Html.render(() -> Html.pText("Welcome aboard!"));
        let welcome = Email.make("no-reply@weft.dev", "alice@example.com", "Welcome!")
            |> Email.addTo("bob@example.com")
            |> Email.withCc("team@weft.dev" :: Nil)
            |> Email.withReplyTo("support@weft.dev")
            |> Email.withText("Welcome aboard!")
            |> Email.withHtml(htmlDoc)
            |> Email.withHeader("X-Campaign", "onboarding");

        // JSON round-trip
        match Email.fromJson(Email.toJson(welcome)) {
            case Ok(decoded) => assertEq(expected = welcome, decoded)
            case Err(e)      => Assert.fail("Email JSON round-trip failed: ${e}")
        };

        // 1. Mailer.runRecording (Mail::fake())
        let (msgIdRes, sent) = Mailer.runRecording(() ->
            MailError.runToResult(() -> Mailer.send(welcome))
        );
        assertEq(expected = Ok("msg-1"), msgIdRes);
        assertEq(expected = 1, List.length(sent));
        assertEq(expected = Some(welcome), List.head(sent));

        // 2. Mailer.runFailing + Middleware.mailErrorToHttp -> 502 Bad Gateway
        let mailApp = Router.empty()
            |> Router.post("/send", () -> Mailer.send(welcome))
            |> Router.toApp
            |> Middleware.mailErrorToHttp
            |> Middleware.errorJson;
        let failRes = Mailer.runFailing("SMTP refused", () -> TestClient.postJson("/send", Json.obj(Nil), mailApp));
        assertEq(expected = Status.badGateway(), Response.status(failRes));

        // 3. Mailer.runLogging
        let (logRes, logs) = TestEffects.runCollectingLogger(() ->
            Mailer.runLogging(() -> MailError.runToResult(() -> Mailer.send(welcome)))
        );
        assertEq(expected = Ok("log-1"), logRes);
        assertTrue(List.exists(match (_, l) -> String.contains({substr = "Welcome!"}, l), logs));

        // 4. Mailer.runWithResend backed purely by HttpClient.runRecording
        let resendResponder = _req ->
            Ok(ClientResponse.json(200, Json.obj(("id", Json.str("re_abc123")) :: Nil)));
        let (resendId, httpReqs) = HttpClient.runRecording(resendResponder, () ->
            Mailer.runWithResend("re_key_secret", () ->
                MailError.runToResult(() -> Mailer.send(welcome))
            )
        );
        assertEq(expected = Ok("re_abc123"), resendId);
        assertEq(expected = 1, List.length(httpReqs));
        match List.head(httpReqs) {
            case None => Assert.fail("Expected Resend HTTP request")
            case Some(r) =>
                assertEq(expected = Method.Post, ClientRequest.method(r));
                assertEq(expected = "https://api.resend.com/emails", ClientRequest.url(r));
                assertEq(expected = Some("Bearer re_key_secret"), ClientRequest.header("Authorization", r))
        };

        // 5. Async email delivery via JobQueue (Mailer.queue + Mailer.registerJobHandler + JobWorker.drain)
        let reg = JobRegistry.empty() |> Mailer.registerJobHandler;
        let (((processedCount, jobStatus), _jobLogs), queuedSent) = Mailer.runRecording(() ->
            run {
                let job = Mailer.queue(welcome);
                let n = JobWorker.drain(WorkerConfig.default(), reg);
                let st = Option.map(Job.status, JobStore.findJob(Job.id(job)));
                (n, st)
            } with TestEffects.runCollectingLogger
              with JobQueue.runWithStore
              with JobStore.runPure
              with TestEffects.runFixedClock(1000i64)
        );
        assertEq(expected = 1, processedCount);
        assertEq(expected = Some(JobStatus.Completed), jobStatus);
        assertEq(expected = 1, List.length(queuedSent))
    }

}
