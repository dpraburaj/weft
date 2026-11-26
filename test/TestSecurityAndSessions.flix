mod TestSecurityAndSessions {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Auth
    use Weft.Body
    use Weft.Cookie
    use Weft.Crypto
    use Weft.Csrf
    use Weft.CsrfConfig
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.Json
    use Weft.Middleware
    use Weft.MultipartForm
    use Weft.OptionalAuth
    use Weft.Principal
    use Weft.Random
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Session
    use Weft.SessionConfig
    use Weft.SessionData
    use Weft.SessionStore
    use Weft.Status
    use Weft.TestClient
    use Weft.TestEffects
    use Weft.UploadedFile

    def extractSessionCookieValue(res: Response): Option[String] =
        Response.header("Set-Cookie", res) |> Option.flatMap(hdr -> {
            let firstPart = match String.indexOfLeft({substr = ";"}, hdr) {
                case Some(idx) => String.sliceLeft({end = idx}, hdr)
                case None      => hdr
            };
            match String.indexOfLeft({substr = "="}, firstPart) {
                case Some(eqIdx) => Some(String.sliceRight({start = eqIdx + 1}, firstPart))
                case None        => None
            }
        })

    def loadUser(uid: String): Option[Principal] = match uid {
        case "u-1" => Some(Principal.make("u-1", "Ada", "customer" :: "admin" :: Nil))
        case "u-2" => Some(Principal.make("u-2", "Grace", "customer" :: Nil))
        case _     => None
    }

    @Test
    def testRandomDeterministicFixedAndSecure(): Unit \ {Assert, IO} = {
        let (t1, u1) = Random.runDeterministic(12345i64, () -> (Random.tokenHex(16), Random.uuidV4()));
        let (t2, u2) = Random.runDeterministic(12345i64, () -> (Random.tokenHex(16), Random.uuidV4()));
        assertEq(expected = t1, t2);
        assertEq(expected = u1, u2);
        assertEq(expected = 32, String.length(t1));
        assertEq(expected = 36, String.length(u1));
        assertEq(expected = '4', String.charAt(14, u1));

        let fixed = Random.runFixedSequence(Vector#{1i8, 2i8, 3i8} :: Nil, () -> Random.tokenHex(3));
        assertEq(expected = "010203", fixed);

        let (live1, live2) = Random.runWithSecureRandom(() -> (Random.tokenBase64Url(32), Random.tokenBase64Url(32)));
        assertTrue(String.length(live1) >= 40);
        assertFalse(live1 == live2)
    }

    @Test
    def testCryptoSha256HmacSignedCookiesAndPasswordHashing(): Unit \ Assert = {
        // Known NIST SHA-256 vectors
        assertEq(
            expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Crypto.sha256Hex("")
        );
        assertEq(
            expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Crypto.sha256Hex("abc")
        );

        // Hex and Base64URL round-trip
        let raw = Vector#{-128i8, 0i8, 15i8, 127i8, -1i8};
        assertEq(expected = Ok(raw), Crypto.hexDecode(Crypto.hexEncode(raw)));
        assertEq(expected = Ok(raw), Crypto.base64UrlDecode(Crypto.base64UrlEncode(raw)));

        // Webhook HMAC verification over raw bytes
        let payload = Body.utf8Bytes("{\"event\":\"payment.succeeded\",\"amount\":4999}");
        let sig = Crypto.hmacSha256Hex("whsec_test", Body.utf8String(payload));
        assertTrue(Crypto.verifyHmacHex("whsec_test", payload, sig));
        assertFalse(Crypto.verifyHmacHex("wrong_secret", payload, sig));
        assertFalse(Crypto.verifyHmacHex("whsec_test", Body.utf8Bytes("tampered"), sig));

        // Signed cookie verification via Cookie + Req
        let secret = "cookie-signing-key";
        let signedCookie = Cookie.makeSigned(secret, "cart", "cart-99");
        let signedVal = match String.indexOfLeft({substr = ";"}, Cookie.toHeaderValue(signedCookie)) {
            case Some(i) => String.slice({start = 5}, {end = i}, Cookie.toHeaderValue(signedCookie))
            case None    => ""
        };
        assertEq(expected = Some("cart-99"), Cookie.verifySigned(secret, signedVal));
        assertEq(expected = None, Cookie.verifySigned(secret, "tampered" + signedVal));
        assertEq(expected = None, Cookie.verifySigned("other-secret", signedVal));

        let req = Request.get("/") |> Request.withCookie("cart", signedVal);
        let verified = Req.runWith(req, () -> Req.signedCookie(secret, "cart"));
        assertEq(expected = Some("cart-99"), verified);

        // PBKDF2-HMAC-SHA256 password hashing (low iterations for fast deterministic test)
        let (h1, h2) = Random.runDeterministic(99i64, () -> (
            Crypto.hashPasswordWithIterations(1000, "correct-horse-battery-staple"),
            Crypto.hashPasswordWithIterations(1000, "correct-horse-battery-staple")
        ));
        assertFalse(h1 == h2); // unique salts
        assertTrue(String.startsWith({prefix = "pbkdf2_sha256$1000$"}, h1));
        assertTrue(Crypto.verifyPassword("correct-horse-battery-staple", h1));
        assertTrue(Crypto.verifyPassword("correct-horse-battery-staple", h2));
        assertFalse(Crypto.verifyPassword("wrong-password", h1));
        assertFalse(Crypto.verifyPassword("correct-horse-battery-staple", "corrupted-hash"))
    }

    @Test
    def testSessionLifecycleGuestCartLoginRotationFlashAndLogout(): Unit \ Assert = {
        let cfg = SessionConfig.default("super-secret-session-key") |> SessionConfig.withTtlSeconds(3600);

        let app = Router.empty()
            |> Router.get("/browse", () ->
                Json.obj(("cart", Json.str(Session.getOrDefault("cart_id", "none"))) :: Nil)
            )
            |> Router.post("/cart/add", () -> {
                Session.put("cart_id", "cart-42");
                Session.putFlash("notice", "Added to cart");
                Response.seeOther("/cart")
            })
            |> Router.get("/cart", () -> {
                let flash = Option.getWithDefault("", Session.takeFlash("notice"));
                let cart = Session.getOrDefault("cart_id", "none");
                let user = Session.getOrDefault(Auth.sessionUserIdKey(), "guest");
                Json.obj(
                    ("cart", Json.str(cart)) ::
                    ("flash", Json.str(flash)) ::
                    ("user", Json.str(user)) ::
                    ("sid", Json.str(Session.sessionId())) ::
                    Nil
                )
            })
            |> Router.post("/login", () -> {
                Auth.loginSession("u-1");
                "logged-in"
            })
            |> Router.post("/logout", () -> {
                Auth.logoutSession();
                "logged-out"
            })
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.session(cfg);

        region rc {
            let nowMs = Ref.fresh(rc, 1000000i64);
            run {
                // 1. Anonymous read-only request does NOT emit Set-Cookie
                let rBrowse = TestClient.get("/browse", app);
                assertEq(expected = Status.ok(), Response.status(rBrowse));
                assertEq(expected = None, Response.header("Set-Cookie", rBrowse));

                // 2. Guest adds to cart + sets flash -> emits signed Set-Cookie
                let rAdd = TestClient.send(Request.post("/cart/add"), app);
                assertEq(expected = Status.seeOther(), Response.status(rAdd));
                let cookie1 = match extractSessionCookieValue(rAdd) {
                    case Some(c) => c
                    case None    => { Assert.fail("Expected Set-Cookie after session mutation"); "" }
                };

                // 3. Read /cart with cookie -> receives cart_id + flash once
                let rCart1 = TestClient.send(Request.get("/cart") |> Request.withCookie("weft_session", cookie1), app);
                assertTrue(String.contains({substr = "\"cart\":\"cart-42\""}, Response.body(rCart1)));
                assertTrue(String.contains({substr = "\"flash\":\"Added to cart\""}, Response.body(rCart1)));

                // 4. Second read /cart -> flash was consumed and is now empty
                let rCart2 = TestClient.send(Request.get("/cart") |> Request.withCookie("weft_session", cookie1), app);
                assertTrue(String.contains({substr = "\"flash\":\"\""}, Response.body(rCart2)));

                // 5. Login rotates session ID (anti-fixation) while preserving guest cart!
                let rLogin = TestClient.send(Request.post("/login") |> Request.withCookie("weft_session", cookie1), app);
                let cookie2 = match extractSessionCookieValue(rLogin) {
                    case Some(c) => c
                    case None    => { Assert.fail("Expected rotated Set-Cookie after login"); "" }
                };
                assertFalse(cookie1 == cookie2);

                // Old session ID was deleted on rotation
                let rOld = TestClient.send(Request.get("/browse") |> Request.withCookie("weft_session", cookie1), app);
                assertTrue(String.contains({substr = "\"cart\":\"none\""}, Response.body(rOld)));

                // New session ID has BOTH logged-in user AND preserved guest cart
                let rAuthedCart = TestClient.send(Request.get("/cart") |> Request.withCookie("weft_session", cookie2), app);
                assertTrue(String.contains({substr = "\"cart\":\"cart-42\""}, Response.body(rAuthedCart)));
                assertTrue(String.contains({substr = "\"user\":\"u-1\""}, Response.body(rAuthedCart)));

                // 6. Tampered cookie is rejected cleanly
                let rTampered = TestClient.send(Request.get("/browse") |> Request.withCookie("weft_session", cookie2 + "X"), app);
                assertTrue(String.contains({substr = "\"cart\":\"none\""}, Response.body(rTampered)));

                // 7. Logout destroys session and sends Max-Age=0 cookie
                let rLogout = TestClient.send(Request.post("/logout") |> Request.withCookie("weft_session", cookie2), app);
                let logoutCookieHdr = Option.getWithDefault("", Response.header("Set-Cookie", rLogout));
                assertTrue(String.contains({substr = "Max-Age=0"}, logoutCookieHdr));
                let rAfterLogout = TestClient.send(Request.get("/browse") |> Request.withCookie("weft_session", cookie2), app);
                assertTrue(String.contains({substr = "\"cart\":\"none\""}, Response.body(rAfterLogout)));

                // 8. Expiration check via manual clock
                let rNew = TestClient.send(Request.post("/cart/add"), app);
                let cookie3 = Option.getWithDefault("", extractSessionCookieValue(rNew));
                Ref.put(1000000i64 + 4000i64 * 1000i64, nowMs); // advance past 3600s TTL
                let rExpired = TestClient.send(Request.get("/browse") |> Request.withCookie("weft_session", cookie3), app);
                assertTrue(String.contains({substr = "\"cart\":\"none\""}, Response.body(rExpired)))
            } with SessionStore.runPure
              with Random.runDeterministic(777i64)
              with TestEffects.runManualClock(nowMs)
        }
    }

    @Test
    def testSessionStoreInMemoryAndSqlitePersistence(): Unit \ {Assert, IO} = {
        let s1 = SessionData.make(
            "sid-1",
            Map#{"cart_id" => "c-10"},
            Map#{"info" => "saved"},
            5000i64,
            1000i64,
            1000i64
        );
        let s1Updated = SessionData.make(
            "sid-1",
            Map#{"cart_id" => "c-10", "coupon" => "SAVE10"},
            Map.empty(),
            9000i64,
            1000i64,
            2000i64
        );
        let sExpired = SessionData.make("sid-old", Map.empty(), Map.empty(), 1500i64, 500i64, 500i64);

        // 1. Concurrent InMemory backend
        let mem = SessionStore.makeInMemory();
        SessionStore.runInMemory(mem, () -> {
            SessionStore.saveSession(s1);
            SessionStore.saveSession(sExpired);
            assertEq(expected = Some(s1), SessionStore.loadSession("sid-1", 2000i64));
            assertEq(expected = None, SessionStore.loadSession("sid-old", 2000i64));
            SessionStore.saveSession(s1Updated);
            assertEq(expected = Some(s1Updated), SessionStore.loadSession("sid-1", 2000i64));
            SessionStore.saveSession(sExpired);
            assertEq(expected = 1, SessionStore.pruneExpired(2000i64));
            SessionStore.deleteSession("sid-1");
            assertEq(expected = None, SessionStore.loadSession("sid-1", 2000i64))
        });

        // 2. Persistent SQLite backend via Db effect
        let sqlRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            SessionStore.initSchema();
            SessionStore.runWithDb(() -> {
                SessionStore.saveSession(s1);
                SessionStore.saveSession(sExpired);
                assertEq(expected = Some(s1), SessionStore.loadSession("sid-1", 2000i64));
                SessionStore.saveSession(s1Updated);
                assertEq(expected = Some(s1Updated), SessionStore.loadSession("sid-1", 2000i64));
                assertEq(expected = 1, SessionStore.pruneExpired(2000i64));
                SessionStore.deleteSession("sid-1");
                assertEq(expected = None, SessionStore.loadSession("sid-1", 2000i64))
            })
        }));
        match sqlRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("SQLite SessionStore persistence test failed")
        }
    }

    @Test
    def testOptionalAuthAndSessionAuthMiddleware(): Unit \ Assert = {
        let cfg = SessionConfig.default("auth-secret");

        let storefront = Router.empty()
            |> Router.get("/home", () -> {
                let greeting = match OptionalAuth.userName() {
                    case Some(name) => "Hello, ${name}"
                    case None       => "Hello, Guest"
                };
                greeting
            })
            |> Router.withMiddleware(Middleware.optionalSessionAuth(loadUser));

        let apiAccount = Router.empty()
            |> Router.get("/api/me", () -> "user:${Auth.userId()}:${Auth.userName()}")
            |> Router.withMiddleware(Middleware.sessionAuth(loadUser));

        let ssrCheckout = Router.empty()
            |> Router.get("/checkout", () -> "checkout:${Auth.userName()}")
            |> Router.withMiddleware(Middleware.sessionAuthOrRedirect("/login", loadUser));

        let app = Router.empty()
            |> Router.post("/login", () -> { Auth.loginSession("u-1"); "ok" })
            |> Router.merge(storefront)
            |> Router.merge(apiAccount)
            |> Router.merge(ssrCheckout)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.session(cfg);

        run {
            // Guest requests
            let rGuestHome = TestClient.get("/home", app);
            assertEq(expected = Status.ok(), Response.status(rGuestHome));
            assertEq(expected = "Hello, Guest", Response.body(rGuestHome));

            let rGuestApi = TestClient.get("/api/me", app);
            assertEq(expected = Status.unauthorized(), Response.status(rGuestApi));

            let rGuestCheckout = TestClient.get("/checkout", app);
            assertEq(expected = Status.seeOther(), Response.status(rGuestCheckout));
            assertEq(expected = Some("/login"), Response.header("Location", rGuestCheckout));

            // Sign in
            let rLogin = TestClient.send(Request.post("/login"), app);
            let sidCookie = Option.getWithDefault("", extractSessionCookieValue(rLogin));

            let rAuthHome = TestClient.send(Request.get("/home") |> Request.withCookie("weft_session", sidCookie), app);
            assertEq(expected = "Hello, Ada", Response.body(rAuthHome));

            let rAuthApi = TestClient.send(Request.get("/api/me") |> Request.withCookie("weft_session", sidCookie), app);
            assertEq(expected = Status.ok(), Response.status(rAuthApi));
            assertEq(expected = "user:u-1:Ada", Response.body(rAuthApi));

            let rAuthCheckout = TestClient.send(Request.get("/checkout") |> Request.withCookie("weft_session", sidCookie), app);
            assertEq(expected = Status.ok(), Response.status(rAuthCheckout));
            assertEq(expected = "checkout:Ada", Response.body(rAuthCheckout))
        } with SessionStore.runPure
          with Random.runDeterministic(321i64)
          with TestEffects.runFixedClock(50000i64)
    }

    @Test
    def testCsrfProtectionFormHeaderMultipartAndHtmlHelpers(): Unit \ Assert = {
        let sessionCfg = SessionConfig.default("csrf-session-secret");
        let csrfCfg = CsrfConfig.default();

        let webRoutes = Router.empty()
            |> Router.get("/form", () -> {
                let _ = Csrf.token();
                Html.pageWithHead(
                    "Checkout",
                    () -> Csrf.metaTag(),
                    () -> Html.form(() -> {
                        Html.method("post");
                        Html.action("/form");
                        Csrf.hiddenInput();
                        Html.button(() -> Html.text("Pay"))
                    })
                )
            })
            |> Router.post("/form", () -> "submitted")
            |> Router.post("/upload", () -> {
                let form = Req.multipartForm();
                let f = MultipartForm.requireFile("photo", form);
                "uploaded:${UploadedFile.fileName(f)}:${UploadedFile.size(f)}"
            })
            |> Router.withMiddleware(Middleware.csrf(csrfCfg));

        // Webhook route intentionally mounted OUTSIDE CSRF middleware!
        let webhookRoutes = Router.empty()
            |> Router.post("/webhooks/stripe", () -> {
                let sig = Req.requireHeader("X-Signature");
                if (Crypto.verifyHmacHex("whsec_live", Req.bodyBytes(), sig))
                    "webhook-ok"
                else
                    Weft.HttpError.unauthorized("Bad signature")
            });

        let app = Router.empty()
            |> Router.merge(webRoutes)
            |> Router.merge(webhookRoutes)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.session(sessionCfg);

        run {
            // 1. GET /form generates CSRF token in session and renders hidden input + meta tag
            let rGet = TestClient.get("/form", app);
            assertEq(expected = Status.ok(), Response.status(rGet));
            let html = Response.body(rGet);
            assertTrue(String.contains({substr = "name=\"_csrf\""}, html));
            assertTrue(String.contains({substr = "name=\"csrf-token\""}, html));
            let sidCookie = Option.getWithDefault("", extractSessionCookieValue(rGet));

            // Extract token value from `<meta name="csrf-token" content="...">`
            let marker = "name=\"csrf-token\" content=\"";
            let csrfTok = match String.indexOfLeft({substr = marker}, html) {
                case Some(idx) =>
                    let rest = String.sliceRight({start = idx + String.length(marker)}, html);
                    match String.indexOfLeft({substr = "\""}, rest) {
                        case Some(endIdx) => String.sliceLeft({end = endIdx}, rest)
                        case None         => ""
                    }
                case None => ""
            };
            assertTrue(String.length(csrfTok) > 20);

            // 2. POST without token -> 403 Forbidden
            let rMissing = TestClient.send(
                Request.post("/form") |> Request.withCookie("weft_session", sidCookie),
                app
            );
            assertEq(expected = Status.forbidden(), Response.status(rMissing));

            // 3. POST with wrong token -> 403 Forbidden
            let rWrong = TestClient.send(
                Request.post("/form")
                    |> Request.withCookie("weft_session", sidCookie)
                    |> Request.withHeader("X-CSRF-Token", "wrong-token"),
                app
            );
            assertEq(expected = Status.forbidden(), Response.status(rWrong));

            // 4. POST with valid URL-encoded `_csrf` form field -> 200 OK
            let rFormOk = TestClient.send(
                Request.post("/form")
                    |> Request.withCookie("weft_session", sidCookie)
                    |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
                    |> Request.withBody(Weft.Url.encodeQuery(("_csrf", csrfTok) :: Nil)),
                app
            );
            assertEq(expected = Status.ok(), Response.status(rFormOk));
            assertEq(expected = "submitted", Response.body(rFormOk));

            // 5. POST with valid `X-CSRF-Token` header (HTMX/JS) -> 200 OK
            let rHeaderOk = TestClient.send(
                Request.post("/form")
                    |> Request.withCookie("weft_session", sidCookie)
                    |> Request.withHeader("X-CSRF-Token", csrfTok),
                app
            );
            assertEq(expected = Status.ok(), Response.status(rHeaderOk));

            // 6. Multipart upload with `_csrf` field + binary file -> 200 OK
            let boundary = "CsrfUploadBoundary";
            let img = UploadedFile.make("photo", "shoe.png", "image/png", Vector#{-119i8, 80i8, 78i8, 71i8});
            let mpBody = Weft.Multipart.encode(boundary, ("_csrf", csrfTok) :: Nil, img :: Nil);
            let rUploadOk = TestClient.send(
                Request.post("/upload")
                    |> Request.withCookie("weft_session", sidCookie)
                    |> Request.withHeader("Content-Type", "multipart/form-data; boundary=${boundary}")
                    |> Request.withBytes(mpBody),
                app
            );
            assertEq(expected = Status.ok(), Response.status(rUploadOk));
            assertEq(expected = "uploaded:shoe.png:4", Response.body(rUploadOk));

            // 7. Webhook outside CSRF sub-router succeeds via HMAC signature without session/CSRF
            let whBody = "{\"id\":\"evt_1\"}";
            let whSig = Crypto.hmacSha256Hex("whsec_live", whBody);
            let rWh = TestClient.send(
                Request.post("/webhooks/stripe")
                    |> Request.withHeader("X-Signature", whSig)
                    |> Request.withBody(whBody),
                app
            );
            assertEq(expected = Status.ok(), Response.status(rWh));
            assertEq(expected = "webhook-ok", Response.body(rWh))
        } with SessionStore.runPure
          with Random.runDeterministic(555i64)
          with TestEffects.runFixedClock(90000i64)
    }

}
