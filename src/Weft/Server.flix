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
    import java.io.ByteArrayOutputStream
    import java.io.IOException
    import java.io.InputStream
    import java.lang.Exception
    import java.lang.InterruptedException
    import java.lang.Runnable
    import java.lang.Runtime
    import java.lang.Thread
    import java.net.InetSocketAddress
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
            let _ctx = srv.createContext("/", makeHttpHandler(c#maxBodyBytes, app));
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

    def makeHttpHandler(maxBodyBytes: Int32, app: App[IO]): HttpHandler \ IO =
        new HttpHandler {
            def handle(_this: HttpHandler, exchange: HttpExchange): Unit \ IO =
                try {
                    match readRequest(maxBodyBytes, exchange) {
                        case Ok(req) =>
                            let res = app(req);
                            writeResponse(req, res, exchange)
                        case Err(limitMsg) =>
                            let tooLarge = Response.text(limitMsg)
                                |> Response.withStatus(Status.payloadTooLarge());
                            let dummyReq = Request.make(Method.parse(exchange.getRequestMethod()), "/");
                            writeResponse(dummyReq, tooLarge, exchange)
                    }
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

    def readRequest(maxBodyBytes: Int32, exchange: HttpExchange): Result[String, Request] \ IO =
        let method = Method.parse(exchange.getRequestMethod());
        let uri = exchange.getRequestURI();
        let rawPath = uri.getRawPath();
        let rawQueryObj = uri.getRawQuery();
        let fullRawPath = if (Object.isNull(rawQueryObj)) rawPath else "${rawPath}?${rawQueryObj}";
        let jHeaders = exchange.getRequestHeaders();
        let flixHeaders = readHeaders(jHeaders);
        let declaredTooLarge = if (maxBodyBytes > 0) {
            match Headers.get("Content-Length", flixHeaders) {
                case Some(clStr) => match Int64.fromString(String.trim(clStr)) {
                    case Some(cl) => cl > Int32.toInt64(maxBodyBytes)
                    case None     => false
                }
                case None => false
            }
        } else {
            false
        };
        if (declaredTooLarge)
            Err("Request body exceeds maximum allowed size of ${maxBodyBytes} bytes")
        else
            match readBoundedBytes(exchange.getRequestBody(), maxBodyBytes) {
                case Err(msg) => Err(msg)
                case Ok(bodyVec) =>
                    Ok(
                        Request.make(method, fullRawPath)
                            |> Request.withHeaders(flixHeaders)
                            |> Request.withBytes(bodyVec)
                    )
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
            let bodyVec = Response.bodyBytes(res);
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
