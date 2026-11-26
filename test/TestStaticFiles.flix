mod TestStaticFiles {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Body
    use Weft.Middleware
    use Weft.Mime
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.StaticConfig
    use Weft.StaticFile
    use Weft.StaticFiles
    use Weft.StaticStore
    use Weft.Status
    use Weft.TestClient

    import java.io.File
    import java.lang.System
    import java.nio.file.Files
    import java.nio.file.OpenOption
    import java.nio.file.Path

    def samplePng(): Vector[Int8] =
        Vector#{-119i8, 80i8, 78i8, 71i8, 13i8, 10i8, 26i8, 10i8, 0i8, -1i8}

    @Test
    def testMimeDetection(): Unit \ Assert = {
        assertEq(expected = "text/css; charset=utf-8", Mime.fromPath("/static/css/site.css"));
        assertEq(expected = "text/javascript; charset=utf-8", Mime.fromPath("bundle.mjs"));
        assertEq(expected = "image/png", Mime.fromPath("images/HERO.PNG"));
        assertEq(expected = "image/webp", Mime.fromPath("product.webp"));
        assertEq(expected = "image/svg+xml", Mime.fromPath("icons/cart.svg"));
        assertEq(expected = "font/woff2", Mime.fromPath("fonts/inter.woff2"));
        assertEq(expected = "application/pdf", Mime.fromPath("invoices/inv-001.pdf"));
        assertEq(expected = "application/octet-stream", Mime.fromPath("README"));
        assertEq(expected = "application/octet-stream", Mime.fromPath(".env"));
        assertEq(expected = "application/octet-stream", Mime.fromPath("archive.unknownext"))
    }

    @Test
    def testPureStaticFilesServingEtagAndNotModified(): Unit \ Assert = {
        let cssBytes = Body.utf8Bytes("body { color: #111; }");
        let pngBytes = samplePng();
        let indexBytes = Body.utf8Bytes("<h1>Storefront</h1>");
        let docsIndex = Body.utf8Bytes("<h1>Docs</h1>");

        let assets = Map#{
            "index.html"      => indexBytes,
            "css/app.css"     => cssBytes,
            "img/logo.png"    => pngBytes,
            "docs/index.html" => docsIndex
        };

        let app = StaticFiles.routes("/static", StaticConfig.default())
            |> Router.toApp
            |> Middleware.errorJson;

        run {
            // 1. CSS asset with MIME, Cache-Control, and ETag
            let rCss = TestClient.get("/static/css/app.css", app);
            assertEq(expected = Status.ok(), Response.status(rCss));
            assertEq(expected = Some("text/css; charset=utf-8"), Response.header("Content-Type", rCss));
            assertEq(expected = Some("public, max-age=3600"), Response.header("Cache-Control", rCss));
            assertEq(expected = "body { color: #111; }", Response.body(rCss));
            let etag = match Response.header("ETag", rCss) {
                case Some(e) => e
                case None    => { Assert.fail("Expected ETag header"); "" }
            };

            // 2. Conditional GET with matching If-None-Match -> 304 Not Modified
            let r304 = TestClient.send(
                Request.get("/static/css/app.css") |> Request.withHeader("If-None-Match", etag),
                app
            );
            assertEq(expected = Status.notModified(), Response.status(r304));
            assertEq(expected = 0, Response.bodyLength(r304));
            assertEq(expected = Some(etag), Response.header("ETag", r304));

            // 3. Weak ETag & wildcard If-None-Match also trigger 304
            let rWeak304 = TestClient.send(
                Request.get("/static/css/app.css") |> Request.withHeader("If-None-Match", "\"other\", W/${etag}"),
                app
            );
            assertEq(expected = Status.notModified(), Response.status(rWeak304));

            // 4. Binary PNG asset preserves raw non-UTF-8 bytes exactly
            let rPng = TestClient.get("/static/img/logo.png", app);
            assertEq(expected = Status.ok(), Response.status(rPng));
            assertEq(expected = Some("image/png"), Response.header("Content-Type", rPng));
            assertEq(expected = pngBytes, Response.bodyBytes(rPng));

            // 5. HEAD fallback works automatically
            let rHead = TestClient.head("/static/img/logo.png", app);
            assertEq(expected = Status.ok(), Response.status(rHead));
            assertEq(expected = 0, Response.bodyLength(rHead));
            assertTrue(Option.nonEmpty(Response.header("ETag", rHead)));

            // 6. Directory index fallback
            let rRoot = TestClient.get("/static", app);
            assertEq(expected = Status.ok(), Response.status(rRoot));
            assertEq(expected = "<h1>Storefront</h1>", Response.body(rRoot));

            let rDocs = TestClient.get("/static/docs", app);
            assertEq(expected = Status.ok(), Response.status(rDocs));
            assertEq(expected = "<h1>Docs</h1>", Response.body(rDocs));

            // 7. Missing file -> 404
            let rMissing = TestClient.get("/static/does-not-exist.js", app);
            assertEq(expected = Status.notFound(), Response.status(rMissing))
        } with StaticStore.runPure(assets)
    }

    @Test
    def testStaticFilesTraversalAndDotfileProtection(): Unit \ Assert = {
        assertEq(expected = None, StaticFiles.sanitizePath(false, "../etc/passwd"));
        assertEq(expected = None, StaticFiles.sanitizePath(false, "css/../../secret.txt"));
        assertEq(expected = None, StaticFiles.sanitizePath(false, ".env"));
        assertEq(expected = None, StaticFiles.sanitizePath(false, "sub/.git/config"));
        assertEq(expected = None, StaticFiles.sanitizePath(false, "a\\b.txt"));
        assertEq(expected = None, StaticFiles.sanitizePath(false, "a\u0000b.txt"));
        assertEq(expected = Some(".well-known/security.txt"), StaticFiles.sanitizePath(true, ".well-known/security.txt"));

        let assets = Map#{
            ".env"                     => Body.utf8Bytes("SECRET=1"),
            ".well-known/security.txt" => Body.utf8Bytes("Contact: sec@shop.test"),
            "public.txt"               => Body.utf8Bytes("hello")
        };

        let strictApp = StaticFiles.routes("/static", StaticConfig.default())
            |> Router.toApp
            |> Middleware.errorJson;

        let dotfilesApp = StaticFiles.routes("/static", StaticConfig.default() |> StaticConfig.withDotfiles(true))
            |> Router.toApp
            |> Middleware.errorJson;

        run {
            assertEq(expected = Status.notFound(), Response.status(TestClient.get("/static/.env", strictApp)));
            assertEq(expected = Status.notFound(), Response.status(TestClient.get("/static/../public.txt", strictApp)));
            assertEq(expected = Status.ok(), Response.status(TestClient.get("/static/public.txt", strictApp)));

            // Dotfiles allowed when explicitly opted in
            let rWellKnown = TestClient.get("/static/.well-known/security.txt", dotfilesApp);
            assertEq(expected = Status.ok(), Response.status(rWellKnown));
            assertEq(expected = "Contact: sec@shop.test", Response.body(rWellKnown))
        } with StaticStore.runPure(assets)
    }

    @Test
    def testStaticStoreRunFromDirRealFilesystem(): Unit \ {Assert, IO} = {
        let emptyOpts: Array[OpenOption, IO] = Array#{} @ Static;
        let tmpRoot = System.getProperty("java.io.tmpdir");
        let baseFile = new File(tmpRoot, "weft-static-test-${System.nanoTime()}");
        let pubFile = new File(baseFile, "public");
        let imgFile = new File(pubFile, "img");
        let _ = imgFile.mkdirs();

        let baseDir: Path = baseFile.toPath();
        let pubDir: Path = pubFile.toPath();
        let imgDir: Path = imgFile.toPath();

        let secretFile: Path = baseDir.resolve("secret.txt");
        let cssFile: Path = pubDir.resolve("app.css");
        let pngFile: Path = imgDir.resolve("item.png");
        let dotFile: Path = pubDir.resolve(".env");

        let pngBytes = samplePng();
        let _ = Files.write(secretFile, Vector.toArray(Static, Body.utf8Bytes("TOP SECRET")), emptyOpts);
        let _ = Files.write(cssFile, Vector.toArray(Static, Body.utf8Bytes("h1{margin:0}")), emptyOpts);
        let _ = Files.write(pngFile, Vector.toArray(Static, pngBytes), emptyOpts);
        let _ = Files.write(dotFile, Vector.toArray(Static, Body.utf8Bytes("DB_PASS=123")), emptyOpts);

        let app = StaticFiles.routes("/assets", StaticConfig.default())
            |> Router.toApp
            |> Middleware.errorJson;

        run {
            let rCss = TestClient.get("/assets/app.css", app);
            assertEq(expected = Status.ok(), Response.status(rCss));
            assertEq(expected = Some("text/css; charset=utf-8"), Response.header("Content-Type", rCss));
            assertEq(expected = "h1{margin:0}", Response.body(rCss));
            assertTrue(Option.nonEmpty(Response.header("Last-Modified", rCss)));
            assertTrue(Option.nonEmpty(Response.header("ETag", rCss)));

            let rPng = TestClient.get("/assets/img/item.png", app);
            assertEq(expected = Status.ok(), Response.status(rPng));
            assertEq(expected = Some("image/png"), Response.header("Content-Type", rPng));
            assertEq(expected = pngBytes, Response.bodyBytes(rPng));

            // Traversal to sibling secret.txt and hidden .env are blocked
            assertEq(expected = Status.notFound(), Response.status(TestClient.get("/assets/../secret.txt", app)));
            assertEq(expected = Status.notFound(), Response.status(TestClient.get("/assets/.env", app)))
        } with StaticStore.runFromDir(pubDir.toString());

        // Clean up temp files
        let _ = Files.deleteIfExists(dotFile);
        let _ = Files.deleteIfExists(pngFile);
        let _ = Files.deleteIfExists(cssFile);
        let _ = Files.deleteIfExists(secretFile);
        let _ = Files.deleteIfExists(imgDir);
        let _ = Files.deleteIfExists(pubDir);
        let _ = Files.deleteIfExists(baseDir);
        ()
    }

}
