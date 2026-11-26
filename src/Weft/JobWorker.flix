pub mod Weft.JobWorker {
    use Weft.Job
    use Weft.JobError
    use Weft.JobRegistry
    use Weft.JobStore
    use Weft.WorkerConfig
    use Weft.WorkerHandle
    use Time.Clock

    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.Runnable
    import java.lang.Thread
    import java.util.concurrent.atomic.AtomicBoolean

    ///
    /// Claims and processes at most one due job from `cfg#queue`.
    ///
    /// - Returns `true` if a job was claimed and processed (succeeded, scheduled for retry, or dead-lettered).
    /// - Returns `false` if no due job was available.
    /// - Completely effect-polymorphic (no `IO` required!) so it runs identically in pure tests and live servers.
    ///
    pub def runNext(
        cfg: WorkerConfig,
        reg: JobRegistry[ef]
    ): Bool \ (ef - JobError - Abort) + {JobStore, Clock, Logger} =
        let now = Clock.now();
        match JobStore.claimNext(WorkerConfig.queue(cfg), now) {
            case None => false
            case Some(job) =>
                let id = Job.id(job);
                let kind = Job.kind(job);
                match JobRegistry.lookup(kind, reg) {
                    case None =>
                        let msg = "No handler registered for job kind '${kind}'";
                        JobStore.markDead(id, msg, Clock.now());
                        Logger.fatal("Job #${id} (${kind}) dead: ${msg}");
                        true
                    case Some(handlerFn) =>
                        let execRes = run {
                            Ok(handlerFn(job))
                        } with handler JobError {
                            def fail(reason, _k) = Err(reason)
                        } with handler Abort {
                            def abort(reason, _k) = Err("Aborted: ${RichString.toString(reason)}")
                        };
                        let doneAt = Clock.now();
                        match execRes {
                            case Ok(()) =>
                                JobStore.markCompleted(id, doneAt);
                                Logger.info("Job #${id} (${kind}) completed (attempt ${Job.attempts(job)}/${Job.maxAttempts(job)})");
                                true
                            case Err(reason) =>
                                if (Job.attempts(job) < Job.maxAttempts(job)) {
                                    let backoff = computeBackoff(WorkerConfig.retryBackoffMs(cfg), Job.attempts(job));
                                    let nextRunAt = doneAt + backoff;
                                    JobStore.markRetry(id, nextRunAt, reason, doneAt);
                                    Logger.warn("Job #${id} (${kind}) failed attempt ${Job.attempts(job)}/${Job.maxAttempts(job)}, retrying in ${backoff}ms: ${reason}");
                                    true
                                } else {
                                    JobStore.markDead(id, reason, doneAt);
                                    Logger.fatal("Job #${id} (${kind}) exhausted ${Job.maxAttempts(job)} attempts -> dead: ${reason}");
                                    true
                                }
                        }
                }
        }

    ///
    /// Processes all currently due jobs in `cfg#queue` until none remain, returning the
    /// number of jobs processed.
    ///
    pub def drain(
        cfg: WorkerConfig,
        reg: JobRegistry[ef]
    ): Int32 \ (ef - JobError - Abort) + {JobStore, Clock, Logger} =
        def loop(processed: Int32) = {
            if (runNext(cfg, reg))
                loop(processed + 1)
            else
                processed
        };
        loop(0)

    ///
    /// Reclaims any jobs stuck in `Running` for longer than `leaseTimeoutMs` milliseconds
    /// (e.g. after a worker crash), resetting them to `Pending` (or `Dead` if max attempts
    /// were exhausted). Returns the number of reclaimed jobs.
    ///
    pub def reclaimStale(leaseTimeoutMs: Int64): Int32 \ {JobStore, Clock} = {
        let now = Clock.now();
        let staleBefore = now - Int64.max(0i64, leaseTimeoutMs);
        JobStore.reclaimStale(staleBefore, now)
    }

    ///
    /// Starts `cfg#concurrency` background Java 21 virtual threads that continuously
    /// invoke `runOnce()` (typically `() -> run { JobWorker.runNext(cfg, reg) } with ...`).
    ///
    /// Sleeps for `cfg#pollIntervalMs` when idle and stops promptly on `WorkerHandle.stop`.
    ///
    pub def startBackground(cfg: WorkerConfig, runOnce: Unit -> Bool \ IO): WorkerHandle \ IO = {
        let running = new AtomicBoolean(true);
        let count = WorkerConfig.concurrency(cfg);
        let pollMs = WorkerConfig.pollIntervalMs(cfg);
        let threads = List.range(0, count) |> List.map(idx -> {
            let task = new Runnable {
                def $run(_this: Runnable): Unit \ IO =
                    workerLoop(running, pollMs, runOnce)
            };
            Thread.ofVirtual().name("weft-worker-${WorkerConfig.queue(cfg)}-${idx}").start(task)
        });
        WorkerHandle.WorkerHandle(running, threads)
    }

    def workerLoop(running: AtomicBoolean, pollMs: Int64, runOnce: Unit -> Bool \ IO): Unit \ IO = {
        if (running.get()) {
            let didWork = try {
                runOnce()
            } catch {
                case _: Exception => false
            };
            if (not didWork and running.get()) {
                try {
                    Thread.sleep(pollMs)
                } catch {
                    case _: InterruptedException => ()
                }
            } else ();
            workerLoop(running, pollMs, runOnce)
        } else {
            ()
        }
    }

    ///
    /// Exponential backoff: `baseMs * 2^(attempt - 1)` capped at 2^10x to avoid overflow.
    ///
    def computeBackoff(baseMs: Int64, attempt: Int32): Int64 =
        let exp = Int32.min(10, Int32.max(0, attempt - 1));
        def pow2(n: Int32, acc: Int64): Int64 =
            if (n <= 0) acc else pow2(n - 1, acc * 2i64);
        baseMs * pow2(exp, 1i64)

}
