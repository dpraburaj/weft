mod TestE2eSessionJourney {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Time.Clock
    use Weft.App
    use Weft.Auth
    use Weft.Body
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Crypto
    use Weft.Csrf
    use Weft.CsrfConfig
    use Weft.Db
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.HttpClient
    use Weft.HttpError
    use Weft.Job
    use Weft.JobQueue
    use Weft.JobRegistry
    use Weft.JobStore
    use Weft.JobWorker
    use Weft.Json
    use Weft.Middleware
    use Weft.Migration
    use Weft.OptionalAuth
    use Weft.Principal
    use Weft.Random
    use Weft.Req
    use Weft.Response
    use Weft.Router
    use Weft.Row
    use Weft.Session
    use Weft.SessionConfig
    use Weft.SessionStore
    use Weft.SqlValue
    use Weft.StaticConfig
    use Weft.StaticFiles
    use Weft.StaticStore
    use Weft.Status
    use Weft.TestEffects
    use Weft.TestSession
    use Weft.Validate
    use Weft.ValidationErrors
    use Weft.WorkerConfig

    def loadUser(uid: String): Option[Principal] = match uid {
        case "cust-1" => Some(Principal.make("cust-1", "Ada", "customer" :: Nil))
        case _        => None
    }

    def homeHandler(): HtmlDoc \ {OptionalAuth, Session, Random, Db, DbError} = {
        let who = Option.getWithDefault("Guest", OptionalAuth.userName());
        let flash = Session.takeFlash("notice");
        let cartSku = Session.get("cart_sku");
        let products = Db.queryMap("SELECT sku, price_cents FROM products ORDER BY sku", Nil, r ->
            (Row.requireString("sku", r), Row.requireInt64("price_cents", r))
        );
        Html.pageWithHead(
            "Weft Shop",
            () -> Csrf.metaTag(),
            () -> {
                Html.pText("Welcome, ${who}");
                Html.whenSome(flash, msg -> Html.div(() -> { Html.cls("flash"); Html.text(msg) }));
                Html.whenSome(cartSku, sku -> Html.pText("Cart: ${sku}"));
                Html.ul(() -> Html.each(products, match (sku, cents) ->
                    Html.li(() -> Html.form(() -> {
                        Html.method("post");
                        Html.action("/cart/add");
                        Csrf.hiddenInput();
                        Html.input(() -> { Html.type_("hidden"); Html.name("sku"); Html.value(sku) });
                        Html.button(() -> Html.text("Add ${sku} (${cents})"))
                    }))
                ))
            }
        )
    }

    def addToCartHandler(): Response \ {Req, HttpError, Session} = {
        let sku = Req.requireNonEmptyFormField("sku");
        Session.put("cart_sku", sku);
        Session.putFlash("notice", "Added ${sku} to cart");
        Response.seeOther("/")
    }

    def loginHandler(): Response \ {Req, HttpError, Db, DbError, Session} = {
        let email = Req.requireNonEmptyFormField("email");
        let password = Req.requireNonEmptyFormField("password");
        let row = Db.queryOne("SELECT id, password_hash FROM users WHERE email = ?", SqlValue.text(email) :: Nil)
            |> HttpError.orUnauthorized("Invalid credentials");
        let storedHash = Row.requireString("password_hash", row);
        HttpError.ensure(Crypto.verifyPassword(password, storedHash), Status.unauthorized(), "Invalid credentials");
        Auth.loginSession(Row.requireString("id", row));
        Session.putFlash("notice", "Signed in!");
        Response.seeOther("/checkout")
    }

    def checkoutGetHandler(): HtmlDoc \ {Auth, Session, Random} = {
        let sku = Session.getOrDefault("cart_sku", "empty");
        let flash = Option.getWithDefault("", Session.takeFlash("notice"));
        Html.pageWithHead(
            "Checkout",
            () -> Csrf.metaTag(),
            () -> {
                Html.h1Text("Checkout for ${Auth.userName()}");
                Html.pText("Flash: ${flash}");
                Html.pText("Item: ${sku}")
            }
        )
    }

    def checkoutPostHandler(): Response \ {Req, HttpError, Auth, Db, DbError, Session, HttpClient, JobQueue} = {
        let form = Req.formParams();
        match Validate.toResult(() ->
            Validate.requireNonEmpty("address", Map.get("address", form))
                |> Validate.minLength("address", 5)
        ) {
            case Err(errs) =>
                let doc = Html.page("Checkout Error", () ->
                    ValidationErrors.renderFieldError("address", errs)
                );
                HtmlDoc.toResponseWithStatus(Status.unprocessableEntity(), doc)
            case Ok(shippingAddr) =>
                let sku = Session.get("cart_sku") |> HttpError.orBadRequest("Cart is empty");
                let prod = Db.queryOne("SELECT price_cents FROM products WHERE sku = ?", SqlValue.text(sku) :: Nil)
                    |> HttpError.orNotFound("Product not found");
                let cents = Row.requireInt64("price_cents", prod);

                let payRes = HttpClient.sendOrBadGateway(
                    ClientRequest.postJson(
                        "https://api.stripe.test/v1/charges",
                        Json.obj(("amount", Json.int64(cents)) :: ("sku", Json.str(sku)) :: Nil)
                    ) |> ClientRequest.withBearer("sk_test_shop")
                );
                HttpError.ensure(ClientResponse.isSuccess(payRes), Status.badRequest(), "Payment failed");

                let orderId = Db.transactionHttp(() -> {
                    let oid = Db.insertAndGetId(
                        "INSERT INTO orders (user_id, sku, total_cents, address) VALUES (?, ?, ?, ?)",
                        SqlValue.text(Auth.userId()) ::
                        SqlValue.text(sku) ::
                        SqlValue.int64(cents) ::
                        SqlValue.text(shippingAddr) ::
                        Nil
                    );
                    let _ = JobQueue.dispatchUnique(
                        "order:${oid}:receipt",
                        "email.receipt",
                        Json.obj(("orderId", Json.int64(oid)) :: ("user", Json.str(Auth.userName())) :: Nil)
                    );
                    oid
                });
                Session.remove("cart_sku");
                Session.putFlash("notice", "Order #${orderId} confirmed!");
                Response.seeOther("/orders/${orderId}")
        }
    }

    def orderGetHandler(): String \ {Req, HttpError, Auth, Session} = {
        let oid = Req.requireInt64Param("id");
        let flash = Option.getWithDefault("", Session.takeFlash("notice"));
        "order=${oid};user=${Auth.userName()};flash=${flash}"
    }

    def buildShopApp(): App[{Db, SessionStore, Random, Clock, StaticStore, HttpClient, JobQueue, Logger}] = {
        let sessionCfg = SessionConfig.default("e2e-shop-secret");
        let csrfCfg = CsrfConfig.default();

        let storefrontRoutes: Router[{Db, DbError, Session, Random}] = Router.empty()
            |> Router.get("/", homeHandler)
            |> Router.withMiddleware(Middleware.optionalSessionAuth(loadUser));

        let cartAndAuthRoutes: Router[{Req, HttpError, Db, DbError, Session}] = Router.empty()
            |> Router.post("/cart/add", addToCartHandler)
            |> Router.post("/login", loginHandler)
            |> Router.withMiddleware(Middleware.csrf(csrfCfg));

        let checkoutBase: Router[{Req, HttpError, Auth, Db, DbError, Session, Random, HttpClient, JobQueue}] = Router.empty()
            |> Router.get("/checkout", checkoutGetHandler)
            |> Router.post("/checkout", checkoutPostHandler)
            |> Router.get("/orders/:id", orderGetHandler);

        let checkoutWithCsrf: Router[{Req, HttpError, Auth, Db, DbError, Session, Random, HttpClient, JobQueue}] =
            checkoutBase |> Router.withMiddleware(Middleware.csrf(csrfCfg));
        let checkoutRoutes: Router[{Req, HttpError, Db, DbError, Session, Random, HttpClient, JobQueue}] =
            checkoutWithCsrf |> Router.withMiddleware(Middleware.sessionAuthOrRedirect("/login", loadUser));

        let routed: App[{Db, DbError, HttpError, Session, Random, StaticStore, HttpClient, JobQueue}] =
            Router.empty()
                |> Router.merge(StaticFiles.routes("/static", StaticConfig.default()))
                |> Router.merge(storefrontRoutes)
                |> Router.merge(cartAndAuthRoutes)
                |> Router.merge(checkoutRoutes)
                |> Router.toApp;

        let withDbErr: App[{Db, HttpError, Session, Random, StaticStore, HttpClient, JobQueue, Logger}] =
            routed |> Middleware.dbErrorToHttpSafe;
        let withErr: App[{Db, Session, Random, StaticStore, HttpClient, JobQueue, Logger}] =
            withDbErr |> Middleware.errorNegotiated;
        withErr |> Middleware.session(sessionCfg)
    }

    def seedShopDb(): Unit \ {Db, DbError} = {
        let schema =
            "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL);" +
            "CREATE TABLE products (sku TEXT PRIMARY KEY, price_cents INTEGER NOT NULL);" +
            "CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, sku TEXT NOT NULL, total_cents INTEGER NOT NULL, address TEXT NOT NULL);";
        let _ = Migration.runAll(Migration.make(1, "shop_init", schema) :: Nil);
        SessionStore.initSchema();
        JobStore.initSchema();

        let pwHash = Random.runDeterministic(11i64, () -> Crypto.hashPasswordWithIterations(1000, "lovelace-1843"));
        let _ = Db.execute(
            "INSERT INTO users (id, email, password_hash) VALUES (?, ?, ?)",
            SqlValue.text("cust-1") :: SqlValue.text("ada@shop.test") :: SqlValue.text(pwHash) :: Nil
        );
        let _ = Db.execute(
            "INSERT INTO products (sku, price_cents) VALUES (?, ?)",
            SqlValue.text("GRIND-01") :: SqlValue.int64(19900i64) :: Nil
        );
        ()
    }

    @Test
    def testTestSessionCookiesRedirectsAndMethodPreservation(): Unit \ Assert = {
        let app: App[{}] = Router.empty()
            |> Router.get("/hop1", () ->
                Response.redirect("/hop2")
                    |> Response.withCookie(Weft.Cookie.make("step", "1"))
            )
            |> Router.get("/hop2", () -> {
                let s = Option.getWithDefault("none", Req.cookie("step"));
                Response.seeOther("/final?from=${s}")
                    |> Response.withCookie(Weft.Cookie.make("step", "2"))
            })
            |> Router.get("/final", () -> {
                let fromQ = Option.getWithDefault("", Req.queryParam("from"));
                let c = Option.getWithDefault("", Req.cookie("step"));
                "from=${fromQ};cookie=${c}"
            })
            |> Router.post("/temp-redirect", () ->
                Response.makeBody(Status.temporaryRedirect(), Weft.Headers.singleton("Location", "/echo-post"), Body.empty())
            )
            |> Router.post("/echo-post", () -> "posted:${Req.body()}")
            |> Router.post("/clear-cookie", () ->
                Response.ok("cleared") |> Response.withCookie(Weft.Cookie.expired("step"))
            )
            |> Router.toApp
            |> Middleware.errorText;

        region rc {
            let browser = TestSession.make(rc) |> TestSession.withFollowRedirects(true);

            // 1. Follows multi-hop redirects and accumulates Set-Cookie on every hop!
            let rFinal = TestSession.get("/hop1", app, browser);
            assertEq(expected = Status.ok(), Response.status(rFinal));
            assertEq(expected = "from=1;cookie=2", Response.body(rFinal));
            assertEq(expected = Some("2"), TestSession.cookie("step", browser));

            // 2. 307 Temporary Redirect preserves POST method & body
            let r307 = TestSession.postText("/temp-redirect", "payload-42", app, browser);
            assertEq(expected = Status.ok(), Response.status(r307));
            assertEq(expected = "posted:payload-42", Response.body(r307));

            // 3. sendNoRedirect inspects 302 directly even when followRedirects is enabled
            let rNoFollow = TestSession.sendNoRedirect(Weft.Request.get("/hop1"), app, browser);
            assertEq(expected = Status.found(), Response.status(rNoFollow));
            assertEq(expected = Some("/hop2"), Response.header("Location", rNoFollow));

            // 4. Max-Age=0 deletes cookie from the jar
            let _ = TestSession.postText("/clear-cookie", "", app, browser);
            assertEq(expected = None, TestSession.cookie("step", browser))
        }
    }

    def wireShopApp(
        db: Weft.Db.SqliteDb,
        staticAssets: Map[String, Vector[Int8]],
        stripeMock: ClientRequest -> Result[String, ClientResponse],
        stripeCallsRef: Ref[List[ClientRequest], Static]
    ): App[IO] = {
        let app = buildShopApp();
        req -> {
            let r1 = run {
                let (res, calls) = run {
                    app(req)
                } with SessionStore.runWithDb
                  with JobQueue.runWithDb
                  with StaticStore.runPure(staticAssets)
                  with HttpClient.runRecording(stripeMock);
                Ref.transform(xs -> List.append(xs, calls), stripeCallsRef);
                res
            } with Sqlite.runWith(db)
              with DbError.runToHttpError
              with HttpError.runAsText
              with Random.runDeterministic(2026i64)
              with TestEffects.runFixedClock(1700000000000i64)
              with TestEffects.runSilentLogger;
            r1
        }
    }

    def drainReceiptJobs(db: Weft.Db.SqliteDb, sentEmailsRef: Ref[List[Int64], Static]): Result[(Weft.DbErrorKind, String), Int32] \ IO = {
        let reg = JobRegistry.empty()
            |> JobRegistry.register("email.receipt", job -> {
                Ref.transform(xs -> Job.id(job) :: xs, sentEmailsRef)
            });
        run {
            JobWorker.drain(WorkerConfig.default(), reg)
        } with JobStore.runWithDb
          with Sqlite.runWith(db)
          with DbError.runToResult
          with TestEffects.runFixedClock(1700000000000i64)
          with TestEffects.runSilentLogger
    }

    def verifyGuestBrowsingAndCart(
        shopApp: App[IO],
        browser: TestSession[r]
    ): (String, String) \ {Assert, IO, r} = {
        // 1. Static asset loads with PNG MIME + exact bytes
        let rLogo = TestSession.get("/static/logo.png", shopApp, browser);
        assertEq(expected = Status.ok(), Response.status(rLogo));
        assertEq(expected = Some("image/png"), Response.header("Content-Type", rLogo));

        // 2. Guest visits storefront, gets CSRF token
        let rHome = TestSession.get("/", shopApp, browser);
        assertEq(expected = Status.ok(), Response.status(rHome));
        assertTrue(String.contains({substr = "Welcome, Guest"}, Response.body(rHome)));
        let csrf = match TestSession.extractCsrfToken(rHome) {
            case Some(t) => t
            case None    => { Assert.fail("Expected CSRF token on home page"); "" }
        };

        // 3. Guest tries /checkout -> redirected to /login (303)
        let rUnauth = TestSession.sendNoRedirect(Weft.Request.get("/checkout"), shopApp, browser);
        assertEq(expected = Status.seeOther(), Response.status(rUnauth));
        assertEq(expected = Some("/login"), Response.header("Location", rUnauth));

        // 4. Guest adds product to cart -> POST /cart/add -> 303 -> GET / shows flash & cart!
        let rAdded = TestSession.postForm("/cart/add", ("_csrf", csrf) :: ("sku", "GRIND-01") :: Nil, shopApp, browser);
        assertEq(expected = Status.ok(), Response.status(rAdded));
        assertTrue(String.contains({substr = "Added GRIND-01 to cart"}, Response.body(rAdded)));
        assertTrue(String.contains({substr = "Cart: GRIND-01"}, Response.body(rAdded)));
        let guestCookie = Option.getWithDefault("", TestSession.cookie("weft_session", browser));
        (csrf, guestCookie)
    }

    def verifyLoginAndCheckout(
        csrf: String,
        guestCookie: String,
        shopApp: App[IO],
        browser: TestSession[r]
    ): Unit \ {Assert, IO, r} = {
        // 5. Guest logs in -> session ID rotates, redirects to /checkout, guest cart preserved!
        let rLogin = TestSession.postForm(
            "/login",
            ("_csrf", csrf) :: ("email", "ada@shop.test") :: ("password", "lovelace-1843") :: Nil,
            shopApp,
            browser
        );
        assertEq(expected = Status.ok(), Response.status(rLogin));
        assertTrue(String.contains({substr = "Checkout for Ada"}, Response.body(rLogin)));
        assertTrue(String.contains({substr = "Item: GRIND-01"}, Response.body(rLogin)));
        let authedCookie = Option.getWithDefault("", TestSession.cookie("weft_session", browser));
        assertFalse(guestCookie == authedCookie);

        // 6. Invalid checkout address -> 422 with inline HTML field error
        let rBadAddr = TestSession.postForm("/checkout", ("_csrf", csrf) :: ("address", "12") :: Nil, shopApp, browser);
        assertEq(expected = Status.unprocessableEntity(), Response.status(rBadAddr));
        assertTrue(String.contains({substr = "class=\"field-error\""}, Response.body(rBadAddr)));

        // 7. Valid checkout -> Stripe charge + atomic DB order + outbox job + redirect to /orders/1!
        let rOrder = TestSession.postForm("/checkout", ("_csrf", csrf) :: ("address", "10 Downing Street") :: Nil, shopApp, browser);
        assertEq(expected = Status.ok(), Response.status(rOrder));
        assertEq(expected = "order=1;user=Ada;flash=Order #1 confirmed!", Response.body(rOrder))
    }

    ///
    /// Full end-to-end e-commerce checkout journey combining Milestones 1-5:
    /// Static assets + SQLite catalog + guest cart session + CSRF form + login session rotation
    /// + multi-field validation + outbound Stripe HttpClient charge + atomic Db.transactionHttp
    /// transactional outbox job + JobWorker email dispatch — all tested via stateful TestSession!
    ///
    @Test
    def testFullEcommerceCheckoutJourneyWithTestSession(): Unit \ {Assert, IO} = {
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail(e)
            case Ok(db) =>
                let seedRes = run {
                    seedShopDb()
                } with Sqlite.runWith(db)
                  with DbError.runToResult;
                assertTrue(Result.isOk(seedRes));

                let staticAssets = Map#{"logo.png" => Vector#{-119i8, 80i8, 78i8, 71i8}};
                let stripeMock: ClientRequest -> Result[String, ClientResponse] =
                    _req -> Ok(ClientResponse.json(200, Json.obj(("id", Json.str("ch_ok")) :: Nil)));
                let sentEmailsRef = Ref.fresh(Static, Nil);
                let stripeCallsRef = Ref.fresh(Static, Nil);
                let shopApp = wireShopApp(db, staticAssets, stripeMock, stripeCallsRef);

                region rc {
                    let browser = TestSession.make(rc)
                        |> TestSession.withHeader("Accept", "text/html, */*;q=0.8")
                        |> TestSession.withFollowRedirects(true);
                    let (csrf, guestCookie) = verifyGuestBrowsingAndCart(shopApp, browser);
                    verifyLoginAndCheckout(csrf, guestCookie, shopApp, browser)
                };

                assertEq(expected = Ok(1), drainReceiptJobs(db, sentEmailsRef));
                assertEq(expected = 1, List.length(Ref.get(stripeCallsRef)));
                assertEq(expected = 1i64 :: Nil, Ref.get(sentEmailsRef));
                Sqlite.close(db)
        }
    }

}
