mod TestHttpAndJson {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Cookie
    use Weft.Headers
    use Weft.HttpError
    use Weft.Json
    use Weft.Method
    use Weft.Request
    use Weft.Response
    use Weft.SameSite
    use Weft.Status
    use Weft.Url

    @Test
    def testUrlQueryParsing(): Unit \ Assert = {
        let q = Url.parseQuery("?name=Ada+Lovelace&lang=Flix%200.63&flag");
        assertEq(expected = Some("Ada Lovelace"), Map.get("name", q));
        assertEq(expected = Some("Flix 0.63"), Map.get("lang", q));
        assertEq(expected = Some(""), Map.get("flag", q))
    }

    @Test
    def testUrlPathSplittingAndJoin(): Unit \ Assert = {
        assertEq(expected = "api" :: "v1" :: "hello world" :: "a+b" :: Nil, Url.splitPath("/api/v1/hello%20world/a+b/?x=1"));
        assertEq(expected = "/api/v1/todos", Url.joinPaths("/api/v1/", "/todos/"));
        assertEq(expected = "/", Url.normalizePath("///"))
    }

    @Test
    def testHeadersCaseInsensitiveAndMultiValue(): Unit \ Assert = {
        let h = Headers.empty()
            |> Headers.set("Content-Type", "application/json")
            |> Headers.add("Set-Cookie", "a=1")
            |> Headers.add("set-cookie", "b=2");
        assertEq(expected = Some("application/json"), Headers.get("content-type", h));
        assertTrue(Headers.contains("CONTENT-TYPE", h));
        assertEq(expected = "a=1" :: "b=2" :: Nil, Headers.getAll("SET-COOKIE", h));
        let h2 = Headers.remove("Content-Type", h);
        assertFalse(Headers.contains("content-type", h2))
    }

    @Test
    def testCookieSerializeAndParse(): Unit \ Assert = {
        let c = Cookie.make("session", "xyz")
            |> Cookie.withPath("/api")
            |> Cookie.withMaxAge(3600)
            |> Cookie.withSecure(true)
            |> Cookie.withSameSite(SameSite.Strict);
        let serialized = Cookie.toHeaderValue(c);
        assertEq(expected = "session=xyz; Path=/api; Max-Age=3600; HttpOnly; Secure; SameSite=Strict", serialized);
        let parsed = Cookie.parseHeader("session=xyz; theme=dark");
        assertEq(expected = Some("xyz"), Map.get("session", parsed));
        assertEq(expected = Some("dark"), Map.get("theme", parsed))
    }

    @Test
    def testRequestBearerToken(): Unit \ Assert = {
        let req = Request.get("/me") |> Request.withBearer("secret-123");
        assertEq(expected = Some("secret-123"), Request.bearerToken(req));
        let reqNoAuth = Request.get("/me");
        assertEq(expected = None, Request.bearerToken(reqNoAuth));
        let reqBasic = Request.get("/me") |> Request.withHeader("Authorization", "Basic abc");
        assertEq(expected = None, Request.bearerToken(reqBasic))
    }

    @Test
    def testMethodParse(): Unit \ Assert = {
        assertEq(expected = Method.Get, Method.parse("get"));
        assertEq(expected = Method.Post, Method.parse(" POST "));
        assertEq(expected = Method.Custom("PURGE"), Method.parse("purge"))
    }

    @Test
    def testJsonRoundTrip(): Unit \ Assert = {
        let sample = Json.obj(
            ("name",   Json.str("Ada \"The First\"\nLine2\\end")) ::
            ("age",    Json.int(36)) ::
            ("score",  Json.float(99.5)) ::
            ("active", Json.bool(true)) ::
            ("empty",  Json.nullValue()) ::
            ("tags",   Json.arr(Json.str("math") :: Json.str("code") :: Nil)) ::
            Nil
        );
        let encoded = Json.encode(sample);
        match Json.parse(encoded) {
            case Ok(decoded) => assertEq(expected = sample, decoded)
            case Err(msg)    => Assert.fail("Expected valid JSON round-trip, got error: ${msg}")
        }
    }

    @Test
    def testJsonUnicodeEscapeAndInvalidInputs(): Unit \ Assert = {
        match Json.parse("{\"ch\":\"\\u0041\"}") {
            case Ok(j) =>
                assertEq(expected = Some("A"), Option.flatMap(Json.asString, Json.getField("ch", j)))
            case Err(msg) =>
                Assert.fail("Unexpected parse failure: ${msg}")
        };
        assertTrue(Result.isErr(Json.parse("")));
        assertTrue(Result.isErr(Json.parse("{\"unterminated\": [1, 2")));
        assertTrue(Result.isErr(Json.parse("{\"a\": 1} trailing")))
    }

    @Test
    def testJsonEffectfulExtractors(): Unit \ Assert = {
        let res = HttpError.runAsJson(() -> {
            let j = Json.parseOrBadRequest("{\"title\":\"   \"}");
            let _t = Json.requireNonEmptyString("title", j);
            Response.ok("never")
        });
        assertEq(expected = Status.badRequest(), Response.status(res));
        assertTrue(String.contains({substr = "must not be empty"}, Response.body(res)))
    }

}
