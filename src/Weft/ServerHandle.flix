pub mod Weft.ServerHandle {
    use Weft.ServerHandle

    import io.undertow.Undertow
    import io.undertow.server.handlers.GracefulShutdownHandler
    import java.lang.Exception
    import java.lang.InterruptedException
    import java.util.concurrent.ExecutorService

    ///
    /// Handle to a running embedded Undertow HTTP or HTTPS server.
    ///
    pub enum ServerHandle {
        case ServerHandle({
            server    = Undertow,
            graceful  = GracefulShutdownHandler,
            executor  = ExecutorService,
            host      = String,
            boundPort = Int32,
            ioThreads = Int32,
            tls       = Bool
        })
    }

    ///
    /// Returns the actual bound port (useful when started with `port = 0`).
    ///
    pub def port(h: ServerHandle): Int32 =
        let ServerHandle.ServerHandle(r) = h;
        r#boundPort

    ///
    /// Returns the host address the server was configured to bind.
    ///
    pub def host(h: ServerHandle): String =
        let ServerHandle.ServerHandle(r) = h;
        r#host

    ///
    /// Returns the number of Undertow/XNIO event-loop I/O threads running on this server.
    ///
    pub def ioThreads(h: ServerHandle): Int32 =
        let ServerHandle.ServerHandle(r) = h;
        r#ioThreads

    ///
    /// Returns `true` if the server is running with TLS/HTTPS enabled.
    ///
    pub def isTls(h: ServerHandle): Bool =
        let ServerHandle.ServerHandle(r) = h;
        r#tls

    ///
    /// Returns `"https"` for TLS servers or `"http"` for plaintext servers.
    ///
    pub def scheme(h: ServerHandle): String =
        if (isTls(h)) "https" else "http"

    ///
    /// Returns the base URL (e.g. `"http://127.0.0.1:8080"` or `"https://127.0.0.1:8443"`).
    ///
    pub def url(h: ServerHandle): String =
        "${scheme(h)}://${host(h)}:${port(h)}"

    ///
    /// Gracefully stops the server, waiting up to `delaySeconds` for active requests to drain
    /// before tearing down Undertow listeners and the virtual-thread executor.
    ///
    pub def stop(delaySeconds: Int32, h: ServerHandle): Unit \ IO = {
        let ServerHandle.ServerHandle(r) = h;
        try {
            r#graceful.shutdown();
            if (delaySeconds > 0) {
                try {
                    let _ = r#graceful.awaitShutdown(Int32.toInt64(delaySeconds) * 1000i64);
                    ()
                } catch {
                    case _: InterruptedException => ()
                }
            } else {
                ()
            }
        } catch {
            case _: Exception => ()
        };
        try {
            r#server.stop()
        } catch {
            case _: Exception => ()
        };
        try {
            r#executor.shutdown()
        } catch {
            case _: Exception => ()
        }
    }

}
