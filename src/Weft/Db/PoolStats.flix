pub mod Weft.Db.PoolStats {
    use Weft.Db.PoolStats
    use Weft.Json

    ///
    /// Point-in-time snapshot of a `Weft.Db.ConnectionPool`'s utilization and lifecycle.
    ///
    pub enum PoolStats {
        case PoolStats({
            maxConnections    = Int32,
            activeConnections = Int32,
            idleConnections   = Int32,
            totalCreated      = Int64,
            closed            = Bool
        })
    }

    instance Eq[PoolStats] {
        pub def eq(a: PoolStats, b: PoolStats): Bool =
            let PoolStats.PoolStats(x) = a;
            let PoolStats.PoolStats(y) = b;
            x#maxConnections == y#maxConnections and
            x#activeConnections == y#activeConnections and
            x#idleConnections == y#idleConnections and
            x#totalCreated == y#totalCreated and
            x#closed == y#closed
    }

    pub def make(
        maxConns: Int32,
        activeConns: Int32,
        idleConns: Int32,
        totalCreated: Int64,
        closed: Bool
    ): PoolStats =
        PoolStats.PoolStats({
            maxConnections    = maxConns,
            activeConnections = activeConns,
            idleConnections   = idleConns,
            totalCreated      = totalCreated,
            closed            = closed
        })

    pub def maxConnections(s: PoolStats): Int32    = let PoolStats.PoolStats(r) = s; r#maxConnections
    pub def activeConnections(s: PoolStats): Int32 = let PoolStats.PoolStats(r) = s; r#activeConnections
    pub def idleConnections(s: PoolStats): Int32   = let PoolStats.PoolStats(r) = s; r#idleConnections
    pub def totalCreated(s: PoolStats): Int64      = let PoolStats.PoolStats(r) = s; r#totalCreated
    pub def isClosed(s: PoolStats): Bool           = let PoolStats.PoolStats(r) = s; r#closed

    pub def toJson(s: PoolStats): Json =
        Json.obj(
            ("maxConnections",    Json.int(maxConnections(s))) ::
            ("activeConnections", Json.int(activeConnections(s))) ::
            ("idleConnections",   Json.int(idleConnections(s))) ::
            ("totalCreated",      Json.int64(totalCreated(s))) ::
            ("closed",            Json.bool(isClosed(s))) ::
            Nil
        )

}
