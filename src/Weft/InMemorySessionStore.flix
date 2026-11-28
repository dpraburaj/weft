pub mod Weft.InMemorySessionStore {
    use Weft.SessionData

    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe concurrent in-memory session store handle for virtual-thread servers.
    ///
    pub enum InMemorySessionStore {
        case InMemorySessionStore(ReentrantLock, Int32, Ref[Map[String, SessionData], Static])
    }

}
