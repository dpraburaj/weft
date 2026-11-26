mod TestJobs {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Job
    use Weft.JobBackend
    use Weft.JobError
    use Weft.JobQueue
    use Weft.JobRegistry
    use Weft.JobSpec
    use Weft.JobStatus
    use Weft.JobStore
    use Weft.JobWorker
    use Weft.Json
    use Weft.TestEffects
    use Weft.WorkerConfig
    use Weft.WorkerHandle
    use Time.Clock

    import java.lang.InterruptedException
    import java.lang.Thread
    import java.util.concurrent.atomic.AtomicInteger

    ///
    /// 100% PURE test of enqueue, delayed scheduling, queue isolation, and draining!
    /// Zero IO, zero threads, zero sleep — deterministic clock control!
    ///
    @Test
    def testPureEnqueueDelayAndQueueIsolation(): Unit \ Assert = {
        region rc {
            let now = Ref.fresh(rc, 1000i64);
            let processed = Ref.fresh(rc, Nil);
            let reg = JobRegistry.empty()
                |> JobRegistry.register("send.email", job -> {
                    let to = Option.getWithDefault("", Option.flatMap(Json.asString, Json.getField("to", Job.payload(job))));
                    Ref.transform(xs -> to :: xs, processed)
                });

            let cfgDefault = WorkerConfig.default();
            let cfgEmails = WorkerConfig.default() |> WorkerConfig.withQueue("emails");

            let (_, logs) = run {
                // Enqueue at t = 1000ms
                let jNow = JobQueue.dispatch("send.email", Json.obj(("to", Json.str("ada@flix.dev")) :: Nil));
                let jDelayed = JobQueue.dispatchIn(5000i64, "send.email", Json.obj(("to", Json.str("grace@flix.dev")) :: Nil));
                let jOtherQueue = JobQueue.dispatchOn("emails", "send.email", Json.obj(("to", Json.str("alan@flix.dev")) :: Nil));

                assertEq(expected = 1000i64, Job.runAtMs(jNow));
                assertEq(expected = 6000i64, Job.runAtMs(jDelayed));
                assertEq(expected = "emails", Job.queue(jOtherQueue));

                // Drain "default" at t = 1000ms -> only jNow runs; jDelayed is not yet due!
                let n1 = JobWorker.drain(cfgDefault, reg);
                assertEq(expected = 1, n1);
                assertEq(expected = "ada@flix.dev" :: Nil, Ref.get(processed));

                // Advance clock to t = 5999ms -> still not due!
                Ref.put(5999i64, now);
                let n2 = JobWorker.drain(cfgDefault, reg);
                assertEq(expected = 0, n2);

                // Advance clock to t = 6000ms -> jDelayed now runs!
                Ref.put(6000i64, now);
                let n3 = JobWorker.drain(cfgDefault, reg);
                assertEq(expected = 1, n3);
                assertEq(expected = "grace@flix.dev" :: "ada@flix.dev" :: Nil, Ref.get(processed));

                // Drain "emails" queue -> jOtherQueue runs independently!
                let n4 = JobWorker.drain(cfgEmails, reg);
                assertEq(expected = 1, n4);

                let completed = JobStore.listJobs(None, Some(JobStatus.Completed));
                assertEq(expected = 3, List.length(completed))
            } with JobQueue.runWithStore
              with JobStore.runPure
              with TestEffects.runManualClock(now)
              with TestEffects.runCollectingLogger;

            assertEq(expected = 3, List.length(logs))
        }
    }

    ///
    /// 100% PURE test of exponential backoff retries, Abort recovery, and Dead-lettering!
    ///
    @Test
    def testPureRetriesExponentialBackoffAndDeadLetter(): Unit \ Assert = {
        region rc {
            let now = Ref.fresh(rc, 10000i64);
            let reg = JobRegistry.empty()
                |> JobRegistry.register("flaky.job", job -> {
                    JobError.fail("boom on attempt ${Job.attempts(job)}")
                })
                |> JobRegistry.register("aborting.job", _ -> {
                    Abort.abort(RichString.fromString("unexpected abort"))
                });

            let cfg = WorkerConfig.default() |> WorkerConfig.withRetryBackoffMs(1000i64);

            run {
                let job = JobQueue.enqueue(
                    JobSpec.make("flaky.job", Json.obj(Nil)) |> JobSpec.withMaxAttempts(3)
                );

                // Attempt 1 at t=10000 -> fails, rescheduled to 10000 + 1000 = 11000
                assertTrue(JobWorker.runNext(cfg, reg));
                match JobStore.findJob(Job.id(job)) {
                    case None => Assert.fail("Expected job")
                    case Some(j1) =>
                        assertEq(expected = JobStatus.Pending, Job.status(j1));
                        assertEq(expected = 1, Job.attempts(j1));
                        assertEq(expected = 11000i64, Job.runAtMs(j1));
                        assertEq(expected = Some("boom on attempt 1"), Job.lastError(j1))
                };

                // Not due at t=10999
                Ref.put(10999i64, now);
                assertFalse(JobWorker.runNext(cfg, reg));

                // Attempt 2 at t=11000 -> fails, exponential backoff 1000 * 2 = 2000 -> 13000
                Ref.put(11000i64, now);
                assertTrue(JobWorker.runNext(cfg, reg));
                match JobStore.findJob(Job.id(job)) {
                    case None => Assert.fail("Expected job")
                    case Some(j2) =>
                        assertEq(expected = JobStatus.Pending, Job.status(j2));
                        assertEq(expected = 2, Job.attempts(j2));
                        assertEq(expected = 13000i64, Job.runAtMs(j2))
                };

                // Attempt 3 (maxAttempts=3) at t=13000 -> moves to Dead!
                Ref.put(13000i64, now);
                assertTrue(JobWorker.runNext(cfg, reg));
                match JobStore.findJob(Job.id(job)) {
                    case None => Assert.fail("Expected job")
                    case Some(j3) =>
                        assertEq(expected = JobStatus.Dead, Job.status(j3));
                        assertEq(expected = 3, Job.attempts(j3));
                        assertEq(expected = Some("boom on attempt 3"), Job.lastError(j3))
                };

                // Abort inside a job handler with maxAttempts=1 -> caught cleanly and marked Dead
                Ref.put(20000i64, now);
                let abortJob = JobQueue.enqueue(JobSpec.make("aborting.job", Json.obj(Nil)) |> JobSpec.withMaxAttempts(1));
                let _ = JobWorker.runNext(cfg, reg);
                match JobStore.findJob(Job.id(abortJob)) {
                    case None => Assert.fail("Expected abortJob")
                    case Some(ja) =>
                        assertEq(expected = JobStatus.Dead, Job.status(ja));
                        assertTrue(String.contains({substr = "unexpected abort"}, Option.getWithDefault("", Job.lastError(ja))))
                };

                // Unknown job kind -> immediately Dead
                let unknownJob = JobQueue.dispatch("no.such.handler", Json.obj(Nil));
                let _ = JobWorker.runNext(cfg, reg);
                match JobStore.findJob(Job.id(unknownJob)) {
                    case None => Assert.fail("Expected unknownJob")
                    case Some(ju) =>
                        assertEq(expected = JobStatus.Dead, Job.status(ju));
                        assertTrue(String.contains({substr = "No handler registered"}, Option.getWithDefault("", Job.lastError(ju))))
                }
            } with JobQueue.runWithStore
              with JobStore.runPure
              with TestEffects.runManualClock(now)
              with TestEffects.runSilentLogger
        }
    }

    ///
    /// Runs the EXACT same job workflow against BOTH configurable backends:
    /// `JobBackend.inMemory()` AND `JobBackend.sqlite(db)`.
    ///
    def runSharedBackendScenario(backend: JobBackend): Unit \ {Assert, IO} = {
        region rc {
            let now = Ref.fresh(rc, 1000i64);
            let counter = new AtomicInteger(0);
            let reg = JobRegistry.empty()
                |> JobRegistry.register("math.add", job -> {
                    let n = Option.getWithDefault(0, Option.flatMap(Json.asInt, Json.getField("n", Job.payload(job))));
                    if (Job.attempts(job) == 1 and n == 99)
                        JobError.fail("transient failure on first try")
                    else {
                        let _ = counter.addAndGet(n);
                        ()
                    }
                });

            let cfg = WorkerConfig.default() |> WorkerConfig.withRetryBackoffMs(500i64);

            let res = run {
                let _ = JobQueue.dispatch("math.add", Json.obj(("n", Json.int(10)) :: Nil));
                let _ = JobQueue.dispatch("math.add", Json.obj(("n", Json.int(99)) :: Nil));

                // Drain at t=1000 -> job1 completes (+10), job2 fails attempt 1 (scheduled for t=1500)
                let d1 = JobWorker.drain(cfg, reg);
                assertEq(expected = 2, d1);
                assertEq(expected = 10, counter.get());

                // Advance clock to t=1500 -> job2 succeeds on attempt 2 (+99 => total 109)
                Ref.put(1500i64, now);
                let d2 = JobWorker.drain(cfg, reg);
                assertEq(expected = 1, d2);
                assertEq(expected = 109, counter.get());

                let doneJobs = JobStore.listJobs(Some("default"), Some(JobStatus.Completed));
                assertEq(expected = 2, List.length(doneJobs))
            } with JobBackend.runQueue(backend)
              with DbError.runToResult
              with TestEffects.runManualClock(now)
              with TestEffects.runSilentLogger;

            match res {
                case Ok(())           => ()
                case Err((kind, msg)) => Assert.fail("Backend scenario failed (${kind}): ${msg}")
            }
        }
    }

    @Test
    def testConfigurableBackendInMemoryAndSqlite(): Unit \ {Assert, IO} = {
        // 1. Run against InMemory backend
        runSharedBackendScenario(JobBackend.inMemory());

        // 2. Run exact same scenario against SQLite backend
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail(e)
            case Ok(db) =>
                match JobBackend.sqlite(db) {
                    case Err(e) =>
                        Sqlite.close(db);
                        Assert.fail(e)
                    case Ok(sqliteBackend) =>
                        runSharedBackendScenario(sqliteBackend);
                        Sqlite.close(db)
                }
        }
    }

    ///
    /// Live background virtual-thread worker pool test on BOTH `InMemory` and `Sqlite` backends!
    ///
    def runLiveWorkerScenario(backend: JobBackend): Unit \ {Assert, IO} = {
        let doneCount = new AtomicInteger(0);
        let reg = JobRegistry.empty()
            |> JobRegistry.register("bg.work", _ -> {
                let _ = doneCount.incrementAndGet();
                ()
            });

        let cfg = WorkerConfig.default()
            |> WorkerConfig.withConcurrency(2)
            |> WorkerConfig.withPollIntervalMs(20i64);

        // Enqueue 6 jobs
        let enqRes = run {
            List.forEach(i -> {
                let _ = JobQueue.dispatch("bg.work", Json.obj(("idx", Json.int(i)) :: Nil));
                ()
            }, List.range(0, 6))
        } with JobBackend.runQueue(backend)
          with DbError.runToResult
          with Clock.runWithIO;
        assertTrue(Result.isOk(enqRes));

        // Start 2 background virtual-thread workers
        let handle = JobWorker.startBackground(cfg, () -> {
            match run {
                JobWorker.runNext(cfg, reg)
            } with JobBackend.runStore(backend)
              with DbError.runToResult
              with TestEffects.runSilentLogger
              with Clock.runWithIO {
                case Ok(didWork) => didWork
                case Err(_)      => false
            }
        });

        // Wait up to 2 seconds for all 6 jobs to finish
        def waitUntil(remainingTries: Int32): Unit \ IO = {
            if (doneCount.get() >= 6 or remainingTries <= 0)
                ()
            else {
                try { Thread.sleep(20i64) } catch { case _: InterruptedException => () };
                waitUntil(remainingTries - 1)
            }
        };
        waitUntil(100);
        WorkerHandle.stop(handle);

        assertFalse(WorkerHandle.isRunning(handle));
        assertEq(expected = 6, doneCount.get())
    }

    @Test
    def testLiveBackgroundVirtualThreadWorkers(): Unit \ {Assert, IO} = {
        runLiveWorkerScenario(JobBackend.inMemory());

        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail(e)
            case Ok(db) =>
                match JobBackend.sqlite(db) {
                    case Err(e) =>
                        Sqlite.close(db);
                        Assert.fail(e)
                    case Ok(sqliteBackend) =>
                        runLiveWorkerScenario(sqliteBackend);
                        Sqlite.close(db)
                }
        }
    }

}
