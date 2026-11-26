pub mod Weft.JobBackend {
    use Weft.Db.Sqlite
    use Weft.Db.SqliteDb
    use Weft.DbError
    use Weft.InMemoryJobStore
    use Weft.JobBackend
    use Weft.JobQueue
    use Weft.JobStore
    use Time.Clock

    ///
    /// Configurable runtime job backend: switch between in-memory and SQLite with one value!
    ///
    pub enum JobBackend {
        case InMemory(InMemoryJobStore)
        case Sqlite(SqliteDb)
    }

    ///
    /// Convenience constructor for a thread-safe in-memory backend.
    ///
    pub def inMemory(): JobBackend \ IO =
        JobBackend.InMemory(JobStore.makeInMemory())

    ///
    /// Convenience constructor for a SQLite-backed job backend (also ensures schema exists).
    ///
    pub def sqlite(db: SqliteDb): Result[String, JobBackend] \ IO =
        let res = run {
            JobStore.initSchema()
        } with Sqlite.runWith(db)
          with DbError.runToResult;
        match res {
            case Ok(())           => Ok(JobBackend.Sqlite(db))
            case Err((kind, msg)) => Err("Failed to initialize SQLite job schema (${kind}): ${msg}")
        }

    ///
    /// Discharges `JobStore` using whichever backend (`InMemory` or `Sqlite`) is configured.
    ///
    pub def runStore(backend: JobBackend, f: Unit -> a \ ef): a \ (ef - JobStore) + {DbError, IO} =
        match backend {
            case JobBackend.InMemory(mem) =>
                checked_ecast(JobStore.runInMemory(mem, f))
            case JobBackend.Sqlite(db) =>
                run {
                    f()
                } with JobStore.runWithDb
                  with Sqlite.runWith(db)
        }

    ///
    /// Discharges BOTH `JobQueue` and `JobStore` using the configured backend.
    ///
    pub def runQueue(backend: JobBackend, f: Unit -> a \ ef): a \ (ef - JobQueue - JobStore) + {DbError, Clock, IO} =
        run {
            f()
        } with JobQueue.runWithStore
          with runStore(backend)

}
