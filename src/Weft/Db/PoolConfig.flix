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
            validationTimeoutSec = Int32
        })
    }

    instance Eq[PoolConfig] {
        pub def eq(a: PoolConfig, b: PoolConfig): Bool =
            let PoolConfig.PoolConfig(x) = a;
            let PoolConfig.PoolConfig(y) = b;
            x#maxConnections == y#maxConnections and
            x#minIdle == y#minIdle and
            x#acquireTimeoutMs == y#acquireTimeoutMs and
            x#validationTimeoutSec == y#validationTimeoutSec
    }

    ///
    /// Default pool settings: up to 10 connections, 2 pre-warmed idle connections,
    /// 5s acquire timeout, 2s liveness validation timeout.
    ///
    pub def default(): PoolConfig =
        PoolConfig.PoolConfig({
            maxConnections       = 10,
            minIdle              = 2,
            acquireTimeoutMs     = 5000i64,
            validationTimeoutSec = 2
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

}
