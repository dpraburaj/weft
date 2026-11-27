mod TestServerHardeningAndProtocol {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.App
    use Weft.Body
    use Weft.ByteRange
    use Weft.Compression
    use Weft.CompressionConfig
    use Weft.Json
    use Weft.Middleware
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Server
    use Weft.ServerConfig
    use Weft.ServerHandle
    use Weft.SseEvent
    use Weft.StaticConfig
    use Weft.StaticFiles
    use Weft.StaticStore
    use Weft.Status
    use Weft.StreamWriter
    use Weft.TestClient
    use Weft.TlsConfig

    import java.io.{File => JFile}
    import java.io.FileInputStream
    import java.lang.Exception
    import java.lang.ProcessBuilder
    import java.lang.RuntimeException
    import java.lang.System
    import java.lang.Thread
    import java.net.URI
    import java.net.http.{HttpClient => JHttpClient}
    import java.net.http.{HttpRequest => JHttpRequest}
    import java.net.http.{HttpRequest$BodyPublishers => JBodyPublishers}
    import java.net.http.{HttpResponse$BodyHandlers => JBodyHandlers}
    import java.security.KeyStore
    import java.security.SecureRandom
    import javax.net.ssl.KeyManager
    import javax.net.ssl.SSLContext
    import javax.net.ssl.TrustManagerFactory

    // =========================================================================
    // 1. Streaming Bodies & SSE Unit Tests
    // =========================================================================

    @Test
    def testSseEventEncodingAndStreamCollection(): Unit \ {Assert, IO} = {
        let ev1 = SseEvent.named("order.updated", "line1\nline2")
            |> SseEvent.withId("42")
            |> SseEvent.withRetryMs(3000i64);
        let expected1 = "id: 42\nevent: order.updated\nretry: 3000\ndata: line1\ndata: line2\n\n";
        assertEq(expected = expected1, SseEvent.encode(ev1));

        let ev2 = SseEvent.json(Json.obj(("ok", Json.bool(true)) :: Nil));
        assertEq(expected = "data: {\"ok\":true}\n\n", SseEvent.encode(ev2));
        assertEq(expected = ": keepalive\n\n", SseEvent.comment("keepalive"));

        // Pure finite SSE response
        let pureRes = Response.sseEvents(ev1 :: ev2 :: Nil);
        assertFalse(Response.isStream(pureRes));
        assertEq(expected = Some("text/event-stream; charset=utf-8"), Response.header("Content-Type", pureRes));
        assertEq(expected = Some("no-cache"), Response.header("Cache-Control", pureRes));
        assertEq(expected = expected1 + "data: {\"ok\":true}\n\n", Response.body(pureRes));

        // Live streaming SSE response materialized in memory via Response.collectBody
        let streamRes = Response.sse(w -> {
            StreamWriter.sendSseComment("ping", w);
            StreamWriter.sendSseData("hello", w);
            StreamWriter.sendSse(ev2, w)
        });
        assertTrue(Response.isStream(streamRes));
        assertEq(expected = -1, Response.bodyLength(streamRes));
        let collected = Response.collectBody(streamRes);
        assertEq(expected = ": ping\n\ndata: hello\n\ndata: {\"ok\":true}\n\n", collected)
    }

    // =========================================================================
    // 2. HTTP ByteRange & StaticFiles 206 / 416 Tests
    // =========================================================================

    @Test
    def testByteRangeParsingAndStaticFilesPartialContent(): Unit \ Assert = {
        assertEq(expected = ByteRange.Satisfiable(0, 3), ByteRange.parse("bytes=0-3", 10));
        assertEq(expected = ByteRange.Satisfiable(4, 9), ByteRange.parse("bytes=4-", 10));
        assertEq(expected = ByteRange.Satisfiable(7, 9), ByteRange.parse("bytes=-3", 10));
        assertEq(expected = ByteRange.Satisfiable(0, 9), ByteRange.parse("bytes=0-999", 10));
        assertEq(expected = ByteRange.Satisfiable(0, 9), ByteRange.parse("bytes=-50", 10));
        assertEq(expected = ByteRange.Unsatisfiable, ByteRange.parse("bytes=10-12", 10));
        assertEq(expected = ByteRange.Unsatisfiable, ByteRange.parse("bytes=-0", 10));
        assertEq(expected = ByteRange.Ignored, ByteRange.parse("items=0-3", 10));
        assertEq(expected = ByteRange.Ignored, ByteRange.parse("bytes=0-1, 3-4", 10));
        assertEq(expected = ByteRange.Ignored, ByteRange.parse("bytes=5-2", 10));

        let files = Map#{"clip.txt" => Body.utf8Bytes("0123456789")};
        let app = StaticFiles.routes("/media", StaticConfig.default())
            |> Router.toApp
            |> Middleware.errorJson;

        StaticStore.runPure(files, () -> {
            // Full response advertises Accept-Ranges: bytes
            let full = TestClient.get("/media/clip.txt", app);
            assertEq(expected = Status.ok(), Response.status(full));
            assertEq(expected = Some("bytes"), Response.header("Accept-Ranges", full));
            assertEq(expected = "0123456789", Response.body(full));

            // 206 Partial Content for closed range
            let r206 = app(Request.get("/media/clip.txt") |> Request.withHeader("Range", "bytes=2-5"));
            assertEq(expected = Status.partialContent(), Response.status(r206));
            assertEq(expected = Some("bytes 2-5/10"), Response.header("Content-Range", r206));
            assertEq(expected = "2345", Response.body(r206));

            // 206 Partial Content for suffix range
            let rSuffix = app(Request.get("/media/clip.txt") |> Request.withHeader("Range", "bytes=-3"));
            assertEq(expected = Status.partialContent(), Response.status(rSuffix));
            assertEq(expected = Some("bytes 7-9/10"), Response.header("Content-Range", rSuffix));
            assertEq(expected = "789", Response.body(rSuffix));

            // 416 Range Not Satisfiable
            let r416 = app(Request.get("/media/clip.txt") |> Request.withHeader("Range", "bytes=99-120"));
            assertEq(expected = Status.rangeNotSatisfiable(), Response.status(r416));
            assertEq(expected = Some("bytes */10"), Response.header("Content-Range", r416));
            assertEq(expected = "", Response.body(r416))
        })
    }

    // =========================================================================
    // 3. Gzip & Deflate Compression Middleware Tests
    // =========================================================================

    @Test
    def testCompressionAlgorithmsAndMiddleware(): Unit \ Assert = {
        let sample = String.repeat(40, "Hello Weft compression! ");
        let sampleBytes = Body.utf8Bytes(sample);

        let gz = Compression.gzip(sampleBytes);
        assertTrue(Vector.length(gz) < Vector.length(sampleBytes));
        assertEq(expected = Ok(sampleBytes), Compression.gunzip(gz));

        let df = Compression.deflate(sampleBytes);
        assertTrue(Vector.length(df) < Vector.length(sampleBytes));
        assertEq(expected = Ok(sampleBytes), Compression.inflate(df));

        // Negotiation respects q-values and exclusions
        let cfg = CompressionConfig.default();
        assertEq(expected = Some("gzip"), Compression.negotiateEncoding(cfg, Some("deflate, gzip")));
        assertEq(expected = Some("deflate"), Compression.negotiateEncoding(cfg, Some("gzip;q=0.2, deflate;q=0.9")));
        assertEq(expected = Some("deflate"), Compression.negotiateEncoding(cfg, Some("gzip;q=0, deflate")));
        assertEq(expected = None, Compression.negotiateEncoding(cfg, Some("br")));

        // Middleware.compress
        let app = Router.empty()
            |> Router.get("/big", () ->
                Response.text(sample) |> Response.withHeader("ETag", "\"v1\"")
            )
            |> Router.get("/tiny", () -> Response.text("hi"))
            |> Router.get("/png", () -> Response.bytes("image/png", sampleBytes))
            |> Router.get("/sse", () -> Response.sseEvents(SseEvent.data(sample) :: Nil))
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.compress;

        // 1. Large text response compressed with gzip + weak ETag + Vary
        let gzRes = app(Request.get("/big") |> Request.withHeader("Accept-Encoding", "gzip, deflate"));
        assertEq(expected = Status.ok(), Response.status(gzRes));
        assertEq(expected = Some("gzip"), Response.header("Content-Encoding", gzRes));
        assertEq(expected = Some("Accept-Encoding"), Response.header("Vary", gzRes));
        assertEq(expected = Some("W/\"v1\""), Response.header("ETag", gzRes));
        assertEq(expected = Ok(sampleBytes), Compression.gunzip(Response.bodyBytes(gzRes)));

        // 2. Deflate when client only accepts deflate
        let dfRes = app(Request.get("/big") |> Request.withHeader("Accept-Encoding", "deflate"));
        assertEq(expected = Some("deflate"), Response.header("Content-Encoding", dfRes));
        assertEq(expected = Ok(sampleBytes), Compression.inflate(Response.bodyBytes(dfRes)));

        // 3. Small body skipped
        let tinyRes = app(Request.get("/tiny") |> Request.withHeader("Accept-Encoding", "gzip"));
        assertEq(expected = None, Response.header("Content-Encoding", tinyRes));
        assertEq(expected = "hi", Response.body(tinyRes));

        // 4. Non-compressible PNG and SSE skipped
        let pngRes = app(Request.get("/png") |> Request.withHeader("Accept-Encoding", "gzip"));
        assertEq(expected = None, Response.header("Content-Encoding", pngRes));

        let sseRes = app(Request.get("/sse") |> Request.withHeader("Accept-Encoding", "gzip"));
        assertEq(expected = None, Response.header("Content-Encoding", sseRes))
    }

    // =========================================================================
    // 4. Live Server: Chunked Streaming, SSE, Gzip, Timeouts & Graceful Shutdown
    // =========================================================================

    @Test
    def testLiveStreamingSseGzipTimeoutAndGracefulShutdown(): Unit \ {Assert, IO} = {
        let bigText = String.repeat(50, "Weft live gzip payload! ");
        let app = Router.empty()
            |> Router.get("/stream", () ->
                Response.stream("text/plain; charset=utf-8", w -> {
                    StreamWriter.writeTextChunk("chunk-1|", w);
                    StreamWriter.writeTextChunk("chunk-2|", w);
                    StreamWriter.writeTextChunk("chunk-3", w)
                })
            )
            |> Router.get("/events", () ->
                Response.sse(w -> {
                    StreamWriter.sendSse(SseEvent.named("tick", "1") |> SseEvent.withId("1"), w);
                    StreamWriter.sendSse(SseEvent.named("tick", "2") |> SseEvent.withId("2"), w)
                })
            )
            |> Router.get("/compressed", () -> Response.text(bigText))
            |> Router.get("/slow", () -> {
                Thread.sleep(400i64);
                Response.text("too late")
            })
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.compress;

        let ioApp: App[IO] = req -> app(req);
        let cfg = ServerConfig.local(0)
            |> ServerConfig.withHandlerTimeoutMs(100i64)
            |> ServerConfig.withShutdownGraceSeconds(1);

        match Server.start(cfg, ioApp) {
            case Err(msg) => Assert.fail("Failed to start server: ${msg}")
            case Ok(handle) =>
                let outcome = try {
                    let baseUrl = ServerHandle.url(handle);
                    let client = JHttpClient.newHttpClient();
                    let strHandler = JBodyHandlers.ofString();
                    let bytesHandler = JBodyHandlers.ofByteArray();
                    let noBody = JBodyPublishers.noBody();

                    // 1. Live chunked stream
                    let sReq = JHttpRequest.newBuilder(URI.create("${baseUrl}/stream")).method("GET", noBody).build();
                    let sResp = client.send(sReq, strHandler);
                    let sBody: String = sResp.body();
                    assertEq(expected = 200, sResp.statusCode());
                    assertEq(expected = "chunk-1|chunk-2|chunk-3", sBody);

                    // 2. Live SSE stream
                    let sseReq = JHttpRequest.newBuilder(URI.create("${baseUrl}/events")).method("GET", noBody).build();
                    let sseResp = client.send(sseReq, strHandler);
                    let sseBody: String = sseResp.body();
                    assertEq(expected = 200, sseResp.statusCode());
                    assertTrue(String.contains({substr = "event: tick\ndata: 1\n\n"}, sseBody));
                    assertTrue(String.contains({substr = "event: tick\ndata: 2\n\n"}, sseBody));

                    // 3. Live Gzip compression over TCP
                    let g0 = JHttpRequest.newBuilder(URI.create("${baseUrl}/compressed"));
                    let g1 = g0.header("Accept-Encoding", "gzip");
                    let gReq = g1.method("GET", noBody).build();
                    let gResp = client.send(gReq, bytesHandler);
                    let gBytes: Array[Int8, IO] = gResp.body();
                    assertEq(expected = 200, gResp.statusCode());
                    match Compression.gunzip(Array.toVector(gBytes)) {
                        case Ok(decoded) => assertEq(expected = bigText, Body.utf8String(decoded))
                        case Err(e)      => Assert.fail("Expected valid gzip response: ${e}")
                    };

                    // 4. Live handler timeout -> 504 Gateway Timeout
                    let slowReq = JHttpRequest.newBuilder(URI.create("${baseUrl}/slow")).method("GET", noBody).build();
                    let slowResp = client.send(slowReq, strHandler);
                    assertEq(expected = 504, slowResp.statusCode());
                    Ok(())
                } catch {
                    case ex: Exception => Err(ex.getMessage())
                };

                // 5. Coordinated graceful shutdown executes every hook even if one throws
                let orderRef = Ref.fresh(Static, Nil);
                let hooks =
                    (() -> Ref.transform(xs -> "hook1" :: xs, orderRef)) ::
                    (() -> throw new RuntimeException("simulated cleanup failure")) ::
                    (() -> Ref.transform(xs -> "hook3" :: xs, orderRef)) ::
                    Nil;
                Server.shutdownGracefully(0, handle, hooks);
                assertEq(expected = "hook1" :: "hook3" :: Nil, List.reverse(Ref.get(orderRef)));

                match outcome {
                    case Ok(())   => ()
                    case Err(msg) => Assert.fail("Live server hardening test failed: ${msg}")
                }
        }
    }

    // =========================================================================
    // 5. Live TLS / HTTPS Server Test (PKCS12 KeyStore + HttpsServer)
    // =========================================================================

    @Test
    def testLiveTlsHttpsServerAndInvalidKeystoreError(): Unit \ {Assert, IO} = {
        // Missing keystore returns clean Err
        let badTls = ServerConfig.local(0)
            |> ServerConfig.withTls(TlsConfig.pkcs12("/nonexistent/weft-missing.p12", "secret"));
        match Server.start(badTls, _ -> Response.ok("never")) {
            case Err(msg) => assertTrue(String.contains({substr = "TLS configuration error"}, msg))
            case Ok(h) =>
                ServerHandle.stop(0, h);
                Assert.fail("Expected TLS startup failure for missing keystore")
        };

        // Generate an ephemeral self-signed PKCS12 keystore using JDK's bundled keytool
        let tmpDir = System.getProperty("java.io.tmpdir");
        let ksFile = new JFile(tmpDir, "weft-tls-test-${System.nanoTime()}.p12");
        let ksPath = ksFile.getAbsolutePath();
        let ksPass = "wefttest123";
        let keytoolBin = "${System.getProperty("java.home")}/bin/keytool";

        let cmd: Array[String, IO] = Array#{
            keytoolBin, "-genkeypair", "-alias", "weft",
            "-keyalg", "RSA", "-keysize", "2048",
            "-storetype", "PKCS12",
            "-keystore", ksPath,
            "-storepass", ksPass,
            "-keypass", ksPass,
            "-validity", "1",
            "-dname", "CN=localhost",
            "-ext", "SAN=IP:127.0.0.1,DNS:localhost"
        } @ Static;
        let proc = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        let exitCode = proc.waitFor();
        assertEq(expected = 0, exitCode);

        let tlsCfg = ServerConfig.local(0) |> ServerConfig.withTls(TlsConfig.pkcs12(ksPath, ksPass));
        let app: App[IO] = _ -> Response.text("hello over tls");

        match Server.start(tlsCfg, app) {
            case Err(msg) =>
                let _ = ksFile.delete();
                Assert.fail("Failed to start HTTPS server: ${msg}")
            case Ok(handle) =>
                assertTrue(ServerHandle.isTls(handle));
                assertEq(expected = "https", ServerHandle.scheme(handle));
                let baseUrl = ServerHandle.url(handle);
                assertTrue(String.startsWith({prefix = "https://"}, baseUrl));

                let outcome = try {
                    // Build client SSLContext trusting the ephemeral self-signed keystore
                    let ks = KeyStore.getInstance("PKCS12");
                    let fis = new FileInputStream(ksPath);
                    ks.load(fis, ksPass.toCharArray());
                    fis.close();
                    let tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                    tmf.init(ks);
                    let clientSsl = SSLContext.getInstance("TLS");
                    let noKeys: Array[KeyManager, IO] = Array#{} @ Static;
                    clientSsl.init(noKeys, tmf.getTrustManagers(), new SecureRandom());

                    let client = JHttpClient.newBuilder().sslContext(clientSsl).build();
                    let req = JHttpRequest.newBuilder(URI.create("${baseUrl}/secure")).method("GET", JBodyPublishers.noBody()).build();
                    let resp = client.send(req, JBodyHandlers.ofString());
                    let body: String = resp.body();
                    assertEq(expected = 200, resp.statusCode());
                    assertEq(expected = "hello over tls", body);
                    Ok(())
                } catch {
                    case ex: Exception => Err(ex.getMessage())
                };
                ServerHandle.stop(0, handle);
                let _ = ksFile.delete();
                match outcome {
                    case Ok(())   => ()
                    case Err(msg) => Assert.fail("Live HTTPS request failed: ${msg}")
                }
        }
    }

}
