pub mod Weft.Db.PostgresDb {
    use Weft.Db.ConnectionPool

    ///
    /// Thread-safe handle to a pooled PostgreSQL database backed by `Weft.Db.ConnectionPool`.
    ///
    pub enum PostgresDb {
        case PostgresDb(ConnectionPool, String)
    }

}
