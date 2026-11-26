pub mod Weft.Server {
    use Weft.App
    use Weft.Headers
    use Weft.Method
    use Weft.Request
    use Weft.Response
    use Weft.ServerConfig
    use Weft.ServerHandle
    use Weft.Status

    import com.sun.net.httpserver.HttpExchange
    import com.sun.net.httpserver.HttpHandler
    import com.sun.net.httpserver.HttpServer
    import com.sun.net.httpserver.{Headers => JHeaders}
    import java.io.IOException
    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.Runnable
    import java.lang.Runtime
    import java.lang.Thread
    import java.lang.{String => JString}
    import java.net.InetSocketAddress
    import java.nio.charset.StandardCharsets
    import java.util.concurrent.CountDownLatch
    import java.util.concurrent.Executors
    import java.util.{List => JList}

    ///
    /// Starts the embedded HTTP/1.1 server on Java 21 virtual threads and returns
    /// immediately with a `ServerHandle`.
    ///
    /// Notice that `app` has type `App[IO]` (`Request -> Response \ IO`), so the Flix
    /// compiler statically guarantees that EVERY custom algebraic effect (`Req`, `Res`,
    /// `HttpError`, `Auth`, `Logger`, `Clock`, domain stores, etc.) has been handled!
    ///
    pub def start(cfg: ServerConfig, app: App[IO]): Result[String, ServerHandle] \ IO =
        let ServerConfig.ServerConfig(c) = cfg;
        try {
            let addr = new InetSocketAddress(c#host, c#port);
            let srv = HttpServer.create(addr, c#backlog);
            let _ctx = srv.createContext("/", makeHttpHandler(app));
            srv.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
            srv.start();
            Ok(ServerHandle.ServerHandle(srv, c#host))
        } catch {
            case ex: IOException => Err("Failed to start server on ${c#host}:${c#port}: ${ex.getMessage()}")
        }

    ///
    /// Starts the server and blocks the current thread until the JVM receives a
    /// shutdown signal (Ctrl+C / SIGTERM), then gracefully stops the server.
    ///
    pub def serve(cfg: ServerConfig, app: App[IO]): Result[String, Unit] \ IO =
        match start(cfg, app) {
            case Err(e) => Err(e)
            case Ok(handle) =>
                let latch = new CountDownLatch(1);
                let shutdownRunnable = new Runnable {
                    def $run(_this: Runnable): Unit \ IO = {
                        ServerHandle.stop(1, handle);
                        latch.countDown()
                    }
                };
                Runtime.getRuntime().addShutdownHook(new Thread(shutdownRunnable));
                try {
                    latch.await();
                    Ok(())
                } catch {
                    case _: InterruptedException =>
                        ServerHandle.stop(1, handle);
                        Ok(())
                }
        }

    // --- JDK HttpExchange <-> Weft Bridge ---

    def makeHttpHandler(app: App[IO]): HttpHandler \ IO =
        new HttpHandler {
            def handle(_this: HttpHandler, exchange: HttpExchange): Unit \ IO =
                try {
                    let req = readRequest(exchange);
                    let res = app(req);
                    writeResponse(req, res, exchange)
                } catch {
                    case ex: Exception =>
                        try {
                            let fallback = Response.text("Internal Server Error: ${ex.getMessage()}")
                                |> Response.withStatus(Status.internalServerError());
                            let dummyReq = Request.get("/");
                            writeResponse(dummyReq, fallback, exchange)
                        } catch {
                            case _: Exception => ()
                        }
                }
        }

    def readRequest(exchange: HttpExchange): Request \ IO =
        let method = Method.parse(exchange.getRequestMethod());
        let uri = exchange.getRequestURI();
        let rawPath = uri.getRawPath();
        let rawQueryObj = uri.getRawQuery();
        let fullRawPath = if (Object.isNull(rawQueryObj)) rawPath else "${rawPath}?${rawQueryObj}";
        let jHeaders = exchange.getRequestHeaders();
        let flixHeaders = readHeaders(jHeaders);
        let bodyBytes = exchange.getRequestBody().readAllBytes();
        let bodyStr = new JString(bodyBytes, StandardCharsets.UTF_8);
        Request.make(method, fullRawPath)
            |> Request.withHeaders(flixHeaders)
            |> Request.withBody(bodyStr)

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
            let bodyStr = Response.body(res);
            let bodyBytes = bodyStr.getBytes(StandardCharsets.UTF_8);
            let len = Array.length(bodyBytes);
            if (len == 0) {
                exchange.sendResponseHeaders(statusCode, -1i64);
                exchange.close()
            } else {
                exchange.sendResponseHeaders(statusCode, Int32.toInt64(len));
                let out = exchange.getResponseBody();
                out.write(bodyBytes);
                out.close()
            }
        }

}
