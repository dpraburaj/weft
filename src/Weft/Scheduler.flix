pub mod Weft.Scheduler {
    use Time.Clock
    use Weft.Cache
    use Weft.JobQueue
    use Weft.Json
    use Weft.Schedule
    use Weft.ScheduledTask
    use Weft.Scheduler
    use Weft.ScheduleStore
    use Weft.WorkerHandle

    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.Runnable
    import java.lang.Thread
    import java.util.concurrent.atomic.AtomicBoolean

    ///
    /// An immutable, effect-polymorphic recurring task scheduler (inspired by Laravel's
    /// task scheduling).
    ///
    /// Tasks accumulate their effect row via Boolean union (`ef1 + ef2`) just like
    /// `Router[ef]` and `JobRegistry[ef]`. `Scheduler.tick` runs 100% purely in tests
    /// with `ScheduleStore.runPure` and deterministic `Clock`, or continuously on a
    /// Java 21 virtual thread via `Scheduler.startBackground`.
    ///
    pub enum Scheduler[ef: Eff] {
        case Scheduler(List[ScheduledTask[ef]])
    }

    ///
    /// Returns an empty pure scheduler (`Scheduler[{}]`).
    ///
    pub def empty(): Scheduler[{}] =
        Scheduler.Scheduler(Nil)

    ///
    /// Registers a named recurring task running `action` whenever `sched` is due.
    ///
    pub def task(
        name: String,
        sched: Schedule,
        action: Unit -> Unit \ ef1,
        s: Scheduler[ef2]
    ): Scheduler[ef1 + ef2] = {
        let Scheduler.Scheduler(existing) = s;
        let widened = List.map(widenTask, existing);
        let newTask: ScheduledTask[ef1 + ef2] =
            ScheduledTask.make(name, sched, () -> checked_ecast(action()));
        Scheduler.Scheduler(List.append(widened, newTask :: Nil))
    }

    ///
    /// Registers a recurring task guarded by an atomic `Cache` lock (`lockTtlMs`) so
    /// concurrent scheduler ticks or nodes never execute the same task simultaneously
    /// (like Laravel's `->withoutOverlapping()`).
    ///
    pub def taskWithoutOverlapping(
        name: String,
        sched: Schedule,
        lockTtlMs: Int64,
        action: Unit -> Unit \ ef1,
        s: Scheduler[ef2]
    ): Scheduler[ef1 + ef2 + {Cache, Clock}] = {
        let lockKey = "_weft_sched_lock:${name}";
        let guarded: Unit -> Unit \ ef1 + {Cache, Clock} = () -> {
            let owner = "sched:${name}:${Clock.now()}";
            let _ = Cache.withLockOwner(lockKey, owner, lockTtlMs, () -> action());
            ()
        };
        task(name, sched, guarded, s)
    }

    ///
    /// Registers a recurring task that dispatches a background job via `JobQueue`
    /// whenever `sched` is due (like Laravel's `Schedule::job(...)`).
    ///
    pub def dispatchJob(
        name: String,
        sched: Schedule,
        kind: String,
        payload: Json,
        s: Scheduler[ef]
    ): Scheduler[ef + JobQueue] =
        task(name, sched, () -> {
            let _ = JobQueue.dispatch(kind, payload);
            ()
        }, s)

    ///
    /// Registers a recurring task that dispatches an idempotent `uniqueKey` background job
    /// (`"sched:<name>"`) so queued work never piles up if a previous run is still pending/running.
    ///
    pub def dispatchUniqueJob(
        name: String,
        sched: Schedule,
        kind: String,
        payload: Json,
        s: Scheduler[ef]
    ): Scheduler[ef + JobQueue] =
        task(name, sched, () -> {
            let _ = JobQueue.dispatchUnique("sched:${name}", kind, payload);
            ()
        }, s)

    ///
    /// Returns `(taskName, scheduleDescription)` pairs for all registered tasks.
    ///
    pub def describe(s: Scheduler[ef]): List[(String, String)] = {
        let Scheduler.Scheduler(tasks) = s;
        List.map(t -> (ScheduledTask.name(t), "${ScheduledTask.schedule(t)}"), tasks)
    }

    ///
    /// Evaluates every registered task against `Clock.now()` and `ScheduleStore`, running
    /// all due tasks in registration order.
    ///
    /// - Catches `Abort` per task and logs failures via `Logger` so one failing task
    ///   never prevents subsequent tasks from running.
    /// - Records each executed task's timestamp in `ScheduleStore`.
    /// - Returns the list of task names that executed during this tick.
    ///
    pub def tick(s: Scheduler[ef]): List[String] \ (ef - Abort) + {ScheduleStore, Clock, Logger} = {
        let Scheduler.Scheduler(tasks) = s;
        let nowMs = Clock.now();
        List.foldLeft((ranAcc, t) -> {
            let tName = ScheduledTask.name(t);
            let lastRun = ScheduleStore.getLastRun(tName);
            if (Schedule.isDue(ScheduledTask.schedule(t), lastRun, nowMs)) {
                ScheduleStore.recordRun(tName, nowMs);
                let res = Abort.runWithResult(() -> (ScheduledTask.action(t))());
                match res {
                    case Ok(()) =>
                        Logger.info("Scheduled task '${tName}' completed")
                    case Err(reason) =>
                        Logger.fatal("Scheduled task '${tName}' aborted: ${RichString.toString(reason)}")
                };
                tName :: ranAcc
            } else {
                ranAcc
            }
        }, Nil, tasks) |> List.reverse
    }

    ///
    /// Starts a single Java 21 virtual thread (`weft-scheduler`) that invokes `runTick()`
    /// every `pollIntervalMs` milliseconds until `WorkerHandle.stop` is called.
    ///
    pub def startBackground(pollIntervalMs: Int64, runTick: Unit -> List[String] \ IO): WorkerHandle \ IO = {
        let running = new AtomicBoolean(true);
        let safePoll = Int64.max(10i64, pollIntervalMs);
        let taskRunnable = new Runnable {
            def $run(_this: Runnable): Unit \ IO =
                schedulerLoop(running, safePoll, runTick)
        };
        let thread = Thread.ofVirtual().name("weft-scheduler").start(taskRunnable);
        WorkerHandle.WorkerHandle(running, thread :: Nil)
    }

    def schedulerLoop(running: AtomicBoolean, pollMs: Int64, runTick: Unit -> List[String] \ IO): Unit \ IO = {
        if (running.get()) {
            let _ = try {
                runTick()
            } catch {
                case _: Exception => Nil
            };
            if (running.get()) {
                try {
                    Thread.sleep(pollMs)
                } catch {
                    case _: InterruptedException => ()
                }
            } else ();
            schedulerLoop(running, pollMs, runTick)
        } else {
            ()
        }
    }

    def widenTask(t: ScheduledTask[ef1]): ScheduledTask[ef1 + ef2] =
        ScheduledTask.make(
            ScheduledTask.name(t),
            ScheduledTask.schedule(t),
            () -> checked_ecast((ScheduledTask.action(t))())
        )

}
