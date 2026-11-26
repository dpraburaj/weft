mod TestBodyFormsAndMultipart {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Body
    use Weft.Json
    use Weft.Middleware
    use Weft.Multipart
    use Weft.MultipartForm
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Status
    use Weft.TestClient
    use Weft.UploadedFile
    use Weft.Url

    def samplePngBytes(): Vector[Int8] =
        Vector#{-119i8, 80i8, 78i8, 71i8, 13i8, 10i8, 26i8, 10i8, 0i8, -1i8, -2i8, 42i8}

    @Test
    def testBinaryBodyPreservesNonUtf8Bytes(): Unit \ Assert = {
        let png = samplePngBytes();
        let b = Body.bytes(png);
        assertTrue(Body.isBinary(b));
        assertFalse(Body.isEmpty(b));
        assertEq(expected = 12, Body.byteLength(b));
        assertEq(expected = png, Body.asBytes(b));

        // Text and UTF-8 bytes compare equal
        assertEq(expected = Body.text("hello weft"), Body.bytes(Body.utf8Bytes("hello weft")));
        assertEq(expected = Body.empty(), Body.text(""));
        assertEq(expected = Body.empty(), Body.bytes(Vector.empty()));

        // Multi-byte UTF-8 length is byte count, not char count
        assertEq(expected = 4, Body.byteLength(Body.text("€!"))); // € (3 bytes) + ! (1 byte)

        // Round-trip through pure App / TestClient
        let app = Router.empty()
            |> Router.post("/binary", () -> Response.bytes("image/png", Req.bodyBytes()))
            |> Router.toApp
            |> Middleware.errorJson;

        let res = TestClient.postBytes("/binary", "image/png", png, app);
        assertEq(expected = Status.ok(), Response.status(res));
        assertEq(expected = Some("image/png"), Response.header("Content-Type", res));
        assertEq(expected = png, Response.bodyBytes(res));
        assertEq(expected = 12, Response.bodyLength(res))
    }

    @Test
    def testMultiValueQueryAndFormParams(): Unit \ Assert = {
        let parsedAll = Url.parseQueryAll("?size=M&size=L&color=blue&flag&size=XL");
        assertEq(expected = Some("M" :: "L" :: "XL" :: Nil), Map.get("size", parsedAll));
        assertEq(expected = Some("blue" :: Nil), Map.get("color", parsedAll));
        assertEq(expected = Some("" :: Nil), Map.get("flag", parsedAll));

        let app = Router.empty()
            |> Router.get("/products", () -> {
                let sizes = Req.queryParamAll("size");
                let lastSize = Option.getWithDefault("", Req.queryParam("size"));
                let minCents = Req.requireInt64Query("min_cents");
                Json.obj(
                    ("sizes", Json.arr(List.map(Json.str, sizes))) ::
                    ("lastSize", Json.str(lastSize)) ::
                    ("minCents", Json.int64(minCents)) ::
                    Nil
                )
            })
            |> Router.post("/checkout", () -> {
                let email = Req.requireNonEmptyFormField("email");
                let qty = Req.requireIntFormField("qty");
                let addons = Req.formFieldAll("addon");
                Json.obj(
                    ("email", Json.str(email)) ::
                    ("qty", Json.int(qty)) ::
                    ("addons", Json.arr(List.map(Json.str, addons))) ::
                    Nil
                )
            })
            |> Router.toApp
            |> Middleware.errorJson;

        let rQuery = TestClient.get("/products?size=S&size=M&min_cents=1999", app);
        assertEq(expected = Status.ok(), Response.status(rQuery));
        let expectedQueryJson = Json.obj(
            ("sizes", Json.arr(Json.str("S") :: Json.str("M") :: Nil)) ::
            ("lastSize", Json.str("M")) ::
            ("minCents", Json.int64(1999i64)) ::
            Nil
        );
        assertEq(expected = Ok(expectedQueryJson), Json.parse(Response.body(rQuery)));

        let rForm = TestClient.postForm(
            "/checkout",
            ("email", "ada@shop.test") :: ("qty", "3") :: ("addon", "gift") :: ("addon", "express") :: Nil,
            app
        );
        assertEq(expected = Status.ok(), Response.status(rForm));
        let expectedFormJson = Json.obj(
            ("email", Json.str("ada@shop.test")) ::
            ("qty", Json.int(3)) ::
            ("addons", Json.arr(Json.str("gift") :: Json.str("express") :: Nil)) ::
            Nil
        );
        assertEq(expected = Ok(expectedFormJson), Json.parse(Response.body(rForm)));

        // Sending JSON to a form-expecting endpoint yields 415 Unsupported Media Type
        let rWrongCt = TestClient.postJson("/checkout", Json.obj(("email", Json.str("a@b.c")) :: Nil), app);
        assertEq(expected = Status.unsupportedMediaType(), Response.status(rWrongCt))
    }

    @Test
    def testMultipartRoundTripWithBinaryFilesAndRepeatedFields(): Unit \ Assert = {
        let png = samplePngBytes();
        let file1 = UploadedFile.make("photos", "hero.png", "image/png", png);
        let file2 = UploadedFile.make("photos", "notes.txt", "text/plain", Body.utf8Bytes("Line 1\r\nLine 2"));

        let app = Router.empty()
            |> Router.post("/admin/products", () -> {
                let form = Req.multipartForm();
                let title = MultipartForm.requireNonEmptyField("title", form);
                let tags = MultipartForm.fieldAll("tag", form);
                let photos = MultipartForm.files("photos", form);
                let primary = MultipartForm.requireFile("photos", form);
                let totalFileBytes = List.foldLeft((acc, f) -> acc + UploadedFile.size(f), 0, photos);
                Json.obj(
                    ("title", Json.str(title)) ::
                    ("tags", Json.arr(List.map(Json.str, tags))) ::
                    ("photoCount", Json.int(List.length(photos))) ::
                    ("primaryName", Json.str(UploadedFile.fileName(primary))) ::
                    ("primaryType", Json.str(UploadedFile.contentType(primary))) ::
                    ("primaryMatches", Json.bool(UploadedFile.data(primary) == png)) ::
                    ("totalFileBytes", Json.int(totalFileBytes)) ::
                    Nil
                )
            })
            |> Router.toApp
            |> Middleware.errorJson;

        let res = TestClient.postMultipart(
            "/admin/products",
            ("title", "Mechanical Keyboard") :: ("tag", "keyboards") :: ("tag", "featured") :: Nil,
            file1 :: file2 :: Nil,
            app
        );
        assertEq(expected = Status.ok(), Response.status(res));
        let expected = Json.obj(
            ("title", Json.str("Mechanical Keyboard")) ::
            ("tags", Json.arr(Json.str("keyboards") :: Json.str("featured") :: Nil)) ::
            ("photoCount", Json.int(2)) ::
            ("primaryName", Json.str("hero.png")) ::
            ("primaryType", Json.str("image/png")) ::
            ("primaryMatches", Json.bool(true)) ::
            ("totalFileBytes", Json.int(12 + 14)) ::
            Nil
        );
        assertEq(expected = Ok(expected), Json.parse(Response.body(res)))
    }

    @Test
    def testMultipartBoundaryExtractionAndErrorHandling(): Unit \ Assert = {
        assertEq(expected = Some("abc-123"), Multipart.extractBoundary("multipart/form-data; boundary=abc-123"));
        assertEq(expected = Some("quoted boundary"), Multipart.extractBoundary("MULTIPART/FORM-DATA; charset=utf-8; BOUNDARY=\"quoted boundary\""));
        assertEq(expected = None, Multipart.extractBoundary("application/json"));
        assertEq(expected = None, Multipart.extractBoundary("multipart/form-data; boundary="));

        // LF-only line endings are parsed cleanly
        let lfBody = Body.utf8Bytes(
            "--b1\nContent-Disposition: form-data; name=\"sku\"\n\nSKU-42\n--b1--\n"
        );
        match Multipart.parse("b1", lfBody) {
            case Ok(form) => assertEq(expected = Some("SKU-42"), MultipartForm.field("sku", form))
            case Err(msg) => Assert.fail("Expected valid LF multipart parse, got: ${msg}")
        };

        // Missing closing boundary returns Err
        let truncated = Body.utf8Bytes("--b1\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello");
        assertTrue(Result.isErr(Multipart.parse("b1", truncated)));

        let app = Router.empty()
            |> Router.post("/upload", () -> {
                let _ = Req.multipartForm();
                "ok"
            })
            |> Router.toApp
            |> Middleware.errorJson;

        // Wrong content type -> 415
        let r415 = TestClient.postText("/upload", "hello", app);
        assertEq(expected = Status.unsupportedMediaType(), Response.status(r415));

        // Malformed multipart payload -> 400
        let r400 = TestClient.send(
            Request.post("/upload")
                |> Request.withHeader("Content-Type", "multipart/form-data; boundary=xyz")
                |> Request.withBody("not a valid multipart body"),
            app
        );
        assertEq(expected = Status.badRequest(), Response.status(r400))
    }

    @Test
    def testMaxBodySizeAppAndRouteMiddleware(): Unit \ Assert = {
        let smallRoutes = Router.empty()
            |> Router.post("/tiny", () -> "ok:${Req.bodyLength()}")
            |> Router.withMiddleware(Middleware.limitBodySize(5));

        let app = Router.empty()
            |> Router.post("/normal", () -> "ok:${Req.bodyLength()}")
            |> Router.merge(smallRoutes)
            |> Router.toApp
            |> Middleware.maxBodySize(10)
            |> Middleware.errorJson;

        // Route limit = 5 bytes
        let rTinyOk = TestClient.postText("/tiny", "12345", app);
        assertEq(expected = Status.ok(), Response.status(rTinyOk));
        assertEq(expected = "ok:5", Response.body(rTinyOk));

        let rTinyTooBig = TestClient.postText("/tiny", "123456", app);
        assertEq(expected = Status.payloadTooLarge(), Response.status(rTinyTooBig));

        // App limit = 10 bytes
        let rNormOk = TestClient.postText("/normal", "0123456789", app);
        assertEq(expected = Status.ok(), Response.status(rNormOk));

        let rNormTooBig = TestClient.postText("/normal", "01234567890", app);
        assertEq(expected = Status.payloadTooLarge(), Response.status(rNormTooBig))
    }

}
