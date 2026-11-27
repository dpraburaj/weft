pub mod Weft.Db.SqliteConfig {
    use Weft.Db.SqliteConfig

    ///
    /// Configuration for opening a SQLite database connection (with optional concurrent
    /// WAL reader connection pool for file-backed databases).
    ///
    pub enum SqliteConfig {
        case SqliteConfig({
            jdbcUrl       = String,
            walMode       = Bool,
            foreignKeys   = Bool,
            busyTimeoutMs = Int32,
            readPoolSize  = Int32
        })
    }

    ///
    /// Configures an in-memory SQLite database (`jdbc:sqlite::memory:`).
    /// Uses a single shared connection (`readPoolSize = 0`) because `:memory:` databases
    /// are scoped per connection. Ideal for fast, isolated integration tests.
    ///
    pub def inMemory(): SqliteConfig =
        SqliteConfig.SqliteConfig({
            jdbcUrl       = "jdbc:sqlite::memory:",
            walMode       = false,
            foreignKeys   = true,
            busyTimeoutMs = 5000,
            readPoolSize  = 0
        })

    ///
    /// Configures a persistent file-backed SQLite database (`jdbc:sqlite:<path>`),
    /// with WAL mode, foreign keys, and a 4-connection concurrent WAL reader pool enabled by default.
    ///
    pub def file(path: String): SqliteConfig =
        SqliteConfig.SqliteConfig({
            jdbcUrl       = "jdbc:sqlite:${path}",
            walMode       = true,
            foreignKeys   = true,
            busyTimeoutMs = 5000,
            readPoolSize  = 4
        })

    pub def jdbcUrl(cfg: SqliteConfig): String     = let SqliteConfig.SqliteConfig(r) = cfg; r#jdbcUrl
    pub def walMode(cfg: SqliteConfig): Bool       = let SqliteConfig.SqliteConfig(r) = cfg; r#walMode
    pub def foreignKeys(cfg: SqliteConfig): Bool   = let SqliteConfig.SqliteConfig(r) = cfg; r#foreignKeys
    pub def busyTimeoutMs(cfg: SqliteConfig): Int32 = let SqliteConfig.SqliteConfig(r) = cfg; r#busyTimeoutMs
    pub def readPoolSize(cfg: SqliteConfig): Int32 = let SqliteConfig.SqliteConfig(r) = cfg; r#readPoolSize

    pub def withWalMode(enabled: Bool, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ walMode = enabled | r })

    pub def withForeignKeys(enabled: Bool, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ foreignKeys = enabled | r })

    pub def withBusyTimeoutMs(ms: Int32, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ busyTimeoutMs = ms | r })

    ///
    /// Sets the number of concurrent read-only WAL connections (`0` disables the reader pool
    /// and routes all reads through the writer connection).
    ///
    pub def withReadPoolSize(n: Int32, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ readPoolSize = Int32.max(0, n) | r })

}
