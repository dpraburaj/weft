pub mod Weft.ServerConfig {
    use Weft.ServerConfig
    use Weft.TlsConfig

    ///
    /// Configuration for the embedded HTTP/HTTPS server.
    ///
    /// - `port = 0` binds an ephemeral OS-assigned port (ideal for integration tests).
    /// - `maxBodyBytes` caps incoming request body size (default 10 MiB; `<= 0` disables).
    /// - `readTimeoutMs` caps incoming request body reads (default 15s -> `408 Request Timeout`; `<= 0` disables).
    /// - `handlerTimeoutMs` caps handler execution time (default 30s -> `504 Gateway Timeout`; `<= 0` disables).
    /// - `shutdownGraceSeconds` sets how long `Server.serve` / `serveWithShutdown` waits for active requests to drain (default 5s).
    /// - `tls` optionally enables HTTPS via `Weft.TlsConfig`.
    ///
    pub enum ServerConfig {
        case ServerConfig({
            host                 = String,
            port                 = Int32,
            backlog              = Int32,
            maxBodyBytes         = Int32,
            exposeInternalErrors = Bool,
            readTimeoutMs        = Int64,
            handlerTimeoutMs     = Int64,
            shutdownGraceSeconds = Int32,
            tls                  = Option[TlsConfig]
        })
    }

    def defaultMaxBodyBytes(): Int32 = 10 * 1024 * 1024
    def defaultReadTimeoutMs(): Int64 = 15000i64
    def defaultHandlerTimeoutMs(): Int64 = 30000i64
    def defaultShutdownGraceSeconds(): Int32 = 5

    pub def default(): ServerConfig =
        ServerConfig.ServerConfig({
            host                 = "127.0.0.1",
            port                 = 8080,
            backlog              = 128,
            maxBodyBytes         = defaultMaxBodyBytes(),
            exposeInternalErrors = false,
            readTimeoutMs        = defaultReadTimeoutMs(),
            handlerTimeoutMs     = defaultHandlerTimeoutMs(),
            shutdownGraceSeconds = defaultShutdownGraceSeconds(),
            tls                  = None
        })

    pub def onPort(p: Int32): ServerConfig =
        default() |> withHost("0.0.0.0") |> withPort(p)

    pub def local(p: Int32): ServerConfig =
        default() |> withHost("127.0.0.1") |> withPort(p)

    pub def host(cfg: ServerConfig): String              = let ServerConfig.ServerConfig(r) = cfg; r#host
    pub def port(cfg: ServerConfig): Int32               = let ServerConfig.ServerConfig(r) = cfg; r#port
    pub def backlog(cfg: ServerConfig): Int32            = let ServerConfig.ServerConfig(r) = cfg; r#backlog
    pub def maxBodyBytes(cfg: ServerConfig): Int32       = let ServerConfig.ServerConfig(r) = cfg; r#maxBodyBytes
    pub def exposeInternalErrors(cfg: ServerConfig): Bool = let ServerConfig.ServerConfig(r) = cfg; r#exposeInternalErrors
    pub def readTimeoutMs(cfg: ServerConfig): Int64      = let ServerConfig.ServerConfig(r) = cfg; r#readTimeoutMs
    pub def handlerTimeoutMs(cfg: ServerConfig): Int64   = let ServerConfig.ServerConfig(r) = cfg; r#handlerTimeoutMs
    pub def shutdownGraceSeconds(cfg: ServerConfig): Int32 = let ServerConfig.ServerConfig(r) = cfg; r#shutdownGraceSeconds
    pub def tls(cfg: ServerConfig): Option[TlsConfig]    = let ServerConfig.ServerConfig(r) = cfg; r#tls
    pub def isTls(cfg: ServerConfig): Bool               = Option.nonEmpty(tls(cfg))

    pub def withHost(h: String, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ host = h | r })

    pub def withPort(p: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ port = p | r })

    pub def withBacklog(b: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ backlog = b | r })

    ///
    /// Sets the maximum allowed incoming request body size in bytes (`413 Payload Too Large`).
    /// Set to `<= 0` to disable the server-level cap.
    ///
    pub def withMaxBodyBytes(n: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ maxBodyBytes = n | r })

    ///
    /// Controls whether unhandled JVM exception messages are included in `500` fallback responses.
    /// Defaults to `false` (redacted `"Internal Server Error"`); enable only in local development.
    ///
    pub def withExposeInternalErrors(flag: Bool, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ exposeInternalErrors = flag | r })

    ///
    /// Sets the maximum time (in milliseconds) allowed for reading an incoming request body
    /// before failing with `408 Request Timeout`. Set to `<= 0` to disable.
    ///
    pub def withReadTimeoutMs(ms: Int64, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ readTimeoutMs = ms | r })

    ///
    /// Sets the maximum time (in milliseconds) allowed for an HTTP handler to produce a
    /// `Response` before interrupting it and returning `504 Gateway Timeout`.
    /// Set to `<= 0` to disable.
    ///
    pub def withHandlerTimeoutMs(ms: Int64, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ handlerTimeoutMs = ms | r })

    ///
    /// Sets the graceful shutdown drain window in seconds (used by `Server.serve` and
    /// `Server.serveWithShutdown`).
    ///
    pub def withShutdownGraceSeconds(secs: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ shutdownGraceSeconds = Int32.max(0, secs) | r })

    ///
    /// Enables TLS/HTTPS using `tlsCfg`.
    ///
    pub def withTls(tlsCfg: TlsConfig, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ tls = Some(tlsCfg) | r })

}
