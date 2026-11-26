pub mod Weft.ServerConfig {
    use Weft.ServerConfig

    ///
    /// Configuration for the embedded HTTP server.
    /// Set `port = 0` to bind an ephemeral OS-assigned port (ideal for integration tests).
    ///
    pub enum ServerConfig {
        case ServerConfig({
            host    = String,
            port    = Int32,
            backlog = Int32
        })
    }

    pub def default(): ServerConfig =
        ServerConfig.ServerConfig({
            host    = "127.0.0.1",
            port    = 8080,
            backlog = 128
        })

    pub def onPort(p: Int32): ServerConfig =
        ServerConfig.ServerConfig({
            host    = "0.0.0.0",
            port    = p,
            backlog = 128
        })

    pub def local(p: Int32): ServerConfig =
        ServerConfig.ServerConfig({
            host    = "127.0.0.1",
            port    = p,
            backlog = 128
        })

    pub def withHost(h: String, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ host = h | r })

    pub def withPort(p: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ port = p | r })

    pub def withBacklog(b: Int32, cfg: ServerConfig): ServerConfig =
        let ServerConfig.ServerConfig(r) = cfg;
        ServerConfig.ServerConfig({ backlog = b | r })

}
