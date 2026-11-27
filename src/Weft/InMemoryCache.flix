pub mod Weft.InMemoryCache {
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe concurrent in-memory cache and lock store for virtual-thread servers.
    ///
    pub enum InMemoryCache {
        case InMemoryCache(
            ReentrantLock,
            Ref[Map[String, (String, Option[Int64])], Static],
            Ref[Map[String, (String, Int64)], Static]
        )
    }

}
