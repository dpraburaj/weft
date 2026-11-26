pub mod Weft.JobQueue {
    use Weft.Db
    use Weft.DbError
    use Weft.Job
    use Weft.JobQueue
    use Weft.JobSpec
    use Weft.JobStore
    use Weft.Json
    use Time.Clock

    ///
    /// Lightweight producer effect for enqueueing background jobs.
    ///
    pub eff JobQueue {
        def enqueue(spec: JobSpec): Job
    }

    ///
    /// Enqueues a job on the `"default"` queue for immediate execution.
    ///
    pub def dispatch(kind: String, payload: Json): Job \ JobQueue =
        JobQueue.enqueue(JobSpec.make(kind, payload))

    ///
    /// Enqueues a job on the `"default"` queue delayed by `delayMs` milliseconds.
    ///
    pub def dispatchIn(delayMs: Int64, kind: String, payload: Json): Job \ JobQueue =
        JobQueue.enqueue(JobSpec.make(kind, payload) |> JobSpec.withDelayMs(delayMs))

    ///
    /// Enqueues a job on a named `queue` for immediate execution.
    ///
    pub def dispatchOn(queue: String, kind: String, payload: Json): Job \ JobQueue =
        JobQueue.enqueue(JobSpec.make(kind, payload) |> JobSpec.withQueue(queue))

    ///
    /// Enqueues an idempotent job keyed by `uniqueKey` on the `"default"` queue.
    /// If a `Pending` or `Running` job with the same `uniqueKey` already exists, returns it.
    ///
    pub def dispatchUnique(uniqueKey: String, kind: String, payload: Json): Job \ JobQueue =
        JobQueue.enqueue(JobSpec.make(kind, payload) |> JobSpec.withUniqueKey(uniqueKey))

    ///
    /// Handles `JobQueue` by persisting into `JobStore` stamped with `Clock.now()`.
    ///
    pub def runWithStore(f: Unit -> a \ ef): a \ (ef - JobQueue) + {JobStore, Clock} =
        run {
            f()
        } with handler JobQueue {
            def enqueue(spec, k) = {
                let now = Clock.now();
                let job = JobStore.insertJob(spec, now);
                k(job)
            }
        }

    ///
    /// Transactional outbox handler: discharges `JobQueue` directly through the caller's
    /// active `Db` effect so `JobQueue.dispatch` inside `Db.transaction` / `Db.transactionHttp`
    /// commits or rolls back atomically with your domain writes!
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - JobQueue) + {Db, DbError, Clock} =
        run {
            runWithStore(f)
        } with JobStore.runWithDb

}
