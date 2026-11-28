pub mod Weft.RateLimiter {
    use Time.Clock
    use Weft.Db
    use Weft.DbError
    use Weft.HttpError
    use Weft.InMemoryRateLimiter
    use Weft.Migration
    use Weft.RateLimitConfig
    use Weft.RateLimitDecision
    use Weft.RateLimiter
    use Weft.Row
    use Weft.SqlValue

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Algebraic effect for fixed-window rate limiting and throttling.
    ///
    /// Handles per-IP, per-user, or per-action throttling across:
    /// - `RateLimiter.runPure` (100% pure region-scoped handler for zero-IO tests)
    /// - `RateLimiter.runInMemory` (thread-safe concurrent store for virtual-thread servers)
    /// - `RateLimiter.runWithDb` (persistent SQL backend via `Weft.Db`)
    ///
    pub eff RateLimiter {
        def hit(key: String, maxRequests: Int32, windowMs: Int64, nowMs: Int64): RateLimitDecision
        def peek(key: String, maxRequests: Int32, windowMs: Int64, nowMs: Int64): RateLimitDecision
        def reset(key: String): Unit
        def pruneExpired(nowMs: Int64): Int32
    }

    // --- Ergonomic Helpers ---

    ///
    /// Records one attempt against `key` using `cfg` and `Clock.now()`, returning the
    /// resulting `RateLimitDecision`.
    ///
    pub def check(cfg: RateLimitConfig, key: String): RateLimitDecision \ {RateLimiter, Clock} =
        RateLimiter.hit(
            RateLimitConfig.scopedKey(key, cfg),
            RateLimitConfig.maxRequests(cfg),
            RateLimitConfig.windowMs(cfg),
            Clock.now()
        )

    ///
    /// Records one attempt and returns `true` if allowed or `false` if throttled.
    ///
    pub def attempt(cfg: RateLimitConfig, key: String): Bool \ {RateLimiter, Clock} =
        RateLimitDecision.isAllowed(check(cfg, key))

    ///
    /// Inspects the remaining allowance for `key` without consuming a hit.
    ///
    pub def inspect(cfg: RateLimitConfig, key: String): RateLimitDecision \ {RateLimiter, Clock} =
        RateLimiter.peek(
            RateLimitConfig.scopedKey(key, cfg),
            RateLimitConfig.maxRequests(cfg),
            RateLimitConfig.windowMs(cfg),
            Clock.now()
        )

    ///
    /// Returns the number of remaining requests allowed in the current window for `key`.
    ///
    pub def remaining(cfg: RateLimitConfig, key: String): Int32 \ {RateLimiter, Clock} =
        RateLimitDecision.remaining(inspect(cfg, key))

    ///
    /// Resets the rate-limit bucket for `key` under `cfg`.
    ///
    pub def clear(cfg: RateLimitConfig, key: String): Unit \ RateLimiter =
        RateLimiter.reset(RateLimitConfig.scopedKey(key, cfg))

    ///
    /// Enforces `cfg` for `key`, raising `429 Too Many Requests` via `HttpError` when exceeded.
    /// Ideal inside login, OTP, or password-reset handlers.
    ///
    pub def enforce(cfg: RateLimitConfig, key: String): RateLimitDecision \ {RateLimiter, Clock, HttpError} = {
        let d = check(cfg, key);
        if (RateLimitDecision.isAllowed(d))
            d
        else {
            let secs = RateLimitDecision.retryAfterSeconds(d);
            HttpError.tooManyRequests("Too many requests. Please retry after ${secs}s.")
        }
    }

    // --- Pure Window Evaluation Helper ---

    def evalHit(
        existing: Option[(Int32, Int64)],
        maxRequests: Int32,
        windowMs: Int64,
        nowMs: Int64
    ): (RateLimitDecision, (Int32, Int64)) = {
        let safeMax = Int32.max(1, maxRequests);
        let safeWin = Int64.max(1i64, windowMs);
        let (curHits, resetAt) = match existing {
            case Some((hits, resetMs)) if nowMs < resetMs => (hits, resetMs)
            case _                                        => (0, nowMs + safeWin)
        };
        if (curHits < safeMax) {
            let nextHits = curHits + 1;
            let rem = safeMax - nextHits;
            (RateLimitDecision.make(true, safeMax, rem, resetAt, 0i64), (nextHits, resetAt))
        } else {
            let retryMs = Int64.max(0i64, resetAt - nowMs);
            (RateLimitDecision.make(false, safeMax, 0, resetAt, retryMs), (curHits, resetAt))
        }
    }

    def evalPeek(
        existing: Option[(Int32, Int64)],
        maxRequests: Int32,
        windowMs: Int64,
        nowMs: Int64
    ): RateLimitDecision = {
        let safeMax = Int32.max(1, maxRequests);
        let safeWin = Int64.max(1i64, windowMs);
        match existing {
            case Some((hits, resetMs)) if nowMs < resetMs =>
                let rem = Int32.max(0, safeMax - hits);
                let allowed = rem > 0;
                let retryMs = if (allowed) 0i64 else Int64.max(0i64, resetMs - nowMs);
                RateLimitDecision.make(allowed, safeMax, rem, resetMs, retryMs)
            case _ =>
                RateLimitDecision.make(true, safeMax, safeMax, nowMs + safeWin, 0i64)
        }
    }

    // --- 1. Pure Region-Scoped Backend (Zero IO!) ---

    ///
    /// 100% pure in-memory `RateLimiter` handler backed by a local `region rc`.
    /// Pairs with `TestEffects.runFixedClock` / `runSteppingClock` for deterministic tests.
    ///
    pub def runPure(f: Unit -> a \ ef): a \ (ef - RateLimiter) =
        region rc {
            let buckets = Ref.fresh(rc, Map.empty());
            run {
                f()
            } with handler RateLimiter {
                def hit(key, maxReqs, winMs, nowMs, k) = {
                    let existing = Map.get(key, Ref.get(buckets));
                    let (decision, nextState) = evalHit(existing, maxReqs, winMs, nowMs);
                    Ref.transform(m -> Map.insert(key, nextState, m), buckets);
                    k(decision)
                }
                def peek(key, maxReqs, winMs, nowMs, k) = {
                    let existing = Map.get(key, Ref.get(buckets));
                    k(evalPeek(existing, maxReqs, winMs, nowMs))
                }
                def reset(key, k) = {
                    Ref.transform(m -> Map.remove(key, m), buckets);
                    k()
                }
                def pruneExpired(nowMs, k) = {
                    let current = Ref.get(buckets);
                    let remaining = Map.filter(match (_, resetMs) -> nowMs < resetMs, current);
                    let removed = Map.size(current) - Map.size(remaining);
                    Ref.put(remaining, buckets);
                    k(removed)
                }
            }
        }

    // --- 2. Thread-Safe Concurrent In-Memory Backend ---

    ///
    /// Creates a thread-safe bounded in-memory rate limiter store (default capacity: 100,000 buckets)
    /// for concurrent virtual-thread servers.
    ///
    pub def makeInMemory(): InMemoryRateLimiter \ IO =
        makeInMemoryWithCapacity(100000)

    ///
    /// Creates a thread-safe in-memory rate limiter store bounded to at most `maxEntries` buckets,
    /// automatically pruning expired windows and evicting the earliest-resetting bucket when full.
    ///
    pub def makeInMemoryWithCapacity(maxEntries: Int32): InMemoryRateLimiter \ IO =
        InMemoryRateLimiter.InMemoryRateLimiter(
            new ReentrantLock(),
            Int32.max(1, maxEntries),
            Ref.fresh(Static, Map.empty())
        )

    def withLock(lock: ReentrantLock, action: Unit -> b \ IO): b \ IO = {
        lock.lock();
        try {
            let r = action();
            lock.unlock();
            r
        } catch {
            case ex: Exception =>
                lock.unlock();
                throw ex
        }
    }

    def evictOldestBucket(m: Map[String, (Int32, Int64)]): Map[String, (Int32, Int64)] = {
        let victimOpt = Map.foldLeftWithKey((acc, k, v) -> {
            let (_, resetMs) = v;
            match acc {
                case None => Some((k, resetMs))
                case Some((_, bestReset)) if resetMs < bestReset => Some((k, resetMs))
                case _ => acc
            }
        }, None, m);
        match victimOpt {
            case Some((k, _)) => Map.remove(k, m)
            case None         => m
        }
    }

    ///
    /// Handles `RateLimiter` against a shared thread-safe `InMemoryRateLimiter`.
    ///
    pub def runInMemory(store: InMemoryRateLimiter, f: Unit -> a \ ef): a \ (ef - RateLimiter) + IO = {
        let InMemoryRateLimiter.InMemoryRateLimiter(lock, maxEntries, mapRef) = store;
        run {
            f()
        } with handler RateLimiter {
            def hit(key, maxReqs, winMs, nowMs, k) = {
                let decision = withLock(lock, () -> {
                    let cur = Ref.get(mapRef);
                    let existing = Map.get(key, cur);
                    let (d, nextState) = evalHit(existing, maxReqs, winMs, nowMs);
                    let prepared = if (Option.nonEmpty(existing) or Map.size(cur) < maxEntries) {
                        cur
                    } else {
                        let pruned = Map.filter(match (_, resetMs) -> nowMs < resetMs, cur);
                        if (Map.size(pruned) < maxEntries) pruned else evictOldestBucket(pruned)
                    };
                    Ref.put(Map.insert(key, nextState, prepared), mapRef);
                    d
                });
                k(decision)
            }
            def peek(key, maxReqs, winMs, nowMs, k) = {
                let decision = withLock(lock, () -> {
                    let existing = Map.get(key, Ref.get(mapRef));
                    evalPeek(existing, maxReqs, winMs, nowMs)
                });
                k(decision)
            }
            def reset(key, k) = {
                withLock(lock, () ->
                    Ref.transform(m -> Map.remove(key, m), mapRef)
                );
                k()
            }
            def pruneExpired(nowMs, k) = {
                let removed = withLock(lock, () -> {
                    let current = Ref.get(mapRef);
                    let remaining = Map.filter(match (_, resetMs) -> nowMs < resetMs, current);
                    let count = Map.size(current) - Map.size(remaining);
                    Ref.put(remaining, mapRef);
                    count
                });
                k(removed)
            }
        }
    }

    // --- 3. Driver-Agnostic SQL Backend (SQLite & Future DBs) ---

    ///
    /// Schema migration creating `_weft_rate_limits` (version `1006`).
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1006,
            "create_weft_rate_limits_table",
            "CREATE TABLE IF NOT EXISTS _weft_rate_limits (" +
            "key TEXT PRIMARY KEY, " +
            "hits INTEGER NOT NULL, " +
            "reset_at_ms BIGINT NOT NULL);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_rate_limits_reset ON _weft_rate_limits (reset_at_ms)"
        ) :: Nil

    ///
    /// Applies the `_weft_rate_limits` schema migration idempotently.
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// Handles `RateLimiter` using the driver-agnostic `Db` effect (e.g. `Sqlite.runWith(db)`).
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - RateLimiter) + {Db, DbError} =
        run {
            f()
        } with handler RateLimiter {
            def hit(key, maxReqs, winMs, nowMs, k) = {
                let safeMax = Int32.max(1, maxReqs);
                let safeWin = Int64.max(1i64, winMs);
                let freshReset = nowMs + safeWin;
                // Single atomic conditional upsert + RETURNING inside a transaction (writer-pinned on SQLite,
                // row-locked atomic increment on PostgreSQL) eliminating read-modify-write race windows.
                let decision = Db.transaction(() -> {
                    let rowOpt = Db.queryOneMap(
                        "INSERT INTO _weft_rate_limits (key, hits, reset_at_ms) VALUES (?, 1, ?) " +
                        "ON CONFLICT(key) DO UPDATE SET " +
                        "hits = CASE " +
                        "  WHEN _weft_rate_limits.reset_at_ms <= ? THEN 1 " +
                        "  WHEN _weft_rate_limits.hits <= ? THEN _weft_rate_limits.hits + 1 " +
                        "  ELSE _weft_rate_limits.hits " +
                        "END, " +
                        "reset_at_ms = CASE " +
                        "  WHEN _weft_rate_limits.reset_at_ms <= ? THEN ? " +
                        "  ELSE _weft_rate_limits.reset_at_ms " +
                        "END " +
                        "RETURNING hits, reset_at_ms",
                        SqlValue.text(key) ::
                        SqlValue.int64(freshReset) ::
                        SqlValue.int64(nowMs) ::
                        SqlValue.int(safeMax) ::
                        SqlValue.int64(nowMs) ::
                        SqlValue.int64(freshReset) ::
                        Nil,
                        row -> (Row.requireInt("hits", row), Row.requireInt64("reset_at_ms", row))
                    );
                    match rowOpt {
                        case Some((hits, resetAt)) =>
                            if (hits <= safeMax)
                                RateLimitDecision.make(true, safeMax, safeMax - hits, resetAt, 0i64)
                            else
                                RateLimitDecision.make(false, safeMax, 0, resetAt, Int64.max(0i64, resetAt - nowMs))
                        case None =>
                            RateLimitDecision.make(true, safeMax, safeMax - 1, freshReset, 0i64)
                    }
                });
                k(decision)
            }
            def peek(key, maxReqs, winMs, nowMs, k) = {
                let existing = Db.queryOneMap(
                    "SELECT hits, reset_at_ms FROM _weft_rate_limits WHERE key = ?",
                    SqlValue.text(key) :: Nil,
                    row -> (Row.requireInt("hits", row), Row.requireInt64("reset_at_ms", row))
                );
                k(evalPeek(existing, maxReqs, winMs, nowMs))
            }
            def reset(key, k) = {
                let _ = Db.execute("DELETE FROM _weft_rate_limits WHERE key = ?", SqlValue.text(key) :: Nil);
                k()
            }
            def pruneExpired(nowMs, k) = {
                let count = Db.execute(
                    "DELETE FROM _weft_rate_limits WHERE reset_at_ms <= ?",
                    SqlValue.int64(nowMs) :: Nil
                );
                k(count)
            }
        }

}
