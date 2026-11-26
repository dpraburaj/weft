pub mod Weft.ServerConfig {
    use Weft.ServerConfig

    ///
    /// Configuration for the embedded HTTP server.
    /// Set `port = 0` to bind an ephemeral OS-assigned port (ideal for integration tests).
    /// `maxBodyBytes` caps incoming request body size (default 10 MiB; `<= 0` disables the limit).
    ///
    pub enum ServerConfig {
        case ServerConfig({
            host                 = String,
            port                 = Int32,
            backlog              = Int32,
            maxBodyBytes         = Int32,
            exposeInternalErrors = Bool
        })
    }

    def defaultMaxBodyBytes(): Int32 = 10 * 1024 * 1024

    pub def default(): ServerConfig =
        ServerConfig.ServerConfig({
            host                 = "127.0.0.1",
            port                 = 8080,
            backlog              = 128,
            maxBodyBytes         = defaultMaxBodyBytes(),
            exposeInternalErrors = false
        })

    pub def onPort(p: Int32): ServerConfig =
        ServerConfig.ServerConfig({
            host                 = "0.0.0.0",
            port                 = p,
            backlog              = 128,
            maxBodyBytes         = defaultMaxBodyBytes(),
            exposeInternalErrors = false
        })

    pub def local(p: Int32): ServerConfig =
        ServerConfig.ServerConfig({
            host                 = "127.0.0.1",
            port                 = p,
            backlog              = 128,
            maxBodyBytes         = defaultMaxBodyBytes(),
            exposeInternalErrors = false
        })

    pub def host(cfg: ServerConfig): String             = let ServerConfig.ServerConfig(r) = cfg; r#host
    pub def port(cfg: ServerConfig): Int32              = let ServerConfig.ServerConfig(r) = cfg; r#port
    pub def backlog(cfg: ServerConfig): Int32           = let ServerConfig.ServerConfig(r) = cfg; r#backlog
    pub def maxBodyBytes(cfg: ServerConfig): Int32      = let ServerConfig.ServerConfig(r) = cfg; r#maxBodyBytes
    pub def exposeInternalErrors(cfg: ServerConfig): Bool = let ServerConfig.ServerConfig(r) = cfg; r#exposeInternalErrors

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
    /// Sets the maximum allowed incoming request body size in bytes.
    /// Requests exceeding this limit are rejected immediately with `413 Payload Too Large`.
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

}
