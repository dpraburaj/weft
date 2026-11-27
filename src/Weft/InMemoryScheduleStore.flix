pub mod Weft.InMemoryScheduleStore {
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe concurrent in-memory store tracking last execution timestamps
    /// for scheduled recurring tasks.
    ///
    pub enum InMemoryScheduleStore {
        case InMemoryScheduleStore(ReentrantLock, Ref[Map[String, Int64], Static])
    }

}
