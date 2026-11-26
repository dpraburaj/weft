pub mod Weft.Db.SqliteDb {
    import java.sql.Connection
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Thread-safe handle to a SQLite database connection.
    ///
    /// Uses a `ReentrantLock` so concurrent virtual threads from `Weft.Server`
    /// safely serialize queries and isolate multi-statement transactions.
    ///
    pub enum SqliteDb {
        case SqliteDb(ReentrantLock, Connection)
    }
}
