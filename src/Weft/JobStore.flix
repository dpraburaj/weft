pub mod Weft.JobStore {
    use Weft.Db
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.InMemoryJobStore
    use Weft.Job
    use Weft.JobSpec
    use Weft.JobStatus
    use Weft.JobStore
    use Weft.Json
    use Weft.Migration
    use Weft.Row
    use Weft.SqlValue

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Pluggable job storage backend effect (`JobStore.runPure`, `JobStore.runInMemory`,
    /// or `JobStore.runWithDb` + `Sqlite.runWith`).
    ///
    pub eff JobStore {
        def insertJob(spec: JobSpec, nowMs: Int64): Job
        def claimNext(queue: String, nowMs: Int64): Option[Job]
        def markCompleted(id: Int64, nowMs: Int64): Unit
        def markRetry(id: Int64, nextRunAtMs: Int64, error: String, nowMs: Int64): Unit
        def markDead(id: Int64, error: String, nowMs: Int64): Unit
        def findJob(id: Int64): Option[Job]
        def listJobs(queue: Option[String], status: Option[JobStatus]): List[Job]
    }

    // --- 1. Pure Region-Scoped Backend (Zero IO!) ---

    ///
    /// 100% pure in-memory `JobStore` handler backed by a local `region rc`.
    /// Ideal for deterministic, zero-IO unit tests!
    ///
    pub def runPure(f: Unit -> a \ ef): a \ (ef - JobStore) =
        region rc {
            let nextId = Ref.fresh(rc, 1i64);
            let jobs = Ref.fresh(rc, Map.empty());
            run {
                f()
            } with handler JobStore {
                def insertJob(spec, nowMs, k) = {
                    let id = Ref.get(nextId);
                    Ref.put(id + 1i64, nextId);
                    let job = buildNewJob(id, spec, nowMs);
                    Ref.transform(m -> Map.insert(id, job, m), jobs);
                    k(job)
                }
                def claimNext(queue, nowMs, k) = {
                    let m = Ref.get(jobs);
                    match pickNextDue(queue, nowMs, Map.valuesOf(m)) {
                        case None => k(None)
                        case Some(j) =>
                            let claimed = transitionRunning(j, nowMs);
                            Ref.put(Map.insert(Job.id(claimed), claimed, m), jobs);
                            k(Some(claimed))
                    }
                }
                def markCompleted(id, nowMs, k) = {
                    Ref.transform(m -> updateJobInMap(id, j -> transitionCompleted(j, nowMs), m), jobs);
                    k()
                }
                def markRetry(id, nextRunAtMs, err, nowMs, k) = {
                    Ref.transform(m -> updateJobInMap(id, j -> transitionRetry(j, nextRunAtMs, err, nowMs), m), jobs);
                    k()
                }
                def markDead(id, err, nowMs, k) = {
                    Ref.transform(m -> updateJobInMap(id, j -> transitionDead(j, err, nowMs), m), jobs);
                    k()
                }
                def findJob(id, k) =
                    k(Map.get(id, Ref.get(jobs)))
                def listJobs(qOpt, stOpt, k) =
                    let filtered = filterAndSortJobs(qOpt, stOpt, Map.valuesOf(Ref.get(jobs)));
                    k(filtered)
            }
        }

    // --- 2. Thread-Safe Concurrent In-Memory Backend ---

    ///
    /// Creates a new thread-safe in-memory job store for concurrent virtual-thread servers & workers.
    ///
    pub def makeInMemory(): InMemoryJobStore \ IO =
        InMemoryJobStore.InMemoryJobStore(
            new ReentrantLock(),
            Ref.fresh(Static, 1i64),
            Ref.fresh(Static, Map.empty())
        )

    def withLock(lock: ReentrantLock, action: Unit -> b \ IO): b \ IO = {
        lock.lock();
        try {
            let r = action();
            lock.unlock();
            r
        } catch {
            case ex: Exception =>
                lock.unlock();
                throw ex
        }
    }

    ///
    /// Handles `JobStore` against a shared thread-safe `InMemoryJobStore`.
    ///
    pub def runInMemory(store: InMemoryJobStore, f: Unit -> a \ ef): a \ (ef - JobStore) + IO =
        let InMemoryJobStore.InMemoryJobStore(lock, nextId, jobs) = store;
        run {
            f()
        } with handler JobStore {
            def insertJob(spec, nowMs, k) = {
                let job = withLock(lock, () -> {
                    let id = Ref.get(nextId);
                    Ref.put(id + 1i64, nextId);
                    let j = buildNewJob(id, spec, nowMs);
                    Ref.transform(m -> Map.insert(id, j, m), jobs);
                    j
                });
                k(job)
            }
            def claimNext(queue, nowMs, k) = {
                let claimedOpt = withLock(lock, () -> {
                    let m = Ref.get(jobs);
                    match pickNextDue(queue, nowMs, Map.valuesOf(m)) {
                        case None => None
                        case Some(j) =>
                            let claimed = transitionRunning(j, nowMs);
                            Ref.put(Map.insert(Job.id(claimed), claimed, m), jobs);
                            Some(claimed)
                    }
                });
                k(claimedOpt)
            }
            def markCompleted(id, nowMs, k) = {
                withLock(lock, () ->
                    Ref.transform(m -> updateJobInMap(id, j -> transitionCompleted(j, nowMs), m), jobs)
                );
                k()
            }
            def markRetry(id, nextRunAtMs, err, nowMs, k) = {
                withLock(lock, () ->
                    Ref.transform(m -> updateJobInMap(id, j -> transitionRetry(j, nextRunAtMs, err, nowMs), m), jobs)
                );
                k()
            }
            def markDead(id, err, nowMs, k) = {
                withLock(lock, () ->
                    Ref.transform(m -> updateJobInMap(id, j -> transitionDead(j, err, nowMs), m), jobs)
                );
                k()
            }
            def findJob(id, k) = {
                let opt = withLock(lock, () -> Map.get(id, Ref.get(jobs)));
                k(opt)
            }
            def listJobs(qOpt, stOpt, k) = {
                let list = withLock(lock, () -> filterAndSortJobs(qOpt, stOpt, Map.valuesOf(Ref.get(jobs))));
                k(list)
            }
        }

    // --- 3. Driver-Agnostic SQL Backend (Works with SQLite & Future DBs!) ---

    ///
    /// Schema migration creating the `_weft_jobs` table and due-job index.
    /// Run via `Migration.runAll(JobStore.migrations())` (or `JobStore.initSchema()`).
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1001,
            "create_weft_jobs_table",
            "CREATE TABLE IF NOT EXISTS _weft_jobs (" +
            "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
            "queue TEXT NOT NULL, " +
            "kind TEXT NOT NULL, " +
            "payload TEXT NOT NULL, " +
            "status TEXT NOT NULL, " +
            "attempts INTEGER NOT NULL DEFAULT 0, " +
            "max_attempts INTEGER NOT NULL DEFAULT 3, " +
            "run_at_ms INTEGER NOT NULL, " +
            "last_error TEXT, " +
            "created_at_ms INTEGER NOT NULL, " +
            "updated_at_ms INTEGER NOT NULL);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_jobs_due ON _weft_jobs (queue, status, run_at_ms, id)"
        ) :: Nil

    ///
    /// Applies the `_weft_jobs` schema migration idempotently.
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// Handles `JobStore` using the driver-agnostic `Db` effect (e.g. `Sqlite.runWith(db)`).
    /// `claimNext` executes atomically inside `Db.transaction` so concurrent workers
    /// never claim the same job twice!
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - JobStore) + {Db, DbError} =
        run {
            f()
        } with handler JobStore {
            def insertJob(spec, nowMs, k) = {
                let runAt = nowMs + JobSpec.delayMs(spec);
                let payloadStr = Json.encode(JobSpec.payload(spec));
                let id = Db.insertAndGetId(
                    "INSERT INTO _weft_jobs (queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms) " +
                    "VALUES (?, ?, ?, 'pending', 0, ?, ?, NULL, ?, ?)",
                    SqlValue.text(JobSpec.queue(spec)) ::
                    SqlValue.text(JobSpec.kind(spec)) ::
                    SqlValue.text(payloadStr) ::
                    SqlValue.int(JobSpec.maxAttempts(spec)) ::
                    SqlValue.int64(runAt) ::
                    SqlValue.int64(nowMs) ::
                    SqlValue.int64(nowMs) ::
                    Nil
                );
                k(buildNewJob(id, spec, nowMs))
            }

            def claimNext(queue, nowMs, k) = {
                let claimed = Db.transaction(() -> {
                    match Db.queryOneMap(
                        "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                        "FROM _weft_jobs WHERE queue = ? AND status = 'pending' AND run_at_ms <= ? " +
                        "ORDER BY run_at_ms ASC, id ASC LIMIT 1",
                        SqlValue.text(queue) :: SqlValue.int64(nowMs) :: Nil,
                        decodeJobRow
                    ) {
                        case None => None
                        case Some(j) =>
                            let nextJob = transitionRunning(j, nowMs);
                            let _ = Db.execute(
                                "UPDATE _weft_jobs SET status = 'running', attempts = ?, updated_at_ms = ? WHERE id = ?",
                                SqlValue.int(Job.attempts(nextJob)) :: SqlValue.int64(nowMs) :: SqlValue.int64(Job.id(nextJob)) :: Nil
                            );
                            Some(nextJob)
                    }
                });
                k(claimed)
            }

            def markCompleted(id, nowMs, k) = {
                let _ = Db.execute(
                    "UPDATE _weft_jobs SET status = 'completed', updated_at_ms = ? WHERE id = ?",
                    SqlValue.int64(nowMs) :: SqlValue.int64(id) :: Nil
                );
                k()
            }

            def markRetry(id, nextRunAtMs, err, nowMs, k) = {
                let _ = Db.execute(
                    "UPDATE _weft_jobs SET status = 'pending', run_at_ms = ?, last_error = ?, updated_at_ms = ? WHERE id = ?",
                    SqlValue.int64(nextRunAtMs) :: SqlValue.text(err) :: SqlValue.int64(nowMs) :: SqlValue.int64(id) :: Nil
                );
                k()
            }

            def markDead(id, err, nowMs, k) = {
                let _ = Db.execute(
                    "UPDATE _weft_jobs SET status = 'dead', last_error = ?, updated_at_ms = ? WHERE id = ?",
                    SqlValue.text(err) :: SqlValue.int64(nowMs) :: SqlValue.int64(id) :: Nil
                );
                k()
            }

            def findJob(id, k) = {
                let found = Db.queryOneMap(
                    "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                    "FROM _weft_jobs WHERE id = ?",
                    SqlValue.int64(id) :: Nil,
                    decodeJobRow
                );
                k(found)
            }

            def listJobs(qOpt, stOpt, k) = {
                let rows = match (qOpt, stOpt) {
                    case (None, None) =>
                        Db.queryMap(
                            "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                            "FROM _weft_jobs ORDER BY id ASC",
                            Nil,
                            decodeJobRow
                        )
                    case (Some(q), None) =>
                        Db.queryMap(
                            "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                            "FROM _weft_jobs WHERE queue = ? ORDER BY id ASC",
                            SqlValue.text(q) :: Nil,
                            decodeJobRow
                        )
                    case (None, Some(st)) =>
                        Db.queryMap(
                            "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                            "FROM _weft_jobs WHERE status = ? ORDER BY id ASC",
                            SqlValue.text("${st}") :: Nil,
                            decodeJobRow
                        )
                    case (Some(q), Some(st)) =>
                        Db.queryMap(
                            "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, created_at_ms, updated_at_ms " +
                            "FROM _weft_jobs WHERE queue = ? AND status = ? ORDER BY id ASC",
                            SqlValue.text(q) :: SqlValue.text("${st}") :: Nil,
                            decodeJobRow
                        )
                };
                k(rows)
            }
        }

    // --- Shared Pure State Transitions & Row Decoder ---

    def buildNewJob(id: Int64, spec: JobSpec, nowMs: Int64): Job =
        Job.Job({
            id          = id,
            queue       = JobSpec.queue(spec),
            kind        = JobSpec.kind(spec),
            payload     = JobSpec.payload(spec),
            status      = JobStatus.Pending,
            attempts    = 0,
            maxAttempts = JobSpec.maxAttempts(spec),
            runAtMs     = nowMs + JobSpec.delayMs(spec),
            lastError   = None,
            createdAtMs = nowMs,
            updatedAtMs = nowMs
        })

    def transitionRunning(j: Job, nowMs: Int64): Job =
        let Job.Job(r) = j;
        Job.Job({ status = JobStatus.Running, attempts = r#attempts + 1, updatedAtMs = nowMs | r })

    def transitionCompleted(j: Job, nowMs: Int64): Job =
        let Job.Job(r) = j;
        Job.Job({ status = JobStatus.Completed, updatedAtMs = nowMs | r })

    def transitionRetry(j: Job, nextRunAtMs: Int64, err: String, nowMs: Int64): Job =
        let Job.Job(r) = j;
        Job.Job({ status = JobStatus.Pending, runAtMs = nextRunAtMs, lastError = Some(err), updatedAtMs = nowMs | r })

    def transitionDead(j: Job, err: String, nowMs: Int64): Job =
        let Job.Job(r) = j;
        Job.Job({ status = JobStatus.Dead, lastError = Some(err), updatedAtMs = nowMs | r })

    def updateJobInMap(id: Int64, f: Job -> Job, m: Map[Int64, Job]): Map[Int64, Job] =
        match Map.get(id, m) {
            case Some(j) => Map.insert(id, f(j), m)
            case None    => m
        }

    def pickNextDue(queue: String, nowMs: Int64, jobs: List[Job]): Option[Job] =
        jobs
            |> List.filter(j -> Job.queue(j) == queue and Job.status(j) == JobStatus.Pending and Job.runAtMs(j) <= nowMs)
            |> List.sortBy(j -> (Job.runAtMs(j), Job.id(j)))
            |> List.head

    def filterAndSortJobs(qOpt: Option[String], stOpt: Option[JobStatus], jobs: List[Job]): List[Job] =
        jobs
            |> List.filter(j -> match qOpt {
                case Some(q) => Job.queue(j) == q
                case None    => true
            })
            |> List.filter(j -> match stOpt {
                case Some(st) => Job.status(j) == st
                case None     => true
            })
            |> List.sortBy(Job.id)

    def decodeJobRow(row: Row): Job \ DbError = {
        let payloadRaw = Row.requireString("payload", row);
        let payloadJson = match Json.parse(payloadRaw) {
            case Ok(j)    => j
            case Err(msg) => DbError.raise(DbErrorKind.ColumnDecodeError, "Invalid job payload JSON: ${msg}")
        };
        let statusRaw = Row.requireString("status", row);
        let statusVal = match Weft.JobStatus.parse(statusRaw) {
            case Some(st) => st
            case None     => DbError.raise(DbErrorKind.ColumnDecodeError, "Unknown job status '${statusRaw}'")
        };
        Job.Job({
            id          = Row.requireInt64("id", row),
            queue       = Row.requireString("queue", row),
            kind        = Row.requireString("kind", row),
            payload     = payloadJson,
            status      = statusVal,
            attempts    = Row.requireInt("attempts", row),
            maxAttempts = Row.requireInt("max_attempts", row),
            runAtMs     = Row.requireInt64("run_at_ms", row),
            lastError   = Row.optionalString("last_error", row),
            createdAtMs = Row.requireInt64("created_at_ms", row),
            updatedAtMs = Row.requireInt64("updated_at_ms", row)
        })
    }

}
