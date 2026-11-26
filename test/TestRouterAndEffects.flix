mod TestRouterAndEffects {
    use Assert.assertEq
    use Assert.assertTrue
    use Weft.Auth
    use Weft.Cookie
    use Weft.CorsConfig
    use Weft.HttpError
    use Weft.Json
    use Weft.Middleware
    use Weft.Principal
    use Weft.Req
    use Weft.Request
    use Weft.Res
    use Weft.Response
    use Weft.Router
    use Weft.Status
    use Weft.TestClient
    use Weft.TestEffects
    use Weft.WithStatus
    use Logger.Severity

    @Test
    def testRoutingStaticParamsWildcardAndScope(): Unit \ Assert = {
        let sub = Router.empty()
            |> Router.get("/users/:id/posts/:postId", () -> {
                let uid = Req.requireIntParam("id");
                let pid = Req.requireParam("postId");
                Json.obj(("userId", Json.int(uid)) :: ("postId", Json.str(pid)) :: Nil)
            })
            |> Router.get("/assets/*path", () -> {
                let p = Req.requireParam("path");
                Response.text(p)
            });

        let app = Router.empty()
            |> Router.get("/ping", () -> "pong")
            |> Router.scope("/v1", sub)
            |> Router.toApp
            |> Middleware.errorJson;

        let r1 = TestClient.get("/ping", app);
        assertEq(expected = Status.ok(), Response.status(r1));
        assertEq(expected = "pong", Response.body(r1));

        let r2 = TestClient.get("/v1/users/42/posts/hello-world", app);
        assertEq(expected = Status.ok(), Response.status(r2));
        assertEq(expected = Ok(Json.obj(("userId", Json.int(42)) :: ("postId", Json.str("hello-world")) :: Nil)), Json.parse(Response.body(r2)));

        let r3 = TestClient.get("/v1/assets/js/app/bundle.js", app);
        assertEq(expected = Status.ok(), Response.status(r3));
        assertEq(expected = "js/app/bundle.js", Response.body(r3));

        // Invalid int param automatically raises 400 Bad Request via HttpError!
        let rBad = TestClient.get("/v1/users/not-a-number/posts/1", app);
        assertEq(expected = Status.badRequest(), Response.status(rBad))
    }

    @Test
    def testMethodNotAllowedAndHeadFallback(): Unit \ Assert = {
        let app = Router.empty()
            |> Router.get("/items", () -> "list-of-items")
            |> Router.post("/items", () -> WithStatus.WithStatus(Status.created(), "created"))
            |> Router.toApp
            |> Middleware.errorJson;

        // HEAD falls back to GET with empty body
        let rHead = TestClient.head("/items", app);
        assertEq(expected = Status.ok(), Response.status(rHead));
        assertEq(expected = "", Response.body(rHead));

        // DELETE returns 405 with Allow header
        let r405 = TestClient.delete("/items", app);
        assertEq(expected = Status.methodNotAllowed(), Response.status(r405));
        assertEq(expected = Some("GET, POST, HEAD"), Response.header("Allow", r405));

        // Unknown path returns 404 JSON
        let r404 = TestClient.get("/unknown", app);
        assertEq(expected = Status.notFound(), Response.status(r404));
        assertTrue(String.contains({substr = "Route not found"}, Response.body(r404)))
    }

    @Test
    def testAmbientResEffect(): Unit \ Assert = {
        let app = Router.empty()
            |> Router.get("/ambient", () -> {
                Res.setHeader("X-Custom", "from-effect");
                Res.addHeader("X-Multi", "one");
                Res.addHeader("X-Multi", "two");
                Res.setCookie(Cookie.make("theme", "dark"));
                Res.setStatus(Status.accepted());
                "accepted"
            })
            |> Router.toApp
            |> Middleware.errorText;

        let res = TestClient.get("/ambient", app);
        assertEq(expected = Status.accepted(), Response.status(res));
        assertEq(expected = Some("from-effect"), Response.header("X-Custom", res));
        assertEq(expected = "one" :: "two" :: Nil, Weft.Headers.getAll("X-Multi", Response.headers(res)));
        assertTrue(Option.nonEmpty(Response.header("Set-Cookie", res)))
    }

    @Test
    def testAuthEffectAndMiddleware(): Unit \ Assert = {
        let verify = tok -> if (tok == "good")
            Some(Principal.make("1", "Ada", "admin" :: Nil))
        else
            None;

        let secretRoutes = Router.empty()
            |> Router.get("/secret", () -> {
                Auth.requireRole("admin");
                "welcome ${Auth.userName()}"
            })
            |> Router.get("/super", () -> {
                Auth.requireRole("superadmin");
                "never"
            })
            |> Router.withMiddleware(Middleware.bearerAuth(verify));

        let app = secretRoutes
            |> Router.toApp
            |> Middleware.errorJson;

        let rNoTok = TestClient.get("/secret", app);
        assertEq(expected = Status.unauthorized(), Response.status(rNoTok));

        let rBadTok = TestClient.send(Request.get("/secret") |> Request.withBearer("wrong"), app);
        assertEq(expected = Status.unauthorized(), Response.status(rBadTok));

        let rOk = TestClient.send(Request.get("/secret") |> Request.withBearer("good"), app);
        assertEq(expected = Status.ok(), Response.status(rOk));
        assertEq(expected = "welcome Ada", Response.body(rOk));

        let rForbidden = TestClient.send(Request.get("/super") |> Request.withBearer("good"), app);
        assertEq(expected = Status.forbidden(), Response.status(rForbidden))
    }

    @Test
    def testAbortRecoveryMiddleware(): Unit \ Assert = {
        let app = Router.empty()
            |> Router.get("/boom", () -> {
                Abort.abort(RichString.fromString("simulated failure"));
                "unreachable"
            })
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.recoverAbort;

        let res = TestClient.get("/boom", app);
        assertEq(expected = Status.internalServerError(), Response.status(res));
        assertTrue(String.contains({substr = "simulated failure"}, Response.body(res)))
    }

    @Test
    def testCorsSecurityTimingAndLoggerDeterministically(): Unit \ Assert = {
        let app = Router.empty()
            |> Router.get("/data", () -> "ok")
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.cors(CorsConfig.permissive())
            |> Middleware.securityHeaders
            |> Middleware.timingHeader
            |> Middleware.requestLogger;

        // 100% pure test: deterministic stepping clock (+7ms per call) & captured logs!
        let (res, logs) = run {
            TestClient.get("/data", app)
        } with TestEffects.runCollectingLogger
          with TestEffects.runSteppingClock(1000i64, 7i64);

        assertEq(expected = Status.ok(), Response.status(res));
        assertEq(expected = Some("*"), Response.header("Access-Control-Allow-Origin", res));
        assertEq(expected = Some("nosniff"), Response.header("X-Content-Type-Options", res));
        // timingHeader calls Clock.now() twice (1007 -> 1014 => 7ms); requestLogger wraps it (1000 -> 1021 => 21ms)
        assertEq(expected = Some("7ms"), Response.header("X-Response-Time", res));
        assertEq(expected = (Severity.Info, "GET /data -> 200 OK (21ms)") :: Nil, logs);

        // OPTIONS preflight
        let preflight = run {
            TestClient.options("/data", app)
        } with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(0i64);

        assertEq(expected = Status.noContent(), Response.status(preflight));
        assertEq(expected = Some("*"), Response.header("Access-Control-Allow-Origin", preflight))
    }

}
