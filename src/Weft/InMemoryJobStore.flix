pub mod Weft.InMemoryJobStore {
    use Weft.Job

    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe in-memory job store handle for `JobBackend.InMemory`.
    ///
    pub enum InMemoryJobStore {
        case InMemoryJobStore(ReentrantLock, Ref[Int64, IO], Ref[Map[Int64, Job], IO])
    }
}
