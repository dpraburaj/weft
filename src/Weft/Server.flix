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

    import io.undertow.Undertow
    import io.undertow.Undertow$ListenerInfo
    import io.undertow.UndertowOptions
    import io.undertow.server.HttpHandler
    import io.undertow.server.HttpServerExchange
    import io.undertow.server.handlers.GracefulShutdownHandler
    import io.undertow.util.HeaderMap
    import io.undertow.util.HeaderValues
    import io.undertow.util.HttpString
    import java.io.ByteArrayOutputStream
    import java.io.InputStream
    import java.lang.{Boolean => JBoolean}
    import java.lang.Exception
    import java.lang.Integer
    import java.lang.InterruptedException
    import java.lang.{Long => JLong}
    import java.lang.{Object => JObject}
    import java.lang.Runnable
    import java.lang.Runtime
    import java.lang.Thread
    import java.net.InetSocketAddress
    import java.nio.charset.StandardCharsets
    import java.util.concurrent.CountDownLatch
    import java.util.concurrent.ExecutorService
    import java.util.concurrent.Executors
    import java.util.concurrent.TimeUnit
    import java.util.logging.{Level => JulLevel}
    import java.util.logging.{Logger => JulLogger}
    import org.xnio.Options

    def silenceRoutineServerLogs(): Unit \ IO = {
        JulLogger.getLogger("io.undertow").setLevel(JulLevel.WARNING);
        JulLogger.getLogger("org.xnio").setLevel(JulLevel.WARNING);
        JulLogger.getLogger("org.jboss.xnio").setLevel(JulLevel.WARNING);
        JulLogger.getLogger("org.jboss.threads").setLevel(JulLevel.WARNING);
        JulLogger.getLogger("org.jboss.logging").setLevel(JulLevel.WARNING)
    }

    ///
    /// Starts the embedded Undertow HTTP/1.1 + HTTP/2 (or HTTPS when `ServerConfig.withTls`
    /// is set) multi-event-loop server backed by Java 21 virtual threads and returns
    /// immediately with a `ServerHandle`.
    ///
    /// Undertow's XNIO I/O event loops (defaulting to one per CPU core) handle socket
    /// accept/read/write across all cores, then dispatch each incoming exchange onto its
    /// own virtual thread so blocking Flix handlers and database calls never stall an
    /// event-loop thread.
    ///
    /// Notice that `app` has type `App[IO]` (`Request -> Response \ IO`), so the Flix
    /// compiler statically guarantees that EVERY custom algebraic effect (`Req`, `Res`,
    /// `HttpError`, `Auth`, `Logger`, `Clock`, domain stores, etc.) has been handled!
    ///
    pub def start(cfg: ServerConfig, app: App[IO]): Result[String, ServerHandle] \ IO = {
        silenceRoutineServerLogs();
        let ServerConfig.ServerConfig(c) = cfg;
        let resolvedIoThreads =
            if (c#ioThreads > 0) c#ioThreads
            else Int32.max(1, Runtime.getRuntime().availableProcessors());
        let sslResult = match c#tls {
            case None         => Ok(None)
            case Some(tlsCfg) =>
                match TlsConfig.buildSslContext(tlsCfg) {
                    case Ok(ctx)  => Ok(Some(ctx))
                    case Err(err) => Err(err)
                }
        };
        match sslResult {
            case Err(tlsErr) => Err(tlsErr)
            case Ok(sslCtxOpt) =>
                let vExec = Executors.newVirtualThreadPerTaskExecutor();
                let coreHandler = makeHttpHandler(
                    c#maxBodyBytes,
                    c#readTimeoutMs,
                    c#handlerTimeoutMs,
                    c#exposeInternalErrors,
                    vExec,
                    app
                );
                let graceful = new GracefulShutdownHandler(coreHandler);
                try {
                    let b0 = Undertow.builder();
                    let b1 = b0.setIoThreads(resolvedIoThreads);
                    let b2 = b1.setWorkerThreads(2);
                    let b3 = b2.setSslEngineDelegatedTaskExecutor(vExec);
                    let backlogObj: JObject = checked_cast(Integer.valueOf(Int32.max(1, c#backlog)));
                    let maxEntityObj: JObject = checked_cast(JLong.valueOf(-1i64));
                    let http2Obj: JObject = checked_cast(JBoolean.valueOf(true));
                    let b4 = b3.setSocketOption(Options.BACKLOG, backlogObj);
                    let b5 = b4.setServerOption(UndertowOptions.MAX_ENTITY_SIZE, maxEntityObj);
                    let b6 = b5.setHandler(graceful);
                    let b7 = if (c#enableHttp2)
                        b6.setServerOption(UndertowOptions.ENABLE_HTTP2, http2Obj)
                    else
                        b6;
                    let isTls = Option.nonEmpty(sslCtxOpt);
                    let b8 = match sslCtxOpt {
                        case None         => b7.addHttpListener(c#port, c#host)
                        case Some(sslCtx) => b7.addHttpsListener(c#port, c#host, sslCtx)
                    };
                    let srv = b8.build();
                    srv.start();
                    let boundPort = extractBoundPort(srv, c#port);
                    Ok(ServerHandle.ServerHandle({
                        server    = srv,
                        graceful  = graceful,
                        executor  = vExec,
                        host      = c#host,
                        boundPort = boundPort,
                        ioThreads = resolvedIoThreads,
                        tls       = isTls
                    }))
                } catch {
                    case ex: Exception =>
                        try { vExec.shutdown() } catch { case _: Exception => () };
                        let rawMsg = ex.getMessage();
                        let msg = if (Object.isNull(rawMsg)) "Unexpected startup error" else rawMsg;
                        let proto = if (Option.nonEmpty(sslCtxOpt)) "HTTPS" else "HTTP";
                        Err("Failed to start ${proto} server on ${c#host}:${c#port}: ${msg}")
                }
        }
    }

    def extractBoundPort(srv: Undertow, fallbackPort: Int32): Int32 \ IO = {
        let listeners = srv.getListenerInfo();
        if (Object.isNull(listeners) or listeners.isEmpty())
            fallbackPort
        else {
            let info: Undertow$ListenerInfo = listeners.get(0);
            let addr = info.getAddress();
            if (Object.isNull(addr))
                fallbackPort
            else {
                let inet: InetSocketAddress = unchecked_cast(addr as InetSocketAddress);
                inet.getPort()
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

    // --- Undertow HttpServerExchange <-> Weft Bridge ---

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
        vExec: ExecutorService,
        app: App[IO]
    ): HttpHandler \ IO =
        new HttpHandler {
            def handleRequest(_this: HttpHandler, exchange: HttpServerExchange): Unit \ IO =
                if (exchange.isInIoThread()) {
                    let _ = exchange.dispatch(vExec, new Runnable {
                        def $run(_r: Runnable): Unit \ IO =
                            processExchange(
                                maxBodyBytes,
                                readTimeoutMs,
                                handlerTimeoutMs,
                                exposeInternalErrors,
                                app,
                                exchange
                            )
                    });
                    ()
                } else {
                    processExchange(
                        maxBodyBytes,
                        readTimeoutMs,
                        handlerTimeoutMs,
                        exposeInternalErrors,
                        app,
                        exchange
                    )
                }
        }

    def processExchange(
        maxBodyBytes: Int32,
        readTimeoutMs: Int64,
        handlerTimeoutMs: Int64,
        exposeInternalErrors: Bool,
        app: App[IO],
        exchange: HttpServerExchange
    ): Unit \ IO =
        try {
            let _ = exchange.startBlocking();
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
                    let dummyReq = Request.make(Method.parse(exchange.getRequestMethod().toString()), "/");
                    writeResponse(dummyReq, tooLarge, exchange)
                case Err(ReadError.ReadTimeout) =>
                    let timedOut = Response.text("Request Timeout: reading request body exceeded ${readTimeoutMs}ms")
                        |> Response.withStatus(Status.requestTimeout());
                    let dummyReq = Request.make(Method.parse(exchange.getRequestMethod().toString()), "/");
                    writeResponse(dummyReq, timedOut, exchange)
                case Err(ReadError.ReadFailed(msg)) =>
                    let bodyMsg = if (exposeInternalErrors) "Bad Request: ${msg}" else "Bad Request";
                    let bad = Response.text(bodyMsg)
                        |> Response.withStatus(Status.badRequest());
                    let dummyReq = Request.make(Method.parse(exchange.getRequestMethod().toString()), "/");
                    writeResponse(dummyReq, bad, exchange)
            }
        } catch {
            case ex: Exception =>
                try {
                    if (not exchange.isResponseStarted()) {
                        let rawMsg = ex.getMessage();
                        let safeMsg = if (Object.isNull(rawMsg)) "Unhandled exception" else rawMsg;
                        let bodyMsg = if (exposeInternalErrors)
                            "Internal Server Error: ${safeMsg}"
                        else
                            "Internal Server Error";
                        let fallback = Response.text(bodyMsg)
                            |> Response.withStatus(Status.internalServerError());
                        let dummyReq = Request.get("/");
                        writeResponse(dummyReq, fallback, exchange)
                    } else {
                        let _ = exchange.endExchange();
                        ()
                    }
                } catch {
                    case _: Exception =>
                        try { let _ = exchange.endExchange(); () } catch { case _: Exception => () }
                }
        }

    def readRequestWithTimeout(
        maxBodyBytes: Int32,
        readTimeoutMs: Int64,
        exchange: HttpServerExchange
    ): Result[ReadError, Request] \ IO = {
        let method = Method.parse(exchange.getRequestMethod().toString());
        let rawPathObj = exchange.getRequestURI();
        let rawPath = if (Object.isNull(rawPathObj)) "/" else rawPathObj;
        let rawQueryObj = exchange.getQueryString();
        let fullRawPath =
            if (Object.isNull(rawQueryObj) or String.isEmpty(rawQueryObj)) rawPath
            else "${rawPath}?${rawQueryObj}";
        let flixHeaders = readHeaders(exchange.getRequestHeaders());
        let contentLenOpt = match Headers.get("Content-Length", flixHeaders) {
            case Some(clStr) => Int64.fromString(String.trim(clStr))
            case None =>
                let cl = exchange.getRequestContentLength();
                if (cl >= 0i64) Some(cl) else None
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
            let hasBody =
                hasTransferEnc
                or (not exchange.isRequestComplete())
                or match contentLenOpt {
                    case Some(cl) => cl > 0i64
                    case None     => false
                };
            if (not hasBody) {
                Ok(
                    Request.make(method, fullRawPath)
                        |> Request.withHeaders(flixHeaders)
                )
            } else {
                match runWithTimeout(readTimeoutMs, () -> readBoundedBytes(exchange.getInputStream(), maxBodyBytes)) {
                    case TimedOutcome.Completed(Ok(bodyVec)) =>
                        let baseReq = Request.make(method, fullRawPath)
                            |> Request.withHeaders(flixHeaders);
                        if (Vector.isEmpty(bodyVec))
                            Ok(baseReq)
                        else
                            Ok(Request.withBytes(bodyVec, baseReq))
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

    def readHeaders(jHeaders: HeaderMap): Headers \ IO = {
        let iter = jHeaders.iterator();
        def loopHeaders(acc: Headers): Headers \ IO = {
            if (iter.hasNext()) {
                let hv: HeaderValues = iter.next();
                let key = hv.getHeaderName().toString();
                let valIter = hv.iterator();
                def loopVals(hAcc: Headers): Headers \ IO = {
                    if (valIter.hasNext()) {
                        let v: String = valIter.next();
                        loopVals(Headers.add(key, v, hAcc))
                    } else {
                        hAcc
                    }
                };
                loopHeaders(loopVals(acc))
            } else {
                acc
            }
        };
        loopHeaders(Headers.empty())
    }

    def writeResponse(req: Request, res: Response, exchange: HttpServerExchange): Unit \ IO = {
        let statusCode = Status.code(Response.status(res));
        let _ = exchange.setStatusCode(statusCode);
        let respHeaders = exchange.getResponseHeaders();
        List.forEach(match (k, v) -> {
            let hs = HttpString.tryFromString(k);
            if (not Object.isNull(hs)) {
                let _ = respHeaders.add(hs, v);
                ()
            } else {
                ()
            }
        }, Headers.toList(Response.headers(res)));
        let isHead = Request.method(req) == Method.Head;
        let noBodyStatus = statusCode == 204 or statusCode == 304 or isHead;
        if (noBodyStatus) {
            let _ = exchange.endExchange();
            ()
        } else {
            match Response.bodyValue(res) {
                case Body.Stream(streamFn) =>
                    // Leaving Content-Length unset enables HTTP/1.1 chunked transfer and HTTP/2 DATA frames
                    let out = exchange.getOutputStream();
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
                    };
                    let _ = exchange.endExchange();
                    ()
                case Body.Empty =>
                    let _ = exchange.setResponseContentLength(0i64);
                    let _ = exchange.endExchange();
                    ()
                case Body.Text(s) =>
                    if (String.isEmpty(s)) {
                        let _ = exchange.setResponseContentLength(0i64);
                        let _ = exchange.endExchange();
                        ()
                    } else {
                        let bodyBytes = s.getBytes(StandardCharsets.UTF_8);
                        let _ = exchange.setResponseContentLength(Int32.toInt64(Array.length(bodyBytes)));
                        let out = exchange.getOutputStream();
                        out.write(bodyBytes);
                        out.close();
                        let _ = exchange.endExchange();
                        ()
                    }
                case Body.Bytes(bodyVec) =>
                    let len = Vector.length(bodyVec);
                    if (len == 0) {
                        let _ = exchange.setResponseContentLength(0i64);
                        let _ = exchange.endExchange();
                        ()
                    } else {
                        let bodyBytes = Vector.toArray(Static, bodyVec);
                        let _ = exchange.setResponseContentLength(Int32.toInt64(len));
                        let out = exchange.getOutputStream();
                        out.write(bodyBytes);
                        out.close();
                        let _ = exchange.endExchange();
                        ()
                    }
            }
        }
    }

}
