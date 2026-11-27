pub mod Weft.Server {
    use Weft.App
    use Weft.Body
    use Weft.Headers
    use Weft.Method
    use Weft.Request
    use Weft.Response
    use Weft.ServerConfig
    use Weft.ServerHandle
    use Weft.Status
    use Weft.StreamWriter
    use Weft.TlsConfig

    import com.sun.net.httpserver.HttpExchange
    import com.sun.net.httpserver.HttpHandler
    import com.sun.net.httpserver.HttpServer
    import com.sun.net.httpserver.HttpsConfigurator
    import com.sun.net.httpserver.HttpsServer
    import com.sun.net.httpserver.{Headers => JHeaders}
    import java.io.ByteArrayOutputStream
    import java.io.IOException
    import java.io.InputStream
    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.Runnable
    import java.lang.Runtime
    import java.lang.Thread
    import java.net.InetSocketAddress
    import java.nio.charset.StandardCharsets
    import java.util.concurrent.CountDownLatch
    import java.util.concurrent.Executors
    import java.util.concurrent.TimeUnit
    import java.util.{List => JList}

    ///
    /// Starts the embedded HTTP/1.1 (or HTTPS when `ServerConfig.withTls` is set) server
    /// on Java 21 virtual threads and returns immediately with a `ServerHandle`.
    ///
    /// Notice that `app` has type `App[IO]` (`Request -> Response \ IO`), so the Flix
    /// compiler statically guarantees that EVERY custom algebraic effect (`Req`, `Res`,
    /// `HttpError`, `Auth`, `Logger`, `Clock`, domain stores, etc.) has been handled!
    ///
    pub def start(cfg: ServerConfig, app: App[IO]): Result[String, ServerHandle] \ IO = {
        let ServerConfig.ServerConfig(c) = cfg;
        let httpHandler = makeHttpHandler(
            c#maxBodyBytes,
            c#readTimeoutMs,
            c#handlerTimeoutMs,
            c#exposeInternalErrors,
            app
        );
        match c#tls {
            case None =>
                try {
                    let addr = new InetSocketAddress(c#host, c#port);
                    let srv = HttpServer.create(addr, c#backlog);
                    let _ctx = srv.createContext("/", httpHandler);
                    srv.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
                    srv.start();
                    Ok(ServerHandle.Http(srv, c#host))
                } catch {
                    case ex: IOException => Err("Failed to start server on ${c#host}:${c#port}: ${ex.getMessage()}")
                }
            case Some(tlsCfg) =>
                match TlsConfig.buildSslContext(tlsCfg) {
                    case Err(tlsErr) => Err(tlsErr)
                    case Ok(sslCtx) =>
                        try {
                            let addr = new InetSocketAddress(c#host, c#port);
                            let srv = HttpsServer.create(addr, c#backlog);
                            srv.setHttpsConfigurator(new HttpsConfigurator(sslCtx));
                            let _ctx = srv.createContext("/", httpHandler);
                            srv.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
                            srv.start();
                            Ok(ServerHandle.Https(srv, c#host))
                        } catch {
                            case ex: IOException => Err("Failed to start HTTPS server on ${c#host}:${c#port}: ${ex.getMessage()}")
                        }
                }
        }
    }

    ///
    /// Starts the server and blocks the current thread until the JVM receives a
    /// shutdown signal (Ctrl+C / SIGTERM), then gracefully drains active requests.
    ///
    pub def serve(cfg: ServerConfig, app: App[IO]): Result[String, Unit] \ IO =
        serveWithShutdown(cfg, Nil, app)

    ///
    /// Starts the server and coordinates graceful shutdown on Ctrl+C / SIGTERM:
    /// 1. Stops accepting new connections and waits up to `ServerConfig.shutdownGraceSeconds(cfg)`
    ///    for in-flight HTTP requests to complete.
    /// 2. Runs each registered cleanup hook in `onShutdown` (e.g. `() -> WorkerHandle.stop(w)`,
    ///    `() -> Sqlite.close(db)`) in order, isolating any hook exceptions so every cleanup runs.
    ///
    pub def serveWithShutdown(
        cfg: ServerConfig,
        onShutdown: List[Unit -> Unit \ IO],
        app: App[IO]
    ): Result[String, Unit] \ IO =
        match start(cfg, app) {
            case Err(e) => Err(e)
            case Ok(handle) =>
                let graceSecs = ServerConfig.shutdownGraceSeconds(cfg);
                let latch = new CountDownLatch(1);
                let shutdownRunnable = new Runnable {
                    def $run(_this: Runnable): Unit \ IO = {
                        shutdownGracefully(graceSecs, handle, onShutdown);
                        latch.countDown()
                    }
                };
                Runtime.getRuntime().addShutdownHook(new Thread(shutdownRunnable));
                try {
                    latch.await();
                    Ok(())
                } catch {
                    case _: InterruptedException =>
                        shutdownGracefully(graceSecs, handle, onShutdown);
                        Ok(())
                }
        }

    ///
    /// Stops `handle` (waiting up to `graceSeconds` for in-flight HTTP requests) and then
    /// runs every hook in `onShutdown` in order, catching exceptions per hook so one
    /// failing cleanup never skips the remaining hooks.
    ///
    pub def shutdownGracefully(
        graceSeconds: Int32,
        handle: ServerHandle,
        onShutdown: List[Unit -> Unit \ IO]
    ): Unit \ IO = {
        try {
            ServerHandle.stop(Int32.max(0, graceSeconds), handle)
        } catch {
            case _: Exception => ()
        };
        List.forEach(hook ->
            try {
                hook()
            } catch {
                case _: Exception => ()
            },
            onShutdown
        )
    }

    // --- Timeout Execution Helper (Virtual Thread + CountDownLatch) ---

    enum TimedOutcome[a] {
        case Completed(a)
        case Failed(String)
        case TimedOut
    }

    def runWithTimeout(timeoutMs: Int64, action: Unit -> a \ IO): TimedOutcome[a] \ IO =
        if (timeoutMs <= 0i64) {
            try {
                TimedOutcome.Completed(action())
            } catch {
                case ex: Exception =>
                    let rawMsg = ex.getMessage();
                    TimedOutcome.Failed(if (Object.isNull(rawMsg)) "Unhandled exception" else rawMsg)
            }
        } else {
            let latch = new CountDownLatch(1);
            let resultRef: Ref[Option[TimedOutcome[a]], Static] = Ref.fresh(Static, None);
            let worker = new Runnable {
                def $run(_this: Runnable): Unit \ IO = {
                    let out = try {
                        TimedOutcome.Completed(action())
                    } catch {
                        case ex: Exception =>
                            let rawMsg = ex.getMessage();
                            TimedOutcome.Failed(if (Object.isNull(rawMsg)) "Unhandled exception" else rawMsg)
                    };
                    Ref.put(Some(out), resultRef);
                    latch.countDown()
                }
            };
            let t = Thread.ofVirtual().start(worker);
            let finished = try {
                latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            } catch {
                case _: InterruptedException => false
            };
            if (finished) {
                match Ref.get(resultRef) {
                    case Some(out) => out
                    case None      => TimedOutcome.Failed("Empty timeout result")
                }
            } else {
                t.interrupt();
                TimedOutcome.TimedOut
            }
        }

    // --- JDK HttpExchange <-> Weft Bridge ---

    enum ReadError {
        case TooLarge(String)
        case ReadTimeout
        case ReadFailed(String)
    }

    def makeHttpHandler(
        maxBodyBytes: Int32,
        readTimeoutMs: Int64,
        handlerTimeoutMs: Int64,
        exposeInternalErrors: Bool,
        app: App[IO]
    ): HttpHandler \ IO =
        new HttpHandler {
            def handle(_this: HttpHandler, exchange: HttpExchange): Unit \ IO =
                try {
                    match readRequestWithTimeout(maxBodyBytes, readTimeoutMs, exchange) {
                        case Ok(req) =>
                            match runWithTimeout(handlerTimeoutMs, () -> app(req)) {
                                case TimedOutcome.Completed(res) =>
                                    writeResponse(req, res, exchange)
                                case TimedOutcome.TimedOut =>
                                    let timeoutRes = Response.text("Gateway Timeout: handler exceeded ${handlerTimeoutMs}ms")
                                        |> Response.withStatus(Status.gatewayTimeout());
                                    writeResponse(req, timeoutRes, exchange)
                                case TimedOutcome.Failed(errMsg) =>
                                    let bodyMsg = if (exposeInternalErrors)
                                        "Internal Server Error: ${errMsg}"
                                    else
                                        "Internal Server Error";
                                    let fallback = Response.text(bodyMsg)
                                        |> Response.withStatus(Status.internalServerError());
                                    writeResponse(req, fallback, exchange)
                            }
                        case Err(ReadError.TooLarge(limitMsg)) =>
                            let tooLarge = Response.text(limitMsg)
                                |> Response.withStatus(Status.payloadTooLarge());
                            let dummyReq = Request.make(Method.parse(exchange.getRequestMethod()), "/");
                            writeResponse(dummyReq, tooLarge, exchange)
                        case Err(ReadError.ReadTimeout) =>
                            let timedOut = Response.text("Request Timeout: reading request body exceeded ${readTimeoutMs}ms")
                                |> Response.withStatus(Status.requestTimeout());
                            let dummyReq = Request.make(Method.parse(exchange.getRequestMethod()), "/");
                            writeResponse(dummyReq, timedOut, exchange)
                        case Err(ReadError.ReadFailed(msg)) =>
                            let bodyMsg = if (exposeInternalErrors) "Bad Request: ${msg}" else "Bad Request";
                            let bad = Response.text(bodyMsg)
                                |> Response.withStatus(Status.badRequest());
                            let dummyReq = Request.make(Method.parse(exchange.getRequestMethod()), "/");
                            writeResponse(dummyReq, bad, exchange)
                    }
                } catch {
                    case ex: Exception =>
                        try {
                            let bodyMsg = if (exposeInternalErrors)
                                "Internal Server Error: ${ex.getMessage()}"
                            else
                                "Internal Server Error";
                            let fallback = Response.text(bodyMsg)
                                |> Response.withStatus(Status.internalServerError());
                            let dummyReq = Request.get("/");
                            writeResponse(dummyReq, fallback, exchange)
                        } catch {
                            case _: Exception => ()
                        }
                }
        }

    def readRequestWithTimeout(
        maxBodyBytes: Int32,
        readTimeoutMs: Int64,
        exchange: HttpExchange
    ): Result[ReadError, Request] \ IO = {
        let method = Method.parse(exchange.getRequestMethod());
        let uri = exchange.getRequestURI();
        let rawPath = uri.getRawPath();
        let rawQueryObj = uri.getRawQuery();
        let fullRawPath = if (Object.isNull(rawQueryObj)) rawPath else "${rawPath}?${rawQueryObj}";
        let flixHeaders = readHeaders(exchange.getRequestHeaders());
        let contentLenOpt = match Headers.get("Content-Length", flixHeaders) {
            case Some(clStr) => Int64.fromString(String.trim(clStr))
            case None        => None
        };
        let hasTransferEnc = Option.nonEmpty(Headers.get("Transfer-Encoding", flixHeaders));
        let declaredTooLarge = if (maxBodyBytes > 0) {
            match contentLenOpt {
                case Some(cl) => cl > Int32.toInt64(maxBodyBytes)
                case None     => false
            }
        } else {
            false
        };
        if (declaredTooLarge)
            Err(ReadError.TooLarge("Request body exceeds maximum allowed size of ${maxBodyBytes} bytes"))
        else {
            let hasBody = hasTransferEnc or match contentLenOpt {
                case Some(cl) => cl > 0i64
                case None     => false
            };
            if (not hasBody) {
                Ok(
                    Request.make(method, fullRawPath)
                        |> Request.withHeaders(flixHeaders)
                )
            } else {
                match runWithTimeout(readTimeoutMs, () -> readBoundedBytes(exchange.getRequestBody(), maxBodyBytes)) {
                    case TimedOutcome.Completed(Ok(bodyVec)) =>
                        Ok(
                            Request.make(method, fullRawPath)
                                |> Request.withHeaders(flixHeaders)
                                |> Request.withBytes(bodyVec)
                        )
                    case TimedOutcome.Completed(Err(msg)) => Err(ReadError.TooLarge(msg))
                    case TimedOutcome.TimedOut           => Err(ReadError.ReadTimeout)
                    case TimedOutcome.Failed(msg)        => Err(ReadError.ReadFailed(msg))
                }
            }
        }
    }

    def readBoundedBytes(stream: InputStream, maxBodyBytes: Int32): Result[String, Vector[Int8]] \ IO =
        if (maxBodyBytes <= 0) {
            let all = stream.readAllBytes();
            Ok(Array.toVector(all))
        } else {
            let out = new ByteArrayOutputStream();
            let buf: Array[Int8, IO] = Array.repeat(Static, 8192, 0i8);
            def loop(total: Int32): Result[String, Vector[Int8]] \ IO = {
                let n = stream.read(buf, 0, 8192);
                if (n < 0) {
                    Ok(Array.toVector(out.toByteArray()))
                } else {
                    let nextTotal = total + n;
                    if (nextTotal > maxBodyBytes)
                        Err("Request body exceeds maximum allowed size of ${maxBodyBytes} bytes")
                    else {
                        out.write(buf, 0, n);
                        loop(nextTotal)
                    }
                }
            };
            loop(0)
        }

    def readHeaders(jHeaders: JHeaders): Headers \ IO =
        let keyIter = jHeaders.keySet().iterator();
        def loopKeys(acc: Headers): Headers \ IO = {
            if (keyIter.hasNext()) {
                let key: String = keyIter.next();
                let values: JList[String] = jHeaders.get(key);
                let nextAcc = if (Object.isNull(values))
                    acc
                else {
                    let valIter = values.iterator();
                    def loopVals(hAcc: Headers): Headers \ IO = {
                        if (valIter.hasNext()) {
                            let v: String = valIter.next();
                            loopVals(Headers.add(key, v, hAcc))
                        } else {
                            hAcc
                        }
                    };
                    loopVals(acc)
                };
                loopKeys(nextAcc)
            } else {
                acc
            }
        };
        loopKeys(Headers.empty())

    def writeResponse(req: Request, res: Response, exchange: HttpExchange): Unit \ IO =
        let respHeaders = exchange.getResponseHeaders();
        List.forEach(match (k, v) -> respHeaders.add(k, v), Headers.toList(Response.headers(res)));
        let statusCode = Status.code(Response.status(res));
        let isHead = Request.method(req) == Method.Head;
        let noBodyStatus = statusCode == 204 or statusCode == 304 or isHead;
        if (noBodyStatus) {
            exchange.sendResponseHeaders(statusCode, -1i64);
            exchange.close()
        } else {
            match Response.bodyValue(res) {
                case Body.Stream(streamFn) =>
                    // 0i64 enables HTTP/1.1 Transfer-Encoding: chunked in JDK HttpServer
                    exchange.sendResponseHeaders(statusCode, 0i64);
                    let out = exchange.getResponseBody();
                    let writer = StreamWriter.make(
                        bs -> out.write(Vector.toArray(Static, bs)),
                        () -> out.flush()
                    );
                    try {
                        streamFn(writer);
                        out.flush();
                        out.close()
                    } catch {
                        case _: Exception =>
                            try { out.close() } catch { case _: Exception => () }
                    }
                case Body.Empty =>
                    exchange.sendResponseHeaders(statusCode, -1i64);
                    exchange.close()
                case Body.Text(s) =>
                    if (String.isEmpty(s)) {
                        exchange.sendResponseHeaders(statusCode, -1i64);
                        exchange.close()
                    } else {
                        let bodyBytes = s.getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(statusCode, Int32.toInt64(Array.length(bodyBytes)));
                        let out = exchange.getResponseBody();
                        out.write(bodyBytes);
                        out.close()
                    }
                case Body.Bytes(bodyVec) =>
                    let len = Vector.length(bodyVec);
                    if (len == 0) {
                        exchange.sendResponseHeaders(statusCode, -1i64);
                        exchange.close()
                    } else {
                        let bodyBytes = Vector.toArray(Static, bodyVec);
                        exchange.sendResponseHeaders(statusCode, Int32.toInt64(len));
                        let out = exchange.getResponseBody();
                        out.write(bodyBytes);
                        out.close()
                    }
            }
        }

}
