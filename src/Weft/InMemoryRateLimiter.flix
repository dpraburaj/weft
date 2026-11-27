pub mod Weft.InMemoryRateLimiter {
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe concurrent in-memory rate limiter store for virtual-thread servers.
    /// Stores `(hitCount, windowResetAtMs)` per scoped key.
    ///
    pub enum InMemoryRateLimiter {
        case InMemoryRateLimiter(ReentrantLock, Ref[Map[String, (Int32, Int64)], Static])
    }

}
