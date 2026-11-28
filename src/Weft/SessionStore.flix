pub mod Weft.SessionStore {
    use Weft.Db
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.InMemorySessionStore
    use Weft.Migration
    use Weft.Row
    use Weft.SessionData
    use Weft.SessionStore
    use Weft.SqlValue

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Pluggable session storage backend effect (`SessionStore.runPure`,
    /// `SessionStore.runInMemory`, or `SessionStore.runWithDb` + `Sqlite.runWith`).
    ///
    pub eff SessionStore {
        def loadSession(id: String, nowMs: Int64): Option[SessionData]
        def saveSession(session: SessionData): Unit
        def deleteSession(id: String): Unit
        def pruneExpired(nowMs: Int64): Int32
    }

    // --- 1. Pure Region-Scoped Backend (Zero IO!) ---

    ///
    /// 100% pure in-memory `SessionStore` handler backed by a local `region rc`.
    /// Ideal for deterministic, zero-IO multi-request tests!
    ///
    pub def runPure(f: Unit -> a \ ef): a \ (ef - SessionStore) =
        region rc {
            let store = Ref.fresh(rc, Map.empty());
            run {
                f()
            } with handler SessionStore {
                def loadSession(id, nowMs, k) =
                    match Map.get(id, Ref.get(store)) {
                        case None => k(None)
                        case Some(s) =>
                            if (SessionData.isExpired(nowMs, s)) {
                                Ref.transform(m -> Map.remove(id, m), store);
                                k(None)
                            } else {
                                k(Some(s))
                            }
                    }
                def saveSession(session, k) = {
                    Ref.transform(m -> Map.insert(SessionData.id(session), session, m), store);
                    k()
                }
                def deleteSession(id, k) = {
                    Ref.transform(m -> Map.remove(id, m), store);
                    k()
                }
                def pruneExpired(nowMs, k) = {
                    let current = Ref.get(store);
                    let remaining = Map.filter(s -> not SessionData.isExpired(nowMs, s), current);
                    let removed = Map.size(current) - Map.size(remaining);
                    Ref.put(remaining, store);
                    k(removed)
                }
            }
        }

    // --- 2. Thread-Safe Concurrent In-Memory Backend ---

    ///
    /// Creates a new thread-safe bounded in-memory session store (default capacity: 100,000 sessions)
    /// for concurrent virtual-thread servers.
    ///
    pub def makeInMemory(): InMemorySessionStore \ IO =
        makeInMemoryWithCapacity(100000)

    ///
    /// Creates a thread-safe in-memory session store bounded to at most `maxEntries` sessions,
    /// pruning expired entries and evicting the earliest-expiring session when full.
    ///
    pub def makeInMemoryWithCapacity(maxEntries: Int32): InMemorySessionStore \ IO =
        InMemorySessionStore.InMemorySessionStore(
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

    def evictOldestSession(m: Map[String, SessionData]): Map[String, SessionData] = {
        let victimOpt = Map.foldLeftWithKey((acc, sid, s) -> match acc {
            case None => Some((sid, SessionData.expiresAtMs(s)))
            case Some((_, bestExp)) =>
                let exp = SessionData.expiresAtMs(s);
                if (exp < bestExp) Some((sid, exp)) else acc
        }, None, m);
        match victimOpt {
            case Some((sid, _)) => Map.remove(sid, m)
            case None           => m
        }
    }

    ///
    /// Handles `SessionStore` against a shared thread-safe `InMemorySessionStore`.
    ///
    pub def runInMemory(store: InMemorySessionStore, f: Unit -> a \ ef): a \ (ef - SessionStore) + IO = {
        let InMemorySessionStore.InMemorySessionStore(lock, maxEntries, mapRef) = store;
        run {
            f()
        } with handler SessionStore {
            def loadSession(id, nowMs, k) = {
                let found = withLock(lock, () ->
                    match Map.get(id, Ref.get(mapRef)) {
                        case None => None
                        case Some(s) =>
                            if (SessionData.isExpired(nowMs, s)) {
                                Ref.transform(m -> Map.remove(id, m), mapRef);
                                None
                            } else {
                                Some(s)
                            }
                    }
                );
                k(found)
            }
            def saveSession(session, k) = {
                withLock(lock, () -> {
                    let sid = SessionData.id(session);
                    let cur = Ref.get(mapRef);
                    let prepared = if (Map.memberOf(sid, cur) or Map.size(cur) < maxEntries) {
                        cur
                    } else {
                        let nowMs = SessionData.updatedAtMs(session);
                        let pruned = Map.filter(s -> not SessionData.isExpired(nowMs, s), cur);
                        if (Map.size(pruned) < maxEntries) pruned else evictOldestSession(pruned)
                    };
                    Ref.put(Map.insert(sid, session, prepared), mapRef)
                });
                k()
            }
            def deleteSession(id, k) = {
                withLock(lock, () ->
                    Ref.transform(m -> Map.remove(id, m), mapRef)
                );
                k()
            }
            def pruneExpired(nowMs, k) = {
                let removed = withLock(lock, () -> {
                    let current = Ref.get(mapRef);
                    let remaining = Map.filter(s -> not SessionData.isExpired(nowMs, s), current);
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
    /// Schema migration creating the `_weft_sessions` table and expiration index.
    /// Uses version `1002` so it never collides with application migrations (`1..999`)
    /// or `_weft_jobs` (`1001`).
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1002,
            "create_weft_sessions_table",
            "CREATE TABLE IF NOT EXISTS _weft_sessions (" +
            "id TEXT PRIMARY KEY, " +
            "payload TEXT NOT NULL, " +
            "expires_at_ms BIGINT NOT NULL, " +
            "created_at_ms BIGINT NOT NULL, " +
            "updated_at_ms BIGINT NOT NULL);" +
            "CREATE INDEX IF NOT EXISTS idx_weft_sessions_expires ON _weft_sessions (expires_at_ms)"
        ) :: Nil

    ///
    /// Applies the `_weft_sessions` schema migration idempotently.
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// Handles `SessionStore` using the driver-agnostic `Db` effect (e.g. `Sqlite.runWith(db)`).
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - SessionStore) + {Db, DbError} =
        run {
            f()
        } with handler SessionStore {
            def loadSession(id, nowMs, k) = {
                let rowOpt = Db.queryOneMap(
                    "SELECT id, payload, expires_at_ms, created_at_ms, updated_at_ms FROM _weft_sessions WHERE id = ?",
                    SqlValue.text(id) :: Nil,
                    decodeSessionRow
                );
                match rowOpt {
                    case None => k(None)
                    case Some(s) =>
                        if (SessionData.isExpired(nowMs, s)) {
                            let _ = Db.execute("DELETE FROM _weft_sessions WHERE id = ?", SqlValue.text(id) :: Nil);
                            k(None)
                        } else {
                            k(Some(s))
                        }
                }
            }
            def saveSession(session, k) = {
                let payload = SessionData.encodePayload(session);
                let _ = Db.execute(
                    "INSERT INTO _weft_sessions (id, payload, expires_at_ms, created_at_ms, updated_at_ms) " +
                    "VALUES (?, ?, ?, ?, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET " +
                    "payload = excluded.payload, " +
                    "expires_at_ms = excluded.expires_at_ms, " +
                    "updated_at_ms = excluded.updated_at_ms",
                    SqlValue.text(SessionData.id(session)) ::
                    SqlValue.text(payload) ::
                    SqlValue.int64(SessionData.expiresAtMs(session)) ::
                    SqlValue.int64(SessionData.createdAtMs(session)) ::
                    SqlValue.int64(SessionData.updatedAtMs(session)) ::
                    Nil
                );
                k()
            }
            def deleteSession(id, k) = {
                let _ = Db.execute("DELETE FROM _weft_sessions WHERE id = ?", SqlValue.text(id) :: Nil);
                k()
            }
            def pruneExpired(nowMs, k) = {
                let count = Db.execute(
                    "DELETE FROM _weft_sessions WHERE expires_at_ms <= ?",
                    SqlValue.int64(nowMs) :: Nil
                );
                k(count)
            }
        }

    def decodeSessionRow(row: Row): SessionData \ DbError = {
        let rawPayload = Row.requireString("payload", row);
        let (vals, fls) = match SessionData.decodePayload(rawPayload) {
            case Ok(pair) => pair
            case Err(msg) => DbError.raise(DbErrorKind.ColumnDecodeError, "Invalid session payload JSON: ${msg}")
        };
        SessionData.make(
            Row.requireString("id", row),
            vals,
            fls,
            Row.requireInt64("expires_at_ms", row),
            Row.requireInt64("created_at_ms", row),
            Row.requireInt64("updated_at_ms", row)
        )
    }

}
