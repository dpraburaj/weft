pub mod Weft.ServerHandle {
    use Weft.ServerHandle

    import com.sun.net.httpserver.HttpServer
    import com.sun.net.httpserver.HttpsServer

    ///
    /// Handle to a running embedded HTTP or HTTPS server.
    ///
    pub enum ServerHandle {
        case Http(HttpServer, String)
        case Https(HttpsServer, String)
    }

    ///
    /// Returns the actual bound port (useful when started with `port = 0`).
    ///
    pub def port(h: ServerHandle): Int32 \ IO = match h {
        case ServerHandle.Http(srv, _)  => srv.getAddress().getPort()
        case ServerHandle.Https(srv, _) => srv.getAddress().getPort()
    }

    ///
    /// Returns the host address the server was configured to bind.
    ///
    pub def host(h: ServerHandle): String = match h {
        case ServerHandle.Http(_, hostAddr)  => hostAddr
        case ServerHandle.Https(_, hostAddr) => hostAddr
    }

    ///
    /// Returns `true` if the server is running with TLS/HTTPS enabled.
    ///
    pub def isTls(h: ServerHandle): Bool = match h {
        case ServerHandle.Http(_, _)  => false
        case ServerHandle.Https(_, _) => true
    }

    ///
    /// Returns `"https"` for TLS servers or `"http"` for plaintext servers.
    ///
    pub def scheme(h: ServerHandle): String =
        if (isTls(h)) "https" else "http"

    ///
    /// Returns the base URL (e.g. `"http://127.0.0.1:8080"` or `"https://127.0.0.1:8443"`).
    ///
    pub def url(h: ServerHandle): String \ IO =
        "${scheme(h)}://${host(h)}:${port(h)}"

    ///
    /// Gracefully stops the server, waiting up to `delaySeconds` for active requests.
    ///
    pub def stop(delaySeconds: Int32, h: ServerHandle): Unit \ IO = match h {
        case ServerHandle.Http(srv, _)  => srv.stop(delaySeconds)
        case ServerHandle.Https(srv, _) => srv.stop(delaySeconds)
    }

}
