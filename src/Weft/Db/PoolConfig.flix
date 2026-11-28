pub mod Weft.Db.PoolConfig {
    use Weft.Db.PoolConfig

    ///
    /// Configuration for a bounded JDBC `Weft.Db.ConnectionPool`.
    ///
    pub enum PoolConfig {
        case PoolConfig({
            maxConnections       = Int32,
            minIdle              = Int32,
            acquireTimeoutMs     = Int64,
            validationTimeoutSec = Int32,
            validationIntervalMs = Int64,
            idleTimeoutMs        = Int64,
            maxLifetimeMs        = Int64
        })
    }

    instance Eq[PoolConfig] {
        pub def eq(a: PoolConfig, b: PoolConfig): Bool =
            let PoolConfig.PoolConfig(x) = a;
            let PoolConfig.PoolConfig(y) = b;
            x#maxConnections == y#maxConnections and
            x#minIdle == y#minIdle and
            x#acquireTimeoutMs == y#acquireTimeoutMs and
            x#validationTimeoutSec == y#validationTimeoutSec and
            x#validationIntervalMs == y#validationIntervalMs and
            x#idleTimeoutMs == y#idleTimeoutMs and
            x#maxLifetimeMs == y#maxLifetimeMs
    }

    ///
    /// Default pool settings:
    /// - up to 10 connections, 2 pre-warmed idle connections
    /// - 5s acquire timeout
    /// - 2s liveness validation timeout, checked only after 30s idle (`validationIntervalMs`)
    /// - 10m idle eviction (`idleTimeoutMs`), 30m max connection lifetime (`maxLifetimeMs`)
    ///
    pub def default(): PoolConfig =
        PoolConfig.PoolConfig({
            maxConnections       = 10,
            minIdle              = 2,
            acquireTimeoutMs     = 5000i64,
            validationTimeoutSec = 2,
            validationIntervalMs = 30000i64,
            idleTimeoutMs        = 600000i64,
            maxLifetimeMs        = 1800000i64
        })

    pub def make(maxConns: Int32): PoolConfig =
        let safeMax = Int32.max(1, maxConns);
        default()
            |> withMaxConnections(safeMax)
            |> withMinIdle(Int32.min(2, safeMax))

    pub def maxConnections(cfg: PoolConfig): Int32       = let PoolConfig.PoolConfig(r) = cfg; r#maxConnections
    pub def minIdle(cfg: PoolConfig): Int32              = let PoolConfig.PoolConfig(r) = cfg; r#minIdle
    pub def acquireTimeoutMs(cfg: PoolConfig): Int64     = let PoolConfig.PoolConfig(r) = cfg; r#acquireTimeoutMs
    pub def validationTimeoutSec(cfg: PoolConfig): Int32 = let PoolConfig.PoolConfig(r) = cfg; r#validationTimeoutSec
    pub def validationIntervalMs(cfg: PoolConfig): Int64 = let PoolConfig.PoolConfig(r) = cfg; r#validationIntervalMs
    pub def idleTimeoutMs(cfg: PoolConfig): Int64        = let PoolConfig.PoolConfig(r) = cfg; r#idleTimeoutMs
    pub def maxLifetimeMs(cfg: PoolConfig): Int64        = let PoolConfig.PoolConfig(r) = cfg; r#maxLifetimeMs

    pub def withMaxConnections(n: Int32, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        let safeMax = Int32.max(1, n);
        PoolConfig.PoolConfig({
            maxConnections = safeMax,
            minIdle        = Int32.min(r#minIdle, safeMax)
            | r
        })

    pub def withMinIdle(n: Int32, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        let safeMin = Int32.max(0, Int32.min(n, r#maxConnections));
        PoolConfig.PoolConfig({ minIdle = safeMin | r })

    pub def withAcquireTimeoutMs(ms: Int64, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        PoolConfig.PoolConfig({ acquireTimeoutMs = Int64.max(1i64, ms) | r })

    pub def withValidationTimeoutSec(secs: Int32, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        PoolConfig.PoolConfig({ validationTimeoutSec = Int32.max(0, secs) | r })

    ///
    /// Minimum idle duration (ms) before running `Connection.isValid` on borrow (default 30s).
    /// Avoids paying a network validation round-trip on every hot-path query. Set `0i64` to validate always.
    ///
    pub def withValidationIntervalMs(ms: Int64, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        PoolConfig.PoolConfig({ validationIntervalMs = Int64.max(0i64, ms) | r })

    ///
    /// Maximum time (ms) a connection may sit idle before eviction (default 10m; `0i64` disables).
    ///
    pub def withIdleTimeoutMs(ms: Int64, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        PoolConfig.PoolConfig({ idleTimeoutMs = Int64.max(0i64, ms) | r })

    ///
    /// Maximum total lifetime (ms) of any pooled connection before retirement (default 30m; `0i64` disables).
    ///
    pub def withMaxLifetimeMs(ms: Int64, cfg: PoolConfig): PoolConfig =
        let PoolConfig.PoolConfig(r) = cfg;
        PoolConfig.PoolConfig({ maxLifetimeMs = Int64.max(0i64, ms) | r })

}
