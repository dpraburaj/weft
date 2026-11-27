pub mod Weft.RateLimitDecision {
    use Weft.RateLimitDecision
    use Weft.Response

    ///
    /// Immutable outcome of a rate-limit check for a single key and window.
    ///
    pub enum RateLimitDecision {
        case RateLimitDecision({
            allowed      = Bool,
            limit        = Int32,
            remaining    = Int32,
            resetAtMs    = Int64,
            retryAfterMs = Int64
        })
    }

    instance Eq[RateLimitDecision] {
        pub def eq(a: RateLimitDecision, b: RateLimitDecision): Bool =
            let RateLimitDecision.RateLimitDecision(x) = a;
            let RateLimitDecision.RateLimitDecision(y) = b;
            x#allowed == y#allowed and
            x#limit == y#limit and
            x#remaining == y#remaining and
            x#resetAtMs == y#resetAtMs and
            x#retryAfterMs == y#retryAfterMs
    }

    pub def make(
        allowed: Bool,
        limit: Int32,
        remaining: Int32,
        resetAtMs: Int64,
        retryAfterMs: Int64
    ): RateLimitDecision =
        RateLimitDecision.RateLimitDecision({
            allowed      = allowed,
            limit        = Int32.max(0, limit),
            remaining    = Int32.max(0, remaining),
            resetAtMs    = resetAtMs,
            retryAfterMs = Int64.max(0i64, retryAfterMs)
        })

    pub def isAllowed(d: RateLimitDecision): Bool  = let RateLimitDecision.RateLimitDecision(r) = d; r#allowed
    pub def isBlocked(d: RateLimitDecision): Bool  = not isAllowed(d)
    pub def limit(d: RateLimitDecision): Int32     = let RateLimitDecision.RateLimitDecision(r) = d; r#limit
    pub def remaining(d: RateLimitDecision): Int32 = let RateLimitDecision.RateLimitDecision(r) = d; r#remaining
    pub def resetAtMs(d: RateLimitDecision): Int64 = let RateLimitDecision.RateLimitDecision(r) = d; r#resetAtMs
    pub def retryAfterMs(d: RateLimitDecision): Int64 = let RateLimitDecision.RateLimitDecision(r) = d; r#retryAfterMs

    ///
    /// Window reset timestamp in whole Unix seconds (suitable for `X-RateLimit-Reset`).
    ///
    pub def resetAtSeconds(d: RateLimitDecision): Int64 =
        (resetAtMs(d) + 999i64) / 1000i64

    ///
    /// Ceiling retry delay in seconds (`0` when allowed, at least `1` when blocked).
    /// Suitable for the HTTP `Retry-After` header.
    ///
    pub def retryAfterSeconds(d: RateLimitDecision): Int64 =
        if (isAllowed(d))
            0i64
        else
            Int64.max(1i64, (retryAfterMs(d) + 999i64) / 1000i64)

    ///
    /// Attaches standard `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
    /// headers (and `Retry-After` when blocked) to `res`.
    ///
    pub def applyHeaders(d: RateLimitDecision, res: Response): Response = {
        let r1 = res
            |> Response.withHeader("X-RateLimit-Limit", "${limit(d)}")
            |> Response.withHeader("X-RateLimit-Remaining", "${remaining(d)}")
            |> Response.withHeader("X-RateLimit-Reset", "${resetAtSeconds(d)}");
        if (isBlocked(d))
            Response.withHeader("Retry-After", "${retryAfterSeconds(d)}", r1)
        else
            r1
    }

}
