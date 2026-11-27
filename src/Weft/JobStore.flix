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
        def reclaimStale(staleBeforeMs: Int64, nowMs: Int64): Int32
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
                    let current = Ref.get(jobs);
                    match findActiveByUniqueKey(JobSpec.uniqueKey(spec), Map.valuesOf(current)) {
                        case Some(existing) =>
                            k(existing)
                        case None =>
                            let id = Ref.get(nextId);
                            Ref.put(id + 1i64, nextId);
                            let job = buildNewJob(id, spec, nowMs);
                            Ref.put(Map.insert(id, job, current), jobs);
                            k(job)
                    }
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
                def reclaimStale(staleBeforeMs, nowMs, k) = {
                    let (nextMap, count) = reclaimStaleInMap(staleBeforeMs, nowMs, Ref.get(jobs));
                    Ref.put(nextMap, jobs);
                    k(count)
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
                    let current = Ref.get(jobs);
                    match findActiveByUniqueKey(JobSpec.uniqueKey(spec), Map.valuesOf(current)) {
                        case Some(existing) => existing
                        case None =>
                            let id = Ref.get(nextId);
                            Ref.put(id + 1i64, nextId);
                            let j = buildNewJob(id, spec, nowMs);
                            Ref.put(Map.insert(id, j, current), jobs);
                            j
                    }
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
            def reclaimStale(staleBeforeMs, nowMs, k) = {
                let count = withLock(lock, () -> {
                    let (nextMap, n) = reclaimStaleInMap(staleBeforeMs, nowMs, Ref.get(jobs));
                    Ref.put(nextMap, jobs);
                    n
                });
                k(count)
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

    def selectCols(): String =
        "SELECT id, queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, unique_key, created_at_ms, updated_at_ms FROM _weft_jobs"

    ///
    /// Schema migrations creating the `_weft_jobs` table, due-job index, and `unique_key` index.
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
        ) ::
        Migration.make(
            1003,
            "add_weft_jobs_unique_key",
            "ALTER TABLE _weft_jobs ADD COLUMN unique_key TEXT;" +
            "CREATE INDEX IF NOT EXISTS idx_weft_jobs_unique_key ON _weft_jobs (unique_key, status)"
        ) ::
        Nil

    ///
    /// Applies the `_weft_jobs` schema migrations idempotently (SQLite dialect).
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// PostgreSQL-compatible schema migrations creating `_weft_jobs` (`BIGSERIAL`, `BIGINT`).
    ///
    pub def migrationsPostgres(): List[Migration] =
        Migration.make(
            1001,
            "create_weft_jobs_table",
            "CREATE TABLE IF NOT EXISTS _weft_jobs (" +
            "id BIGSERIAL PRIMARY KEY, " +
            "queue TEXT NOT NULL, " +
            "kind TEXT NOT NULL, " +
            "payload TEXT NOT NULL, " +
            "status TEXT NOT NULL, " +
            "attempts INTEGER NOT NULL DEFAULT 0, " +
            "max_attempts INTEGER NOT NULL DEFAULT 3, " +
            "run_at_ms BIGINT NOT NULL, " +
            "last_error TEXT, " +
            "created_at_ms BIGINT NOT NULL, " +
            "updated_at_ms BIGINT NOT NULL);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_jobs_due ON _weft_jobs (queue, status, run_at_ms, id)"
        ) ::
        Migration.make(
            1003,
            "add_weft_jobs_unique_key",
            "ALTER TABLE _weft_jobs ADD COLUMN IF NOT EXISTS unique_key TEXT;" +
            "CREATE INDEX IF NOT EXISTS idx_weft_jobs_unique_key ON _weft_jobs (unique_key, status)"
        ) ::
        Nil

    ///
    /// Applies the PostgreSQL `_weft_jobs` schema migrations idempotently.
    ///
    pub def initSchemaPostgres(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrationsPostgres());
        ()
    }

    ///
    /// Handles `JobStore` using the driver-agnostic `Db` effect (e.g. `Sqlite.runWith(db)`).
    /// `claimNext` and `reclaimStale` execute atomically inside `Db.transaction` (using
    /// savepoints when nested inside an outer transaction).
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - JobStore) + {Db, DbError} =
        run {
            f()
        } with handler JobStore {
            def insertJob(spec, nowMs, k) = {
                let inserted = Db.transaction(() -> {
                    let existingOpt = match JobSpec.uniqueKey(spec) {
                        case None => None
                        case Some(uKey) =>
                            Db.queryOneMap(
                                "${selectCols()} WHERE unique_key = ? AND status IN ('pending', 'running') ORDER BY id ASC LIMIT 1",
                                SqlValue.text(uKey) :: Nil,
                                decodeJobRow
                            )
                    };
                    match existingOpt {
                        case Some(existing) => existing
                        case None =>
                            let runAt = nowMs + JobSpec.delayMs(spec);
                            let payloadStr = Json.encode(JobSpec.payload(spec));
                            let id = Db.insertAndGetId(
                                "INSERT INTO _weft_jobs (queue, kind, payload, status, attempts, max_attempts, run_at_ms, last_error, unique_key, created_at_ms, updated_at_ms) " +
                                "VALUES (?, ?, ?, 'pending', 0, ?, ?, NULL, ?, ?, ?)",
                                SqlValue.text(JobSpec.queue(spec)) ::
                                SqlValue.text(JobSpec.kind(spec)) ::
                                SqlValue.text(payloadStr) ::
                                SqlValue.int(JobSpec.maxAttempts(spec)) ::
                                SqlValue.int64(runAt) ::
                                SqlValue.optionalText(JobSpec.uniqueKey(spec)) ::
                                SqlValue.int64(nowMs) ::
                                SqlValue.int64(nowMs) ::
                                Nil
                            );
                            buildNewJob(id, spec, nowMs)
                    }
                });
                k(inserted)
            }

            def claimNext(queue, nowMs, k) = {
                let claimed = Db.transaction(() -> {
                    match Db.queryOneMap(
                        "${selectCols()} WHERE queue = ? AND status = 'pending' AND run_at_ms <= ? " +
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

            def reclaimStale(staleBeforeMs, nowMs, k) = {
                let reclaimed = Db.transaction(() -> {
                    let retryCount = Db.execute(
                        "UPDATE _weft_jobs SET status = 'pending', run_at_ms = ?, last_error = 'Reclaimed stale running job', updated_at_ms = ? " +
                        "WHERE status = 'running' AND updated_at_ms <= ? AND attempts < max_attempts",
                        SqlValue.int64(nowMs) :: SqlValue.int64(nowMs) :: SqlValue.int64(staleBeforeMs) :: Nil
                    );
                    let deadCount = Db.execute(
                        "UPDATE _weft_jobs SET status = 'dead', last_error = 'Reclaimed stale running job after max attempts', updated_at_ms = ? " +
                        "WHERE status = 'running' AND updated_at_ms <= ? AND attempts >= max_attempts",
                        SqlValue.int64(nowMs) :: SqlValue.int64(staleBeforeMs) :: Nil
                    );
                    retryCount + deadCount
                });
                k(reclaimed)
            }

            def findJob(id, k) = {
                let found = Db.queryOneMap(
                    "${selectCols()} WHERE id = ?",
                    SqlValue.int64(id) :: Nil,
                    decodeJobRow
                );
                k(found)
            }

            def listJobs(qOpt, stOpt, k) = {
                let rows = match (qOpt, stOpt) {
                    case (None, None) =>
                        Db.queryMap("${selectCols()} ORDER BY id ASC", Nil, decodeJobRow)
                    case (Some(q), None) =>
                        Db.queryMap("${selectCols()} WHERE queue = ? ORDER BY id ASC", SqlValue.text(q) :: Nil, decodeJobRow)
                    case (None, Some(st)) =>
                        Db.queryMap("${selectCols()} WHERE status = ? ORDER BY id ASC", SqlValue.text("${st}") :: Nil, decodeJobRow)
                    case (Some(q), Some(st)) =>
                        Db.queryMap("${selectCols()} WHERE queue = ? AND status = ? ORDER BY id ASC", SqlValue.text(q) :: SqlValue.text("${st}") :: Nil, decodeJobRow)
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
            uniqueKey   = JobSpec.uniqueKey(spec),
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

    def findActiveByUniqueKey(keyOpt: Option[String], jobs: List[Job]): Option[Job] =
        match keyOpt {
            case None => None
            case Some(uKey) =>
                jobs
                    |> List.filter(j ->
                        Job.uniqueKey(j) == Some(uKey) and
                        (Job.status(j) == JobStatus.Pending or Job.status(j) == JobStatus.Running)
                    )
                    |> List.sortBy(Job.id)
                    |> List.head
        }

    def reclaimStaleInMap(staleBeforeMs: Int64, nowMs: Int64, m: Map[Int64, Job]): (Map[Int64, Job], Int32) =
        Map.foldLeftWithKey((acc, id, j) -> {
            let (curMap, count) = acc;
            if (Job.status(j) == JobStatus.Running and Job.updatedAtMs(j) <= staleBeforeMs) {
                let nextJob = if (Job.attempts(j) < Job.maxAttempts(j))
                    transitionRetry(j, nowMs, "Reclaimed stale running job", nowMs)
                else
                    transitionDead(j, "Reclaimed stale running job after max attempts", nowMs);
                (Map.insert(id, nextJob, curMap), count + 1)
            } else {
                (Map.insert(id, j, curMap), count)
            }
        }, (Map.empty(), 0), m)

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
            uniqueKey   = Row.optionalString("unique_key", row),
            createdAtMs = Row.requireInt64("created_at_ms", row),
            updatedAtMs = Row.requireInt64("updated_at_ms", row)
        })
    }

}
