pub mod Weft.Db.SqliteDb {
    use Weft.Db.ConnectionPool

    import java.sql.Connection
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe handle to a SQLite database with:
    /// - a dedicated writer connection guarded by `ReentrantLock` (with nested savepoint tracking)
    /// - an optional concurrent WAL read-only `ConnectionPool` so concurrent virtual threads
    ///   execute `SELECT` queries in parallel without contending on the writer lock!
    ///
    pub enum SqliteDb {
        case SqliteDb(ReentrantLock, Connection, Ref[Int32, Static], Option[ConnectionPool])
    }
}
