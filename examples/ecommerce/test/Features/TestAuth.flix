mod Features.TestAuth {
    use Assert.assertEq
    use Assert.assertNeq
    use Assert.assertTrue
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestSession
    use weft::Weft.Url

    @Test
    pub def testRegistrationValidationAndGuestCartMerge(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);
            let homeRes = TestSession.get("/", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(homeRes);

            // Guest adds 2 units of product #1 before registering
            let addRes = TestHarness.htmxPostForm(
                "/cart/items",
                csrf,
                ("product_id", "1") :: ("quantity", "2") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(addRes)));

            // 1. Invalid registration returns 422 with inline field errors
            let regPage = TestSession.get("/register", app, browser);
            let regCsrf = TestHarness.extractCsrfOrFail(regPage);
            let badReg = TestSession.postForm(
                "/register",
                ("_csrf", regCsrf) :: ("name", "A") :: ("email", "not-an-email") :: ("password", "123") :: Nil,
                app,
                browser
            );
            assertEq(expected = 422, Status.code(Response.status(badReg)));
            assertTrue(String.contains({substr = "field-error"}, Response.body(badReg)));

            // 2. Duplicate seeded email rejected with 422
            let dupReg = TestSession.postForm(
                "/register",
                ("_csrf", regCsrf) :: ("name", "Ada Clone") :: ("email", "ada@example.com") :: ("password", "secret123") :: Nil,
                app,
                browser
            );
            assertEq(expected = 422, Status.code(Response.status(dupReg)));
            assertTrue(String.contains({substr = "already exists"}, Response.body(dupReg)));

            // 3. Valid registration succeeds (303 -> /), logs user in, and merges guest cart
            let okReg = TestSession.postForm(
                "/register",
                ("_csrf", regCsrf) :: ("name", "Grace Hopper") :: ("email", "grace@example.com") :: ("password", "compiler42") :: Nil,
                app,
                browser
            );
            assertEq(expected = 303, Status.code(Response.status(okReg)));

            let cartRes = TestSession.get("/cart", app, browser);
            assertEq(expected = 200, Status.code(Response.status(cartRes)));
            let cartBody = Response.body(cartRes);
            assertTrue(String.contains({substr = "Hi, Grace Hopper"}, cartBody));
            assertTrue(String.contains({substr = "Ethiopia Yirgacheffe Washed"}, cartBody));
            assertTrue(String.contains({substr = "$44.00"}, cartBody))
        })

    @Test
    pub def testLoginSessionRotationGuestCartMergeAndLogout(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);
            let homeRes = TestSession.get("/", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(homeRes);

            // Guest adds product #1
            let _ = TestHarness.htmxPostForm(
                "/cart/items",
                csrf,
                ("product_id", "1") :: ("quantity", "1") :: Nil,
                app,
                browser
            );
            let preLoginCookie = TestSession.cookie("weft_shop_session", browser);
            assertTrue(Option.nonEmpty(preLoginCookie));

            // 1. Bad password returns 422
            let badLogin = TestHarness.loginAs("ada@example.com", "wrong-password", app, browser);
            assertEq(expected = 422, Status.code(Response.status(badLogin)));
            assertTrue(String.contains({substr = "Invalid email or password"}, Response.body(badLogin)));

            // 2. Valid login rotates session cookie (anti-fixation) and merges guest cart
            let okLogin = TestHarness.loginAs("ada@example.com", "coffee123", app, browser);
            assertEq(expected = 303, Status.code(Response.status(okLogin)));
            let postLoginCookie = TestSession.cookie("weft_shop_session", browser);
            assertTrue(Option.nonEmpty(postLoginCookie));
            assertNeq(unexpected = preLoginCookie, postLoginCookie);

            let cartRes = TestSession.get("/cart", app, browser);
            assertTrue(String.contains({substr = "Hi, Ada Lovelace"}, Response.body(cartRes)));
            assertTrue(String.contains({substr = "Ethiopia Yirgacheffe Washed"}, Response.body(cartRes)));

            // 3. Logout destroys session and returns to guest state
            let logoutCsrf = TestHarness.extractCsrfOrFail(cartRes);
            let logoutRes = TestSession.postForm("/logout", ("_csrf", logoutCsrf) :: Nil, app, browser);
            assertEq(expected = 303, Status.code(Response.status(logoutRes)));

            let afterLogout = TestSession.get("/checkout", app, browser);
            assertEq(expected = 303, Status.code(Response.status(afterLogout)));
            assertEq(expected = Some("/login"), Response.header("Location", afterLogout))
        })

    @Test
    pub def testLoginRateLimitedAfterTooManyAttempts(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);
            let loginGet = TestSession.get("/login", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(loginGet);

            // 10 failed login attempts from the same IP hit the per-minute auth limit
            def attemptFailed(n: Int32): Unit \ {IO, Assert, rc} = {
                if (n <= 0) ()
                else {
                    let req = Request.post("/login")
                        |> Request.withHeader("X-Forwarded-For", "203.0.113.42")
                        |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
                        |> Request.withBody(Url.encodeQuery(("_csrf", csrf) :: ("email", "ada@example.com") :: ("password", "wrong") :: Nil));
                    let r = TestSession.send(req, app, browser);
                    assertEq(expected = 422, Status.code(Response.status(r)));
                    attemptFailed(n - 1)
                }
            };
            attemptFailed(10);

            // 11th attempt is throttled with 429 Too Many Requests + Retry-After
            let blockedReq = Request.post("/login")
                |> Request.withHeader("X-Forwarded-For", "203.0.113.42")
                |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
                |> Request.withBody(Url.encodeQuery(("_csrf", csrf) :: ("email", "ada@example.com") :: ("password", "wrong") :: Nil));
            let blockedRes = TestSession.send(blockedReq, app, browser);
            assertEq(expected = 429, Status.code(Response.status(blockedRes)));
            assertTrue(Option.nonEmpty(Response.header("Retry-After", blockedRes)))
        })

}
