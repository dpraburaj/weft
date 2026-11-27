pub mod Weft.InMemoryStorage {
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe concurrent in-memory file storage store for virtual-thread servers.
    /// Stores `(bytes, lastModifiedMs)` per normalized relative path.
    ///
    pub enum InMemoryStorage {
        case InMemoryStorage(ReentrantLock, Ref[Map[String, (Vector[Int8], Int64)], Static])
    }

}
