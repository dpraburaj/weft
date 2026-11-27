pub mod Weft.ScheduleStore {
    use Weft.Db
    use Weft.DbError
    use Weft.InMemoryScheduleStore
    use Weft.Migration
    use Weft.Row
    use Weft.ScheduleStore
    use Weft.SqlValue

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Algebraic effect persisting last-run timestamps for `Weft.Scheduler` tasks.
    ///
    /// Handles tracking across:
    /// - `ScheduleStore.runPure` (100% pure region-scoped handler for deterministic tests)
    /// - `ScheduleStore.runInMemory` (thread-safe concurrent store)
    /// - `ScheduleStore.runWithDb` (SQLite/DB persistence so restarts remember last run times)
    ///
    pub eff ScheduleStore {
        def getLastRun(taskName: String): Option[Int64]
        def recordRun(taskName: String, ranAtMs: Int64): Unit
        def clearTask(taskName: String): Unit
    }

    // --- 1. Pure Region-Scoped Backend ---

    pub def runPure(f: Unit -> a \ ef): a \ (ef - ScheduleStore) =
        region rc {
            let store = Ref.fresh(rc, Map.empty());
            run {
                f()
            } with handler ScheduleStore {
                def getLastRun(name, k) =
                    k(Map.get(name, Ref.get(store)))
                def recordRun(name, ranAtMs, k) = {
                    Ref.transform(m -> Map.insert(name, ranAtMs, m), store);
                    k()
                }
                def clearTask(name, k) = {
                    Ref.transform(m -> Map.remove(name, m), store);
                    k()
                }
            }
        }

    // --- 2. Thread-Safe In-Memory Backend ---

    pub def makeInMemory(): InMemoryScheduleStore \ IO =
        InMemoryScheduleStore.InMemoryScheduleStore(
            new ReentrantLock(),
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

    pub def runInMemory(store: InMemoryScheduleStore, f: Unit -> a \ ef): a \ (ef - ScheduleStore) + IO = {
        let InMemoryScheduleStore.InMemoryScheduleStore(lock, mapRef) = store;
        run {
            f()
        } with handler ScheduleStore {
            def getLastRun(name, k) = {
                let res = withLock(lock, () -> Map.get(name, Ref.get(mapRef)));
                k(res)
            }
            def recordRun(name, ranAtMs, k) = {
                withLock(lock, () -> Ref.transform(m -> Map.insert(name, ranAtMs, m), mapRef));
                k()
            }
            def clearTask(name, k) = {
                withLock(lock, () -> Ref.transform(m -> Map.remove(name, m), mapRef));
                k()
            }
        }
    }

    // --- 3. Driver-Agnostic SQL Backend ---

    ///
    /// Schema migration creating `_weft_schedules` (version `1005`).
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1005,
            "create_weft_schedules_table",
            "CREATE TABLE IF NOT EXISTS _weft_schedules (" +
            "task_name TEXT PRIMARY KEY, " +
            "last_run_at_ms BIGINT NOT NULL)"
        ) :: Nil

    ///
    /// Applies the `_weft_schedules` schema migration idempotently.
    ///
    pub def initSchema(): Unit \ {Db, DbError} = {
        let _ = Migration.runAll(migrations());
        ()
    }

    ///
    /// Handles `ScheduleStore` using the driver-agnostic `Db` effect.
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - ScheduleStore) + {Db, DbError} =
        run {
            f()
        } with handler ScheduleStore {
            def getLastRun(name, k) = {
                let res = Db.queryOneMap(
                    "SELECT last_run_at_ms FROM _weft_schedules WHERE task_name = ?",
                    SqlValue.text(name) :: Nil,
                    Row.requireInt64("last_run_at_ms")
                );
                k(res)
            }
            def recordRun(name, ranAtMs, k) = {
                let _ = Db.execute(
                    "INSERT INTO _weft_schedules (task_name, last_run_at_ms) VALUES (?, ?) " +
                    "ON CONFLICT(task_name) DO UPDATE SET last_run_at_ms = excluded.last_run_at_ms",
                    SqlValue.text(name) :: SqlValue.int64(ranAtMs) :: Nil
                );
                k()
            }
            def clearTask(name, k) = {
                let _ = Db.execute(
                    "DELETE FROM _weft_schedules WHERE task_name = ?",
                    SqlValue.text(name) :: Nil
                );
                k()
            }
        }

}
