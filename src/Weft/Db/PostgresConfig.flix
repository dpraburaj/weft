pub mod Weft.Db.PostgresConfig {
    use Weft.Db.PoolConfig
    use Weft.Db.PostgresConfig
    use Weft.Url

    import java.lang.Exception
    import java.net.URI

    ///
    /// Configuration for opening a pooled PostgreSQL JDBC connection pool (`Weft.Db.Postgres`).
    ///
    pub enum PostgresConfig {
        case PostgresConfig({
            jdbcUrl           = String,
            username          = String,
            password          = String,
            sslMode           = Option[String],
            applicationName   = String,
            connectTimeoutSec = Int32,
            poolConfig        = PoolConfig
        })
    }

    instance Eq[PostgresConfig] {
        pub def eq(a: PostgresConfig, b: PostgresConfig): Bool =
            let PostgresConfig.PostgresConfig(x) = a;
            let PostgresConfig.PostgresConfig(y) = b;
            x#jdbcUrl == y#jdbcUrl and
            x#username == y#username and
            x#password == y#password and
            x#sslMode == y#sslMode and
            x#applicationName == y#applicationName and
            x#connectTimeoutSec == y#connectTimeoutSec and
            x#poolConfig == y#poolConfig
    }

    ///
    /// Creates a PostgreSQL configuration targeting `host:port/database`.
    ///
    pub def make(host: String, port: Int32, database: String, username: String, password: String): PostgresConfig =
        PostgresConfig.PostgresConfig({
            jdbcUrl           = "jdbc:postgresql://${host}:${port}/${database}",
            username          = username,
            password          = password,
            sslMode           = None,
            applicationName   = "weft",
            connectTimeoutSec = 10,
            poolConfig        = PoolConfig.default()
        })

    ///
    /// Creates a local PostgreSQL configuration targeting `127.0.0.1:5432/database`.
    ///
    pub def local(database: String, username: String, password: String): PostgresConfig =
        make("127.0.0.1", 5432, database, username, password)

    ///
    /// Creates a PostgreSQL configuration directly from a JDBC URL
    /// (e.g. `"jdbc:postgresql://db.internal:5432/app?sslmode=require"`).
    ///
    pub def fromJdbcUrl(jdbcUrl: String, username: String, password: String): PostgresConfig =
        PostgresConfig.PostgresConfig({
            jdbcUrl           = jdbcUrl,
            username          = username,
            password          = password,
            sslMode           = None,
            applicationName   = "weft",
            connectTimeoutSec = 10,
            poolConfig        = PoolConfig.default()
        })

    ///
    /// Parses a standard `DATABASE_URL` URI:
    /// `"postgres://user:pass@host:5432/mydb?sslmode=require"` or `"postgresql://..."`.
    ///
    pub def fromDatabaseUrl(rawUrl: String): Result[String, PostgresConfig] = {
        let trimmed = String.trim(rawUrl);
        if (String.startsWith({prefix = "jdbc:postgresql://"}, trimmed))
            Ok(fromJdbcUrl(trimmed, "", ""))
        else if (not String.startsWith({prefix = "postgres://"}, trimmed) and
                 not String.startsWith({prefix = "postgresql://"}, trimmed))
            Err("DATABASE_URL must start with postgres://, postgresql://, or jdbc:postgresql://")
        else
            try {
                unsafe IO {
                    let uri = URI.create(trimmed);
                    let hostObj = uri.getHost();
                    if (Object.isNull(hostObj) or String.isEmpty(hostObj))
                        Err("Missing host in DATABASE_URL")
                    else {
                        let rawPort = uri.getPort();
                        let portNum = if (rawPort > 0) rawPort else 5432;
                        let rawPath = uri.getPath();
                        let dbName = if (Object.isNull(rawPath)) "" else stripLeadingSlash(rawPath);
                        if (String.isEmpty(dbName))
                            Err("Missing database name in DATABASE_URL")
                        else {
                            let userInfoObj = uri.getRawUserInfo();
                            let (user, pass) = if (Object.isNull(userInfoObj))
                                ("", "")
                            else
                                parseUserInfo(userInfoObj);
                            let rawQueryObj = uri.getRawQuery();
                            let queryStr = if (Object.isNull(rawQueryObj)) "" else rawQueryObj;
                            let queryParams = Url.parseQuery(queryStr);
                            let sslOpt = Map.get("sslmode", queryParams);
                            let jdbc = if (String.isEmpty(queryStr))
                                "jdbc:postgresql://${hostObj}:${portNum}/${dbName}"
                            else
                                "jdbc:postgresql://${hostObj}:${portNum}/${dbName}?${queryStr}";
                            let cfg = PostgresConfig.PostgresConfig({
                                jdbcUrl           = jdbc,
                                username          = user,
                                password          = pass,
                                sslMode           = sslOpt,
                                applicationName   = "weft",
                                connectTimeoutSec = 10,
                                poolConfig        = PoolConfig.default()
                            });
                            Ok(cfg)
                        }
                    }
                }
            } catch {
                case ex: Exception =>
                    let rawMsg = ex.getMessage();
                    Err("Invalid DATABASE_URL: ${if (Object.isNull(rawMsg)) "malformed URI" else rawMsg}")
            }
    }

    // --- Accessors ---

    pub def jdbcUrl(cfg: PostgresConfig): String           = let PostgresConfig.PostgresConfig(r) = cfg; r#jdbcUrl
    pub def username(cfg: PostgresConfig): String          = let PostgresConfig.PostgresConfig(r) = cfg; r#username
    pub def password(cfg: PostgresConfig): String          = let PostgresConfig.PostgresConfig(r) = cfg; r#password
    pub def sslMode(cfg: PostgresConfig): Option[String]   = let PostgresConfig.PostgresConfig(r) = cfg; r#sslMode
    pub def applicationName(cfg: PostgresConfig): String   = let PostgresConfig.PostgresConfig(r) = cfg; r#applicationName
    pub def connectTimeoutSec(cfg: PostgresConfig): Int32  = let PostgresConfig.PostgresConfig(r) = cfg; r#connectTimeoutSec
    pub def poolConfig(cfg: PostgresConfig): PoolConfig    = let PostgresConfig.PostgresConfig(r) = cfg; r#poolConfig

    // --- Builders ---

    pub def withPoolConfig(pc: PoolConfig, cfg: PostgresConfig): PostgresConfig =
        let PostgresConfig.PostgresConfig(r) = cfg;
        PostgresConfig.PostgresConfig({ poolConfig = pc | r })

    pub def withMaxConnections(n: Int32, cfg: PostgresConfig): PostgresConfig =
        withPoolConfig(PoolConfig.withMaxConnections(n, poolConfig(cfg)), cfg)

    pub def withMinIdle(n: Int32, cfg: PostgresConfig): PostgresConfig =
        withPoolConfig(PoolConfig.withMinIdle(n, poolConfig(cfg)), cfg)

    pub def withAcquireTimeoutMs(ms: Int64, cfg: PostgresConfig): PostgresConfig =
        withPoolConfig(PoolConfig.withAcquireTimeoutMs(ms, poolConfig(cfg)), cfg)

    pub def withSslMode(mode: String, cfg: PostgresConfig): PostgresConfig =
        let PostgresConfig.PostgresConfig(r) = cfg;
        PostgresConfig.PostgresConfig({ sslMode = Some(mode) | r })

    pub def withApplicationName(name: String, cfg: PostgresConfig): PostgresConfig =
        let PostgresConfig.PostgresConfig(r) = cfg;
        PostgresConfig.PostgresConfig({ applicationName = name | r })

    pub def withConnectTimeoutSec(secs: Int32, cfg: PostgresConfig): PostgresConfig =
        let PostgresConfig.PostgresConfig(r) = cfg;
        PostgresConfig.PostgresConfig({ connectTimeoutSec = Int32.max(1, secs) | r })

    // --- Internal Parsing Helpers ---

    def stripLeadingSlash(s: String): String =
        match String.stripPrefix({substr = "/"}, s) {
            case Some(rest) => rest
            case None       => s
        }

    def parseUserInfo(raw: String): (String, String) =
        match String.indexOfLeft({substr = ":"}, raw) {
            case None =>
                (Url.decodePathSegment(raw), "")
            case Some(idx) =>
                let u = String.sliceLeft({end = idx}, raw);
                let p = String.sliceRight({start = idx + 1}, raw);
                (Url.decodePathSegment(u), Url.decodePathSegment(p))
        }

}
