mod TestServer {
    use Assert.assertEq
    use Assert.assertTrue
    use Time.Clock
    use Weft.App
    use Weft.Auth
    use Weft.Body
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Json
    use Weft.Middleware
    use Weft.Multipart
    use Weft.MultipartForm
    use Weft.Principal
    use Weft.Req
    use Weft.Res
    use Weft.Response
    use Weft.Router
    use Weft.Server
    use Weft.ServerConfig
    use Weft.ServerHandle
    use Weft.Status
    use Weft.TestEffects
    use Weft.UploadedFile
    use Weft.WithStatus

    import java.lang.Exception
    import java.net.URI
    import java.net.http.HttpClient
    import java.net.http.HttpRequest
    import java.net.http.HttpRequest$BodyPublishers
    import java.net.http.HttpResponse$BodyHandlers

    def verifyToken(token: String): Option[Principal] = match token {
        case "secret-token" => Some(Principal.make("u-1", "alice", "writer" :: Nil))
        case _              => None
    }

    @Test
    def testLiveLoopbackHttpServer(): Unit \ {Assert, IO} = {
        let protectedRoutes = Router.empty()
            |> Router.post("/echo/:tag", () -> {
                let tag = Req.requireParam("tag");
                let body = Req.jsonBody();
                let msg = Json.requireNonEmptyString("message", body);
                Res.addHeader("X-Echo-User", Auth.userName());
                WithStatus.WithStatus(
                    Status.created(),
                    Json.obj(
                        ("tag", Json.str(tag)) ::
                        ("message", Json.str(msg)) ::
                        ("user", Json.str(Auth.userName())) ::
                        Nil
                    )
                )
            })
            |> Router.withMiddleware(Middleware.bearerAuth(verifyToken));

        let app = Router.empty()
            |> Router.get("/health", () -> Json.obj(("service", Json.str("Weft")) :: ("ok", Json.bool(true)) :: Nil))
            |> Router.scope("/api", protectedRoutes)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.timingHeader
            |> Middleware.requestLogger;

        let ioApp: App[IO] = req ->
            run {
                app(req)
            } with TestEffects.runSilentLogger
              with Clock.runWithIO;

        match Server.start(ServerConfig.local(0), ioApp) {
            case Err(msg) =>
                Assert.fail("Failed to start live test server: ${msg}")
            case Ok(handle) =>
                let outcome = try {
                    let baseUrl = ServerHandle.url(handle);
                    let client = HttpClient.newHttpClient();
                    let strHandler = HttpResponse$BodyHandlers.ofString();
                    let noBody = HttpRequest$BodyPublishers.noBody();

                    // 1. Live GET /health
                    let getReq = HttpRequest.newBuilder(URI.create("${baseUrl}/health")).method("GET", noBody).build();
                    let getResp = client.send(getReq, strHandler);
                    let getBody: String = getResp.body();
                    assertEq(expected = 200, getResp.statusCode());
                    assertTrue(String.contains({substr = "\"service\":\"Weft\""}, getBody));

                    // 2. Live POST /api/echo/v1 without auth -> 401
                    let bodyPub = HttpRequest$BodyPublishers.ofString("{\"message\":\"hello weft\"}");
                    let u0 = HttpRequest.newBuilder(URI.create("${baseUrl}/api/echo/v1"));
                    let u1 = u0.header("Content-Type", "application/json");
                    let unauthReq = u1.method("POST", bodyPub).build();
                    let unauthResp = client.send(unauthReq, strHandler);
                    assertEq(expected = 401, unauthResp.statusCode());

                    // 3. Live POST /api/echo/v1 with Bearer auth -> 201 + custom header + JSON body
                    let bodyPub2 = HttpRequest$BodyPublishers.ofString("{\"message\":\"hello weft\"}");
                    let a0 = HttpRequest.newBuilder(URI.create("${baseUrl}/api/echo/v1"));
                    let a1 = a0.header("Content-Type", "application/json");
                    let a2 = a1.header("Authorization", "Bearer secret-token");
                    let authReq = a2.method("POST", bodyPub2).build();
                    let authResp = client.send(authReq, strHandler);
                    let authBody: String = authResp.body();
                    assertEq(expected = 201, authResp.statusCode());
                    assertTrue(String.contains({substr = "\"tag\":\"v1\""}, authBody));
                    assertTrue(String.contains({substr = "\"message\":\"hello weft\""}, authBody));
                    assertTrue(String.contains({substr = "\"user\":\"alice\""}, authBody));

                    // 4. Live 404 check
                    let missingReq = HttpRequest.newBuilder(URI.create("${baseUrl}/does-not-exist")).method("GET", noBody).build();
                    let missingResp = client.send(missingReq, strHandler);
                    let missingBody: String = missingResp.body();
                    assertEq(expected = 404, missingResp.statusCode());
                    assertTrue(String.contains({substr = "Route not found"}, missingBody));
                    Ok(())
                } catch {
                    case ex: Exception => Err(ex.getMessage())
                };
                ServerHandle.stop(0, handle);
                match outcome {
                    case Ok(())   => ()
                    case Err(msg) => Assert.fail("Live HTTP request failed: ${msg}")
                }
        }
    }

    @Test
    def testLiveBinaryEchoMultipartAndMaxBodyLimit(): Unit \ {Assert, IO} = {
        let app = Router.empty()
            |> Router.post("/binary", () -> Response.bytes("application/octet-stream", Req.bodyBytes()))
            |> Router.post("/upload", () -> {
                let form = Req.multipartForm();
                let f = MultipartForm.requireFile("img", form);
                Response.bytes(UploadedFile.contentType(f), UploadedFile.data(f))
            })
            |> Router.toApp
            |> Middleware.errorJson;

        let ioApp: App[IO] = req -> app(req);
        let cfg = ServerConfig.local(0) |> ServerConfig.withMaxBodyBytes(256);

        match Server.start(cfg, ioApp) {
            case Err(msg) =>
                Assert.fail("Failed to start live binary test server: ${msg}")
            case Ok(handle) =>
                let outcome = try {
                    let baseUrl = ServerHandle.url(handle);
                    let client = HttpClient.newHttpClient();
                    let bytesHandler = HttpResponse$BodyHandlers.ofByteArray();
                    let strHandler = HttpResponse$BodyHandlers.ofString();

                    // 1. Raw binary round-trip preserves non-UTF-8 bytes over TCP
                    let rawVec = Vector#{-119i8, 80i8, 78i8, 71i8, 13i8, 10i8, 26i8, 10i8, 0i8, -1i8, -2i8};
                    let rawArr = Vector.toArray(Static, rawVec);
                    let b0 = HttpRequest.newBuilder(URI.create("${baseUrl}/binary"));
                    let b1 = b0.header("Content-Type", "application/octet-stream");
                    let binReq = b1.method("POST", HttpRequest$BodyPublishers.ofByteArray(rawArr)).build();
                    let binResp = client.send(binReq, bytesHandler);
                    let binRespBytes: Array[Int8, IO] = binResp.body();
                    assertEq(expected = 200, binResp.statusCode());
                    assertEq(expected = rawVec, Array.toVector(binRespBytes));

                    // 2. Live multipart/form-data upload returns exact uploaded bytes
                    let boundary = "LiveBoundary123";
                    let uploaded = UploadedFile.make("img", "tiny.png", "image/png", rawVec);
                    let mpVec = Multipart.encode(boundary, ("title", "Logo") :: Nil, uploaded :: Nil);
                    let m0 = HttpRequest.newBuilder(URI.create("${baseUrl}/upload"));
                    let m1 = m0.header("Content-Type", "multipart/form-data; boundary=${boundary}");
                    let mpReq = m1.method("POST", HttpRequest$BodyPublishers.ofByteArray(Vector.toArray(Static, mpVec))).build();
                    let mpResp = client.send(mpReq, bytesHandler);
                    let mpRespBytes: Array[Int8, IO] = mpResp.body();
                    assertEq(expected = 200, mpResp.statusCode());
                    assertEq(expected = rawVec, Array.toVector(mpRespBytes));

                    // 3. Payload exceeding ServerConfig.maxBodyBytes (256) is rejected with 413
                    let bigArr: Array[Int8, IO] = Array.repeat(Static, 300, 65i8);
                    let g0 = HttpRequest.newBuilder(URI.create("${baseUrl}/binary"));
                    let g1 = g0.header("Content-Type", "application/octet-stream");
                    let bigReq = g1.method("POST", HttpRequest$BodyPublishers.ofByteArray(bigArr)).build();
                    let bigResp = client.send(bigReq, strHandler);
                    assertEq(expected = 413, bigResp.statusCode());

                    // 4. Weft.HttpClient.runWithJdk talks cleanly to the live server (binary round-trip)
                    let clientOutcome = Weft.HttpClient.runWithJdk(() ->
                        Weft.HttpClient.send(
                            ClientRequest.post("${baseUrl}/binary")
                                |> ClientRequest.withHeader("Content-Type", "application/octet-stream")
                                |> ClientRequest.withBytes(rawVec)
                        )
                    );
                    match clientOutcome {
                        case Ok(cResp) =>
                            assertEq(expected = 200, ClientResponse.status(cResp));
                            assertEq(expected = rawVec, ClientResponse.bodyBytes(cResp))
                        case Err(e) =>
                            Assert.fail("Weft.HttpClient.runWithJdk failed: ${e}")
                    };
                    Ok(())
                } catch {
                    case ex: Exception => Err(ex.getMessage())
                };
                ServerHandle.stop(0, handle);
                match outcome {
                    case Ok(())   => ()
                    case Err(msg) => Assert.fail("Live binary/multipart HTTP request failed: ${msg}")
                }
        }
    }

}
