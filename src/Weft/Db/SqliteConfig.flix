pub mod Weft.Db.SqliteConfig {
    use Weft.Db.SqliteConfig

    ///
    /// Configuration for opening a SQLite database connection.
    ///
    pub enum SqliteConfig {
        case SqliteConfig({
            jdbcUrl       = String,
            walMode       = Bool,
            foreignKeys   = Bool,
            busyTimeoutMs = Int32
        })
    }

    ///
    /// Configures an in-memory SQLite database (`jdbc:sqlite::memory:`).
    /// Ideal for fast, isolated integration tests.
    ///
    pub def inMemory(): SqliteConfig =
        SqliteConfig.SqliteConfig({
            jdbcUrl       = "jdbc:sqlite::memory:",
            walMode       = false,
            foreignKeys   = true,
            busyTimeoutMs = 5000
        })

    ///
    /// Configures a persistent file-backed SQLite database (`jdbc:sqlite:<path>`),
    /// with WAL mode and foreign keys enabled by default.
    ///
    pub def file(path: String): SqliteConfig =
        SqliteConfig.SqliteConfig({
            jdbcUrl       = "jdbc:sqlite:${path}",
            walMode       = true,
            foreignKeys   = true,
            busyTimeoutMs = 5000
        })

    pub def withWalMode(enabled: Bool, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ walMode = enabled | r })

    pub def withForeignKeys(enabled: Bool, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ foreignKeys = enabled | r })

    pub def withBusyTimeoutMs(ms: Int32, cfg: SqliteConfig): SqliteConfig =
        let SqliteConfig.SqliteConfig(r) = cfg;
        SqliteConfig.SqliteConfig({ busyTimeoutMs = ms | r })

}
