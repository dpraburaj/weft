mod TestValidationAndNegotiation {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Logger.Severity
    use Weft.Accept
    use Weft.App
    use Weft.Db
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.HttpError
    use Weft.Json
    use Weft.Middleware
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Row
    use Weft.SqlValue
    use Weft.Status
    use Weft.TestClient
    use Weft.TestEffects
    use Weft.Validate
    use Weft.ValidationErrors
    use Weft.WithStatus

    @Test
    def testAccumulatingFormValidationAndSsrHtmlFieldErrors(): Unit \ Assert = {
        let badForm = Map#{
            "email"       => "not-an-email",
            "name"        => "A",
            "price_cents" => "-50",
            "shipping"    => "teleport"
        };

        let res = Validate.toResult(() -> {
            let email = Validate.requireEmail("email", Map.get("email", badForm));
            let name = Validate.requireNonEmpty("name", Map.get("name", badForm))
                |> Validate.minLength("name", 2)
                |> Validate.maxLength("name", 80);
            let cents = Validate.requireInt64("price_cents", Map.get("price_cents", badForm))
                |> Validate.positiveInt64("price_cents");
            let shipping = Validate.requireNonEmpty("shipping", Map.get("shipping", badForm))
                |> Validate.oneOf("shipping", "standard" :: "express" :: Nil);
            (email, name, cents, shipping)
        });

        match res {
            case Ok(_) => Assert.fail("Expected validation errors for all 4 invalid fields")
            case Err(errs) =>
                assertEq(expected = 4, ValidationErrors.count(errs));
                assertTrue(ValidationErrors.hasField("email", errs));
                assertTrue(ValidationErrors.hasField("name", errs));
                assertTrue(ValidationErrors.hasField("price_cents", errs));
                assertTrue(ValidationErrors.hasField("shipping", errs));

                // SSR HTML helper renders inline field error
                let html = Html.renderString(() -> {
                    ValidationErrors.renderFieldError("email", errs);
                    ValidationErrors.renderFieldError("missing_field", errs)
                });
                assertTrue(String.contains({substr = "class=\"field-error\""}, html));
                assertTrue(String.contains({substr = "Must be a valid email address"}, html))
        };

        // Valid form succeeds
        let goodForm = Map#{
            "email"       => "ada@shop.test",
            "name"        => "Ada Lovelace",
            "price_cents" => "4999",
            "shipping"    => "express"
        };
        let okRes = Validate.toResult(() -> {
            let email = Validate.requireEmail("email", Map.get("email", goodForm));
            let name = Validate.requireNonEmpty("name", Map.get("name", goodForm)) |> Validate.minLength("name", 2);
            let cents = Validate.requireInt64("price_cents", Map.get("price_cents", goodForm)) |> Validate.positiveInt64("price_cents");
            let shipping = Validate.requireNonEmpty("shipping", Map.get("shipping", goodForm))
                |> Validate.oneOf("shipping", "standard" :: "express" :: Nil);
            (email, name, cents, shipping)
        });
        assertEq(expected = Ok(("ada@shop.test", "Ada Lovelace", 4999i64, "express")), okRes)
    }

    @Test
    def testAccumulatingJsonValidationAnd422Middleware(): Unit \ Assert = {
        let app = Router.empty()
            |> Router.post("/api/products", () -> {
                let body = Req.jsonBody();
                let (name, sku, priceCents) = Validate.orFail(() -> {
                    let n = Validate.jsonNonEmptyString("name", body) |> Validate.minLength("name", 3);
                    let s = Validate.jsonNonEmptyString("sku", body);
                    let p = Validate.jsonInt64("price_cents", body) |> Validate.positiveInt64("price_cents");
                    (n, s, p)
                });
                WithStatus.WithStatus(
                    Status.created(),
                    Json.obj(
                        ("name", Json.str(name)) ::
                        ("sku", Json.str(sku)) ::
                        ("price_cents", Json.int64(priceCents)) ::
                        Nil
                    )
                )
            })
            |> Router.post("/api/simple", () -> {
                let email = Validate.orHttpError(() ->
                    Validate.requireEmail("email", Req.optionalFormField("email"))
                );
                email
            })
            |> Router.toApp
            |> Middleware.validationErrorJson
            |> Middleware.errorJson;

        // Multiple invalid fields returned together in 422 JSON
        let badPayload = Json.obj(
            ("name", Json.str("Hi")) ::
            ("price_cents", Json.int64(0i64)) ::
            Nil
        );
        let r422 = TestClient.postJson("/api/products", badPayload, app);
        assertEq(expected = Status.unprocessableEntity(), Response.status(r422));
        match Json.parse(Response.body(r422)) {
            case Err(msg) => Assert.fail("Expected valid JSON error body: ${msg}")
            case Ok(j) =>
                assertEq(expected = Some(422), Option.flatMap(Json.asInt, Json.getField("status", j)));
                let errsObj = Option.flatMap(Json.asObject, Json.getField("errors", j));
                assertTrue(Option.nonEmpty(Option.flatMap(Map.get("name"), errsObj)));
                assertTrue(Option.nonEmpty(Option.flatMap(Map.get("sku"), errsObj)));
                assertTrue(Option.nonEmpty(Option.flatMap(Map.get("price_cents"), errsObj)))
        };

        // Valid payload returns 201 Created
        let goodPayload = Json.obj(
            ("name", Json.str("Espresso Grinder")) ::
            ("sku", Json.str("GRIND-01")) ::
            ("price_cents", Json.int64(19900i64)) ::
            Nil
        );
        let r201 = TestClient.postJson("/api/products", goodPayload, app);
        assertEq(expected = Status.created(), Response.status(r201));

        // orHttpError maps directly into 422 HttpError
        let rSimple422 = TestClient.postForm("/api/simple", ("email", "bad") :: Nil, app);
        assertEq(expected = Status.unprocessableEntity(), Response.status(rSimple422));
        assertTrue(String.contains({substr = "email"}, Response.body(rSimple422)))
    }

    @Test
    def testExpandedJsonReqAndSqliteBlobExtractors(): Unit \ {Assert, IO} = {
        // Control char escaping in JSON encoder
        let encodedCtrl = Json.encode(Json.str("a\u0007b"));
        assertEq(expected = "\"a\\u0007b\"", encodedCtrl);
        assertEq(expected = Ok(Json.str("a\u0007b")), Json.parse(encodedCtrl));

        // Expanded JSON extractors
        let sample = Json.obj(
            ("big_id", Json.int64(9000000000i64)) ::
            ("weight", Json.float(2.75f64)) ::
            ("items",  Json.arr(Json.int(1) :: Json.int(2) :: Nil)) ::
            ("meta",   Json.obj(("color", Json.str("red")) :: Nil)) ::
            ("opt_i",  Json.int(7)) ::
            ("opt_n",  Json.nullValue()) ::
            Nil
        );
        let extracted = HttpError.runAsText(() -> {
            let bigId = Json.requireInt64("big_id", sample);
            let w = Json.requireFloat("weight", sample);
            let items = Json.requireArray("items", sample);
            let meta = Json.requireObject("meta", sample);
            let optI = Json.optionalInt("opt_i", sample);
            let optN = Json.optionalInt64("opt_n", sample);
            let optMissing = Json.optionalFloat("missing", sample);
            assertEq(expected = 9000000000i64, bigId);
            assertEq(expected = 2.75f64, w);
            assertEq(expected = 2, List.length(items));
            assertTrue(Map.memberOf("color", meta));
            assertEq(expected = Some(7), optI);
            assertEq(expected = None, optN);
            assertEq(expected = None, optMissing);
            Response.ok("ok")
        });
        assertEq(expected = Status.ok(), Response.status(extracted));

        // Expanded Req Int64 & optional form extractors
        let reqApp = Router.empty()
            |> Router.post("/calc", () -> {
                let minQ = Req.optionalInt64Query("min");
                let price = Req.requireInt64FormField("price_cents");
                let discount = Req.optionalIntFormField("discount");
                "${minQ}:${price}:${discount}"
            })
            |> Router.toApp
            |> Middleware.errorText;

        let rCalc = TestClient.postForm("/calc?min=500", ("price_cents", "123456789012") :: ("discount", "") :: Nil, reqApp);
        assertEq(expected = Status.ok(), Response.status(rCalc));
        assertEq(expected = "Some(500):123456789012:None", Response.body(rCalc));

        // SQLite SqlBlob & Row optional extractors round-trip
        let pngBytes = Vector#{-119i8, 80i8, 78i8, 71i8, 0i8, -1i8};
        let dbRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            let _ = Db.executeSql(
                "CREATE TABLE assets (id INTEGER PRIMARY KEY, data BLOB NOT NULL, thumb BLOB, price_cents INTEGER, rating REAL, active INTEGER)"
            );
            let _ = Db.execute(
                "INSERT INTO assets (id, data, thumb, price_cents, rating, active) VALUES (?, ?, ?, ?, ?, ?)",
                SqlValue.int(1) ::
                SqlValue.blob(pngBytes) ::
                SqlValue.optionalBlob(None) ::
                SqlValue.optionalInt64(Some(9999999999i64)) ::
                SqlValue.optionalFloat(Some(4.5f64)) ::
                SqlValue.optionalBool(Some(true)) ::
                Nil
            );
            match Db.queryOne("SELECT data, thumb, price_cents, rating, active FROM assets WHERE id = 1", Nil) {
                case None => Assert.fail("Expected inserted asset row")
                case Some(row) =>
                    assertEq(expected = pngBytes, Row.requireBlob("data", row));
                    assertEq(expected = None, Row.optionalBlob("thumb", row));
                    assertEq(expected = Some(9999999999i64), Row.optionalInt64("price_cents", row));
                    assertEq(expected = Some(4.5f64), Row.optionalFloat("rating", row));
                    assertEq(expected = Some(true), Row.optionalBool("active", row))
            }
        }));
        match dbRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("SQLite Blob/optional extractor test failed")
        }
    }

    @Test
    def testAcceptHeaderParsingAndContentNegotiation(): Unit \ Assert = {
        let browserAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
        assertEq(
            expected = Some("text/html"),
            Accept.negotiate("application/json" :: "text/html" :: Nil, Some(browserAccept))
        );
        assertEq(
            expected = Some("application/json"),
            Accept.negotiate("text/html" :: "application/json" :: Nil, Some("application/json, text/html;q=0.5"))
        );
        // q=0 excludes a media type
        assertEq(
            expected = Some("text/plain"),
            Accept.negotiate("text/html" :: "text/plain" :: Nil, Some("text/html;q=0, */*;q=0.5"))
        );

        let browserReq = Request.get("/products") |> Request.withHeader("Accept", browserAccept);
        assertTrue(Accept.prefersHtml(browserReq));
        assertFalse(Accept.prefersJson(browserReq));

        let apiReq = Request.get("/products") |> Request.withHeader("Accept", "application/json");
        assertFalse(Accept.prefersHtml(apiReq));
        assertTrue(Accept.prefersJson(apiReq));

        // Curl default `*/*` is NOT treated as HTML-preferring
        let curlReq = Request.get("/products") |> Request.withHeader("Accept", "*/*");
        assertFalse(Accept.prefersHtml(curlReq))
    }

    @Test
    def testNegotiatedRouteScopedErrorsAndSafeDbRedaction(): Unit \ Assert = {
        let apiSub: Router[{}] = Router.empty()
            |> Router.get("/fail", () -> { let _: String = HttpError.badRequest("bad api input"); "" })
            |> Router.withMiddleware(Middleware.routeErrorJson);

        let webSub: Router[{}] = Router.empty()
            |> Router.get("/fail", () -> { let _: String = HttpError.badRequest("bad web input"); "" })
            |> Router.withMiddleware(Middleware.routeErrorHtml);

        let routed: App[{DbError, Abort, HttpError}] = Router.empty()
            |> Router.scope("/api", apiSub)
            |> Router.scope("/web", webSub)
            |> Router.get("/db-dup", () -> {
                let _: String = DbError.constraintViolation("UNIQUE constraint failed: users.email");
                ""
            })
            |> Router.get("/abort", () -> {
                Abort.abort(RichString.fromString("secret internal panic"));
                "never"
            })
            |> Router.toApp;

        let withDb: App[{Abort, HttpError, Logger}] = routed |> Middleware.dbErrorToHttpSafe;
        let withErr: App[{Abort, Logger}] = withDb |> Middleware.errorNegotiated;
        let app: App[Logger] = withErr |> Middleware.recoverAbortNegotiated;

        let (_, logs) = TestEffects.runCollectingLogger(() -> {
            // 1. Route-scoped JSON vs HTML errors regardless of Accept header
            let rApi = TestClient.send(Request.get("/api/fail") |> Request.withHeader("Accept", "text/html"), app);
            assertEq(expected = Status.badRequest(), Response.status(rApi));
            assertEq(expected = Some("application/json; charset=utf-8"), Response.header("Content-Type", rApi));

            let rWeb = TestClient.send(Request.get("/web/fail") |> Request.withHeader("Accept", "application/json"), app);
            assertEq(expected = Status.badRequest(), Response.status(rWeb));
            assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", rWeb));

            // 2. Negotiated 404 renders HTML for browser, JSON for API client
            let r404Html = TestClient.send(Request.get("/missing") |> Request.withHeader("Accept", "text/html, */*;q=0.8"), app);
            assertEq(expected = Status.notFound(), Response.status(r404Html));
            assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", r404Html));
            assertTrue(String.contains({substr = "<!DOCTYPE html>"}, Response.body(r404Html)));

            let r404Json = TestClient.send(Request.get("/missing") |> Request.withHeader("Accept", "application/json"), app);
            assertEq(expected = Status.notFound(), Response.status(r404Json));
            assertEq(expected = Some("application/json; charset=utf-8"), Response.header("Content-Type", r404Json));

            // 3. Safe DB error redaction: hides table/column from client while logging detail
            let rDb = TestClient.send(Request.get("/db-dup") |> Request.withHeader("Accept", "application/json"), app);
            assertEq(expected = Status.conflict(), Response.status(rDb));
            assertFalse(String.contains({substr = "users.email"}, Response.body(rDb)));
            assertTrue(String.contains({substr = "resource conflict"}, Response.body(rDb)));

            // 4. Negotiated Abort recovery: redacted 500 in HTML or JSON, details logged
            let rAbortHtml = TestClient.send(Request.get("/abort") |> Request.withHeader("Accept", "text/html"), app);
            assertEq(expected = Status.internalServerError(), Response.status(rAbortHtml));
            assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", rAbortHtml));
            assertFalse(String.contains({substr = "secret internal panic"}, Response.body(rAbortHtml)));

            let rAbortJson = TestClient.send(Request.get("/abort") |> Request.withHeader("Accept", "application/json"), app);
            assertEq(expected = Status.internalServerError(), Response.status(rAbortJson));
            assertEq(expected = Some("application/json; charset=utf-8"), Response.header("Content-Type", rAbortJson));
            assertFalse(String.contains({substr = "secret internal panic"}, Response.body(rAbortJson)))
        });

        // Verify internal details were captured in Logger
        assertTrue(List.exists(match (sev, msg) -> sev == Severity.Warn and String.contains({substr = "users.email"}, msg), logs));
        assertTrue(List.exists(match (sev, msg) -> sev == Severity.Fatal and String.contains({substr = "secret internal panic"}, msg), logs))
    }

}
