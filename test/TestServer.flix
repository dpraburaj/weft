mod TestServer {
    use Assert.assertEq
    use Assert.assertTrue
    use Time.Clock
    use Weft.App
    use Weft.Auth
    use Weft.Json
    use Weft.Middleware
    use Weft.Principal
    use Weft.Req
    use Weft.Res
    use Weft.Router
    use Weft.Server
    use Weft.ServerConfig
    use Weft.ServerHandle
    use Weft.Status
    use Weft.TestEffects
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

}
