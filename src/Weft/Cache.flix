pub mod Weft.Cache {
    use Time.Clock
    use Weft.Cache
    use Weft.Db
    use Weft.DbError
    use Weft.InMemoryCache
    use Weft.Json
    use Weft.Migration
    use Weft.Random
    use Weft.Row
    use Weft.SqlValue

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Algebraic effect for key-value caching with TTLs, `remember` compute-on-miss,
    /// and atomic distributed locks (`tryLock` / `withLock`).
    ///
    /// Backends:
    /// - `Cache.runPure` (100% pure region-scoped backend for zero-IO tests)
    /// - `Cache.runInMemory` (thread-safe concurrent store for virtual-thread servers)
    /// - `Cache.runWithDb` (persistent SQL backend via `Weft.Db`)
    ///
    pub eff Cache {
        def getRaw(key: String, nowMs: Int64): Option[String]
        def putRaw(key: String, value: String, expiresAtMs: Option[Int64]): Unit
        def forget(key: String): Unit
        def clear(): Unit
        def pruneExpired(nowMs: Int64): Int32
        def acquireLock(name: String, owner: String, expiresAtMs: Int64, nowMs: Int64): Bool
        def releaseLock(name: String, owner: String): Bool
    }

    // --- Ergonomic String / JSON Helpers ---

    ///
    /// Retrieves a non-expired cached value for `key`.
    ///
    pub def get(key: String): Option[String] \ {Cache, Clock} =
        Cache.getRaw(key, Clock.now())

    ///
    /// Returns `true` if a non-expired entry exists for `key`.
    ///
    pub def has(key: String): Bool \ {Cache, Clock} =
        Option.nonEmpty(get(key))

    ///
    /// Stores `value` under `key` for `ttlMs` milliseconds.
    ///
    pub def put(key: String, value: String, ttlMs: Int64): Unit \ {Cache, Clock} = {
        let expiresAt = Clock.now() + Int64.max(1i64, ttlMs);
        Cache.putRaw(key, value, Some(expiresAt))
    }

    ///
    /// Stores `value` under `key` without expiration.
    ///
    pub def putForever(key: String, value: String): Unit \ Cache =
        Cache.putRaw(key, value, None)

    ///
    /// Retrieves and immediately removes `key` from the cache (like Laravel's `Cache::pull`).
    ///
    pub def pull(key: String): Option[String] \ {Cache, Clock} = {
        let v = get(key);
        if (Option.nonEmpty(v)) Cache.forget(key) else ();
        v
    }

    ///
    /// Returns the cached value for `key` if present, otherwise computes it via `compute`,
    /// stores it for `ttlMs` milliseconds, and returns it (like Laravel's `Cache::remember`).
    ///
    pub def remember(key: String, ttlMs: Int64, compute: Unit -> String \ ef): String \ ef + {Cache, Clock} =
        match get(key) {
            case Some(hit) => hit
            case None =>
                let v = compute();
                put(key, v, ttlMs);
                v
        }

    ///
    /// Like `remember`, storing the computed value without expiration.
    ///
    pub def rememberForever(key: String, compute: Unit -> String \ ef): String \ ef + {Cache, Clock} =
        match get(key) {
            case Some(hit) => hit
            case None =>
                let v = compute();
                putForever(key, v);
                v
        }

    ///
    /// Retrieves and parses a cached `Json` value for `key` (returns `None` on miss or invalid JSON).
    ///
    pub def getJson(key: String): Option[Json] \ {Cache, Clock} =
        match get(key) {
            case None => None
            case Some(raw) =>
                match Json.parse(raw) {
                    case Ok(j)  => Some(j)
                    case Err(_) => None
                }
        }

    ///
    /// Encodes and stores `value` as JSON under `key` for `ttlMs` milliseconds.
    ///
    pub def putJson(key: String, value: Json, ttlMs: Int64): Unit \ {Cache, Clock} =
        put(key, Json.encode(value), ttlMs)

    ///
    /// Returns cached `Json` for `key`, or computes, caches for `ttlMs`, and returns it.
    ///
    pub def rememberJson(key: String, ttlMs: Int64, compute: Unit -> Json \ ef): Json \ ef + {Cache, Clock} =
        match getJson(key) {
            case Some(hit) => hit
            case None =>
                let v = compute();
                putJson(key, v, ttlMs);
                v
        }

    // --- Atomic Lock Helpers ---

    ///
    /// Attempts to acquire an atomic lock named `name` owned by `owner` for `ttlMs` ms.
    /// Returns `true` if acquired, `false` if already held by another unexpired owner.
    ///
    pub def tryLock(name: String, owner: String, ttlMs: Int64): Bool \ {Cache, Clock} = {
        let now = Clock.now();
        Cache.acquireLock(name, owner, now + Int64.max(1i64, ttlMs), now)
    }

    ///
    /// Releases lock `name` if it is currently owned by `owner`.
    ///
    pub def unlock(name: String, owner: String): Bool \ Cache =
        Cache.releaseLock(name, owner)

    ///
    /// Runs `f` while holding an atomic lock `name` (with explicit `owner` token) for up to `ttlMs`.
    /// Returns `Some(result)` if the lock was acquired, or `None` if already locked.
    ///
    pub def withLockOwner(name: String, owner: String, ttlMs: Int64, f: Unit -> a \ ef): Option[a] \ ef + {Cache, Clock} =
        if (tryLock(name, owner, ttlMs)) {
            let res = f();
            let _ = unlock(name, owner);
            Some(res)
        } else {
            None
        }

    ///
    /// Runs `f` while holding an atomic lock `name` using a freshly generated `Random` owner token.
    /// Returns `Some(result)` if the lock was acquired, or `None` if another worker holds it.
    ///
    pub def withLock(name: String, ttlMs: Int64, f: Unit -> a \ ef): Option[a] \ ef + {Cache, Clock, Random} = {
        let owner = Random.tokenBase64Url(16);
        withLockOwner(name, owner, ttlMs, f)
    }

    // --- Internal Expiration Helpers ---

    def isExpiredOpt(nowMs: Int64, expiresOpt: Option[Int64]): Bool = match expiresOpt {
        case None        => false
        case Some(expMs) => nowMs >= expMs
    }

    // --- 1. Pure Region-Scoped Backend (Zero IO!) ---

    ///
    /// 100% pure in-memory `Cache` handler backed by a local `region rc`.
    /// Ideal for zero-IO deterministic tests!
    ///
    pub def runPure(f: Unit -> a \ ef): a \ (ef - Cache) =
        region rc {
            let entries = Ref.fresh(rc, Map.empty());
            let locks = Ref.fresh(rc, Map.empty());
            run {
                f()
            } with handler Cache {
                def getRaw(key, nowMs, k) =
                    match Map.get(key, Ref.get(entries)) {
                        case None => k(None)
                        case Some((v, expOpt)) =>
                            if (isExpiredOpt(nowMs, expOpt)) {
                                Ref.transform(m -> Map.remove(key, m), entries);
                                k(None)
                            } else {
                                k(Some(v))
                            }
                    }
                def putRaw(key, value, expOpt, k) = {
                    Ref.transform(m -> Map.insert(key, (value, expOpt), m), entries);
                    k()
                }
                def forget(key, k) = {
                    Ref.transform(m -> Map.remove(key, m), entries);
                    k()
                }
                def clear(k) = {
                    Ref.put(Map.empty(), entries);
                    Ref.put(Map.empty(), locks);
                    k()
                }
                def pruneExpired(nowMs, k) = {
                    let curE = Ref.get(entries);
                    let remE = Map.filter(match (_, expOpt) -> not isExpiredOpt(nowMs, expOpt), curE);
                    let removedE = Map.size(curE) - Map.size(remE);
                    Ref.put(remE, entries);

                    let curL = Ref.get(locks);
                    let remL = Map.filter(match (_, expMs) -> nowMs < expMs, curL);
                    let removedL = Map.size(curL) - Map.size(remL);
                    Ref.put(remL, locks);
                    k(removedE + removedL)
                }
                def acquireLock(name, owner, expMs, nowMs, k) = {
                    let acquired = match Map.get(name, Ref.get(locks)) {
                        case Some((curOwner, curExp)) if nowMs < curExp and curOwner != owner =>
                            false
                        case _ =>
                            Ref.transform(m -> Map.insert(name, (owner, expMs), m), locks);
                            true
                    };
                    k(acquired)
                }
                def releaseLock(name, owner, k) = {
                    let released = match Map.get(name, Ref.get(locks)) {
                        case Some((curOwner, _)) if curOwner == owner =>
                            Ref.transform(m -> Map.remove(name, m), locks);
                            true
                        case _ =>
                            false
                    };
                    k(released)
                }
            }
        }

    // --- 2. Thread-Safe Concurrent In-Memory Backend ---

    ///
    /// Creates a new thread-safe concurrent `InMemoryCache` for virtual-thread servers.
    ///
    pub def makeInMemory(): InMemoryCache \ IO =
        InMemoryCache.InMemoryCache(
            new ReentrantLock(),
            Ref.fresh(Static, Map.empty()),
            Ref.fresh(Static, Map.empty())
        )

    def withMutex(lock: ReentrantLock, action: Unit -> b \ IO): b \ IO = {
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

    ///
    /// Handles `Cache` against a shared thread-safe `InMemoryCache`.
    ///
    pub def runInMemory(store: InMemoryCache, f: Unit -> a \ ef): a \ (ef - Cache) + IO = {
        let InMemoryCache.InMemoryCache(lock, entriesRef, locksRef) = store;
        run {
            f()
        } with handler Cache {
            def getRaw(key, nowMs, k) = {
                let found = withMutex(lock, () ->
                    match Map.get(key, Ref.get(entriesRef)) {
                        case None => None
                        case Some((v, expOpt)) =>
                            if (isExpiredOpt(nowMs, expOpt)) {
                                Ref.transform(m -> Map.remove(key, m), entriesRef);
                                None
                            } else {
                                Some(v)
                            }
                    }
                );
                k(found)
            }
            def putRaw(key, value, expOpt, k) = {
                withMutex(lock, () ->
                    Ref.transform(m -> Map.insert(key, (value, expOpt), m), entriesRef)
                );
                k()
            }
            def forget(key, k) = {
                withMutex(lock, () ->
                    Ref.transform(m -> Map.remove(key, m), entriesRef)
                );
                k()
            }
            def clear(k) = {
                withMutex(lock, () -> {
                    Ref.put(Map.empty(), entriesRef);
                    Ref.put(Map.empty(), locksRef)
                });
                k()
            }
            def pruneExpired(nowMs, k) = {
                let removed = withMutex(lock, () -> {
                    let curE = Ref.get(entriesRef);
                    let remE = Map.filter(match (_, expOpt) -> not isExpiredOpt(nowMs, expOpt), curE);
                    let removedE = Map.size(curE) - Map.size(remE);
                    Ref.put(remE, entriesRef);

                    let curL = Ref.get(locksRef);
                    let remL = Map.filter(match (_, expMs) -> nowMs < expMs, curL);
                    let removedL = Map.size(curL) - Map.size(remL);
                    Ref.put(remL, locksRef);
                    removedE + removedL
                });
                k(removed)
            }
            def acquireLock(name, owner, expMs, nowMs, k) = {
                let acquired = withMutex(lock, () ->
                    match Map.get(name, Ref.get(locksRef)) {
                        case Some((curOwner, curExp)) if nowMs < curExp and curOwner != owner =>
                            false
                        case _ =>
                            Ref.transform(m -> Map.insert(name, (owner, expMs), m), locksRef);
                            true
                    }
                );
                k(acquired)
            }
            def releaseLock(name, owner, k) = {
                let released = withMutex(lock, () ->
                    match Map.get(name, Ref.get(locksRef)) {
                        case Some((curOwner, _)) if curOwner == owner =>
                            Ref.transform(m -> Map.remove(name, m), locksRef);
                            true
                        case _ =>
                            false
                    }
                );
                k(released)
            }
        }
    }

    // --- 3. Driver-Agnostic SQL Backend (SQLite & Future DBs) ---

    ///
    /// Schema migration creating `_weft_cache` and `_weft_cache_locks` (version `1004`).
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1004,
            "create_weft_cache_tables",
            "CREATE TABLE IF NOT EXISTS _weft_cache (" +
            "key TEXT PRIMARY KEY, " +
            "value TEXT NOT NULL, " +
            "expires_at_ms BIGINT);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_cache_expires ON _weft_cache (expires_at_ms);" +
            "CREATE TABLE IF NOT EXISTS _weft_cache_locks (" +
            "name TEXT PRIMARY KEY, " +
            "owner TEXT NOT NULL, " +
            "expires_at_ms BIGINT NOT NULL);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_cache_locks_expires ON _weft_cache_locks (expires_at_ms)"
        ) :: Nil

    ///
    /// Applies the `_weft_cache` and `_weft_cache_locks` schema migrations idempotently.
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// Handles `Cache` using the driver-agnostic `Db` effect (e.g. `Sqlite.runWith(db)`).
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - Cache) + {Db, DbError} =
        run {
            f()
        } with handler Cache {
            def getRaw(key, nowMs, k) = {
                let rowOpt = Db.queryOneMap(
                    "SELECT value, expires_at_ms FROM _weft_cache WHERE key = ?",
                    SqlValue.text(key) :: Nil,
                    row -> (Row.requireString("value", row), Row.optionalInt64("expires_at_ms", row))
                );
                match rowOpt {
                    case None => k(None)
                    case Some((v, expOpt)) =>
                        if (isExpiredOpt(nowMs, expOpt)) {
                            let _ = Db.execute("DELETE FROM _weft_cache WHERE key = ?", SqlValue.text(key) :: Nil);
                            k(None)
                        } else {
                            k(Some(v))
                        }
                }
            }
            def putRaw(key, value, expOpt, k) = {
                let _ = Db.execute(
                    "INSERT INTO _weft_cache (key, value, expires_at_ms) VALUES (?, ?, ?) " +
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value, expires_at_ms = excluded.expires_at_ms",
                    SqlValue.text(key) :: SqlValue.text(value) :: SqlValue.optionalInt64(expOpt) :: Nil
                );
                k()
            }
            def forget(key, k) = {
                let _ = Db.execute("DELETE FROM _weft_cache WHERE key = ?", SqlValue.text(key) :: Nil);
                k()
            }
            def clear(k) = {
                let _ = Db.executeSql("DELETE FROM _weft_cache");
                let _ = Db.executeSql("DELETE FROM _weft_cache_locks");
                k()
            }
            def pruneExpired(nowMs, k) = {
                let c1 = Db.execute(
                    "DELETE FROM _weft_cache WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?",
                    SqlValue.int64(nowMs) :: Nil
                );
                let c2 = Db.execute(
                    "DELETE FROM _weft_cache_locks WHERE expires_at_ms <= ?",
                    SqlValue.int64(nowMs) :: Nil
                );
                k(c1 + c2)
            }
            def acquireLock(name, owner, expMs, nowMs, k) = {
                let acquired = Db.transaction(() -> {
                    let existing = Db.queryOneMap(
                        "SELECT owner, expires_at_ms FROM _weft_cache_locks WHERE name = ?",
                        SqlValue.text(name) :: Nil,
                        row -> (Row.requireString("owner", row), Row.requireInt64("expires_at_ms", row))
                    );
                    match existing {
                        case Some((curOwner, curExp)) if nowMs < curExp and curOwner != owner =>
                            false
                        case _ =>
                            let _ = Db.execute(
                                "INSERT INTO _weft_cache_locks (name, owner, expires_at_ms) VALUES (?, ?, ?) " +
                                "ON CONFLICT(name) DO UPDATE SET owner = excluded.owner, expires_at_ms = excluded.expires_at_ms",
                                SqlValue.text(name) :: SqlValue.text(owner) :: SqlValue.int64(expMs) :: Nil
                            );
                            true
                    }
                });
                k(acquired)
            }
            def releaseLock(name, owner, k) = {
                let affected = Db.execute(
                    "DELETE FROM _weft_cache_locks WHERE name = ? AND owner = ?",
                    SqlValue.text(name) :: SqlValue.text(owner) :: Nil
                );
                k(affected > 0)
            }
        }

}
