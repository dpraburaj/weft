pub mod Weft.RateLimitConfig {
    use Weft.RateLimitConfig

    ///
    /// Fixed-window rate limit policy (`maxRequests` per `windowMs` milliseconds).
    ///
    pub enum RateLimitConfig {
        case RateLimitConfig({
            maxRequests = Int32,
            windowMs    = Int64,
            keyPrefix   = String
        })
    }

    instance Eq[RateLimitConfig] {
        pub def eq(a: RateLimitConfig, b: RateLimitConfig): Bool =
            let RateLimitConfig.RateLimitConfig(x) = a;
            let RateLimitConfig.RateLimitConfig(y) = b;
            x#maxRequests == y#maxRequests and
            x#windowMs == y#windowMs and
            x#keyPrefix == y#keyPrefix
    }

    pub def make(maxRequests: Int32, windowMs: Int64): RateLimitConfig =
        RateLimitConfig.RateLimitConfig({
            maxRequests = Int32.max(1, maxRequests),
            windowMs    = Int64.max(1i64, windowMs),
            keyPrefix   = "rl"
        })

    pub def perSecond(maxRequests: Int32): RateLimitConfig =
        make(maxRequests, 1000i64)

    pub def perMinute(maxRequests: Int32): RateLimitConfig =
        make(maxRequests, 60000i64)

    pub def perHour(maxRequests: Int32): RateLimitConfig =
        make(maxRequests, 3600000i64)

    pub def maxRequests(cfg: RateLimitConfig): Int32 = let RateLimitConfig.RateLimitConfig(r) = cfg; r#maxRequests
    pub def windowMs(cfg: RateLimitConfig): Int64    = let RateLimitConfig.RateLimitConfig(r) = cfg; r#windowMs
    pub def keyPrefix(cfg: RateLimitConfig): String  = let RateLimitConfig.RateLimitConfig(r) = cfg; r#keyPrefix

    pub def withPrefix(prefix: String, cfg: RateLimitConfig): RateLimitConfig =
        let RateLimitConfig.RateLimitConfig(r) = cfg;
        RateLimitConfig.RateLimitConfig({ keyPrefix = prefix | r })

    ///
    /// Builds the namespaced bucket key (`"<prefix>:<key>"`).
    ///
    pub def scopedKey(key: String, cfg: RateLimitConfig): String =
        let p = keyPrefix(cfg);
        if (String.isEmpty(p)) key else "${p}:${key}"

}
