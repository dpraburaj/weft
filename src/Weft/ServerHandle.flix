pub mod Weft.ServerHandle {
    use Weft.ServerHandle

    import com.sun.net.httpserver.HttpServer

    ///
    /// Handle to a running embedded HTTP server.
    ///
    pub enum ServerHandle {
        case ServerHandle(HttpServer, String)
    }

    ///
    /// Returns the actual bound port (useful when started with `port = 0`).
    ///
    pub def port(h: ServerHandle): Int32 \ IO =
        let ServerHandle.ServerHandle(srv, _) = h;
        srv.getAddress().getPort()

    ///
    /// Returns the host address the server was configured to bind.
    ///
    pub def host(h: ServerHandle): String =
        let ServerHandle.ServerHandle(_, hostAddr) = h;
        hostAddr

    ///
    /// Returns the base HTTP URL (e.g. `"http://127.0.0.1:8080"`).
    ///
    pub def url(h: ServerHandle): String \ IO =
        "http://${host(h)}:${port(h)}"

    ///
    /// Gracefully stops the server, waiting up to `delaySeconds` for active requests.
    ///
    pub def stop(delaySeconds: Int32, h: ServerHandle): Unit \ IO =
        let ServerHandle.ServerHandle(srv, _) = h;
        srv.stop(delaySeconds)

}
