mod Features.TestCatalog {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Features.Catalog.CatalogFeature
    use Features.Catalog.CatalogStore
    use Shared.Domain.Product
    use Time.Clock
    use weft::Weft.Body
    use weft::Weft.Cache
    use weft::Weft.Compression
    use weft::Weft.Db.PoolStats
    use weft::Weft.Db.Sqlite
    use weft::Weft.DbError
    use weft::Weft.JobStore
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.RateLimiter
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Scheduler
    use weft::Weft.ScheduleStore
    use weft::Weft.SessionStore
    use weft::Weft.Status
    use weft::Weft.TestEffects
    use weft::Weft.TestSession

    ///
    /// Demonstrates testing a feature's HTTP handlers with ZERO SQLite and ZERO `IO`
    /// by swapping `CatalogStore.runWithDb` for `CatalogStore.runPureReadOnly` + `Cache.runPure`.
    ///
    @Test
    pub def testCatalogApiWithPureStore(): Unit \ Assert = {
        let sample: Product = {
            id          = 99i64,
            sku         = "COF-PURE-01",
            slug        = "pure-geisha",
            name        = "Panama Geisha Pure",
            category    = "coffee",
            description = "Jasmine & bergamot tested with zero database I/O.",
            priceCents  = 4200i64,
            stock       = 5,
            hasImage    = false
        };
        let apiApp = CatalogFeature.apiRoutes() |> Router.toApp |> Middleware.errorJson;
        run {
            let okRes = apiApp(Request.get("/products/pure-geisha"));
            assertEq(expected = 200, Status.code(Response.status(okRes)));
            assertTrue(String.contains({substr = "COF-PURE-01"}, Response.body(okRes)));
            assertTrue(String.contains({substr = "$42.00"}, Response.body(okRes)));

            // SSE catalog snapshot endpoint runs 100% purely too
            let sseRes = apiApp(Request.get("/events/catalog"));
            assertEq(expected = 200, Status.code(Response.status(sseRes)));
            assertEq(expected = Some("text/event-stream; charset=utf-8"), Response.header("Content-Type", sseRes));
            assertTrue(String.contains({substr = "event: catalog.summary"}, Response.body(sseRes)));
            assertTrue(String.contains({substr = "COF-PURE-01"}, Response.body(sseRes)));

            let missRes = apiApp(Request.get("/products/missing"));
            assertEq(expected = 404, Status.code(Response.status(missRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "application/json"}, ct), Response.header("Content-Type", missRes)))
        } with CatalogStore.runPureReadOnly(sample :: Nil)
          with Cache.runPure
          with TestEffects.runFixedClock(1000i64)
    }

    @Test
    pub def testStaticAssetsRangeAndStorefrontHome(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);

            // Static CSS & SVG served with MIME + ETag + Accept-Ranges: bytes
            let cssRes = TestSession.get("/static/styles.css", app, browser);
            assertEq(expected = 200, Status.code(Response.status(cssRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "text/css"}, ct), Response.header("Content-Type", cssRes)));
            assertTrue(Option.nonEmpty(Response.header("ETag", cssRes)));
            assertEq(expected = Some("bytes"), Response.header("Accept-Ranges", cssRes));

            // HTTP Range request on static asset -> 206 Partial Content
            let rangeRes = TestSession.send(
                Request.get("/static/styles.css") |> Request.withHeader("Range", "bytes=0-3"),
                app,
                browser
            );
            assertEq(expected = 206, Status.code(Response.status(rangeRes)));
            assertEq(expected = "body", Response.body(rangeRes));

            let svgRes = TestSession.get("/static/brand-mark.svg", app, browser);
            assertEq(expected = 200, Status.code(Response.status(svgRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "image/svg+xml"}, ct), Response.header("Content-Type", svgRes)));

            // Home storefront renders SSR page with seeded catalog, HTMX, and CSRF meta tag
            let homeRes = TestSession.get("/", app, browser);
            assertEq(expected = 200, Status.code(Response.status(homeRes)));
            let homeBody = Response.body(homeRes);
            assertTrue(String.contains({substr = "Weft Roasters"}, homeBody));
            assertTrue(String.contains({substr = "Ethiopia Yirgacheffe Washed"}, homeBody));
            assertTrue(String.contains({substr = "Showing 6 of 10 products"}, homeBody));
            assertTrue(Option.nonEmpty(TestSession.extractCsrfToken(homeRes)))
        })

    @Test
    pub def testHtmxProductGridFilteringSortingAndPagination(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);

            // Category filter partial
            let grindersRes = TestSession.get("/products/grid?category=grinders&sort=price_asc", app, browser);
            assertEq(expected = 200, Status.code(Response.status(grindersRes)));
            let grindersBody = Response.body(grindersRes);
            assertFalse(String.contains({substr = "<!DOCTYPE html>"}, grindersBody));
            assertTrue(String.contains({substr = "Field Stainless Hand Grinder"}, grindersBody));
            assertTrue(String.contains({substr = "Precision 64mm Flat Burr Grinder"}, grindersBody));
            assertFalse(String.contains({substr = "Ethiopia Yirgacheffe Washed"}, grindersBody));

            // Search query partial
            let searchRes = TestSession.get("/products/grid?q=Decaf", app, browser);
            assertEq(expected = 200, Status.code(Response.status(searchRes)));
            assertTrue(String.contains({substr = "Colombia Sugarcane Decaf"}, Response.body(searchRes)));
            assertTrue(String.contains({substr = "Showing 1 of 1 products"}, Response.body(searchRes)));

            // Page 2 pagination (10 products, 6 per page -> 4 on page 2)
            let page2Res = TestSession.get("/products/grid?page=2", app, browser);
            assertEq(expected = 200, Status.code(Response.status(page2Res)));
            assertTrue(String.contains({substr = "Showing 4 of 10 products"}, Response.body(page2Res)))
        })

    @Test
    pub def testProductDetailGzipCompressionAndJsonCatalogApi(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);

            // Product detail SSR page + 404
            let detailRes = TestSession.get("/products/ethiopia-yirgacheffe", app, browser);
            assertEq(expected = 200, Status.code(Response.status(detailRes)));
            assertTrue(String.contains({substr = "COF-ETH-01"}, Response.body(detailRes)));

            let missHtml = TestSession.get("/products/nonexistent-slug", app, browser);
            assertEq(expected = 404, Status.code(Response.status(missHtml)));

            // JSON catalog list API
            let apiListRes = TestSession.get("/api/products?category=coffee&per_page=2", app, browser);
            assertEq(expected = 200, Status.code(Response.status(apiListRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "application/json"}, ct), Response.header("Content-Type", apiListRes)));
            match Json.parse(Response.body(apiListRes)) {
                case Ok(j) =>
                    assertEq(expected = Some(4i64), Json.getField("totalItems", j) |> Option.flatMap(Json.asInt64));
                    assertEq(expected = Some(2), Json.getField("totalPages", j) |> Option.flatMap(Json.asInt))
                case Err(_) => assertTrue(false)
            };

            // Gzip compression on /api/products when Accept-Encoding: gzip is sent
            let gzRes = TestSession.send(
                Request.get("/api/products") |> Request.withHeader("Accept-Encoding", "gzip"),
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(gzRes)));
            assertEq(expected = Some("gzip"), Response.header("Content-Encoding", gzRes));
            assertEq(expected = Some("Accept-Encoding"), Response.header("Vary", gzRes));
            match Compression.gunzip(Response.bodyBytes(gzRes)) {
                case Ok(plain) => assertTrue(String.contains({substr = "Ethiopia Yirgacheffe"}, Body.utf8String(plain)))
                case Err(_)    => assertTrue(false)
            };

            // JSON catalog 404 uses routeErrorJson
            let apiMissRes = TestSession.get("/api/products/does-not-exist", app, browser);
            assertEq(expected = 404, Status.code(Response.status(apiMissRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "application/json"}, ct), Response.header("Content-Type", apiMissRes)));
            assertTrue(String.contains({substr = "not found"}, Response.body(apiMissRes)))
        })

    @Test
    pub def testPooledWalHealthEndpointCacheInvalidationAndScheduler(): Unit \ {IO, Assert} =
        TestHarness.withPooledWalTestEnv((db, app) -> region rc {
            let browser = TestSession.make(rc);

            // 1. WAL reader pool is active and exposed via GET /health
            match Sqlite.readerPoolStats(db) {
                case Some(st) => assertEq(expected = 4, PoolStats.maxConnections(st))
                case None     => assertTrue(false)
            };
            let healthRes = TestSession.get("/health", app, browser);
            assertEq(expected = 200, Status.code(Response.status(healthRes)));
            assertTrue(String.contains({substr = "\"status\":\"ok\""}, Response.body(healthRes)));
            assertTrue(String.contains({substr = "\"maxConnections\":4"}, Response.body(healthRes)));

            // 2. First GET /api/products populates Cache; admin stock update invalidates it!
            let api1 = TestSession.get("/api/products?category=coffee&per_page=10", app, browser);
            assertTrue(String.contains({substr = "\"stock\":24"}, Response.body(api1)));

            let admin = TestSession.make(rc);
            let _ = TestHarness.loginAs("admin@weftroasters.com", "admin123", app, admin);
            let dashRes = TestSession.get("/admin", app, admin);
            let csrf = TestHarness.extractCsrfOrFail(dashRes);
            let _ = TestHarness.htmxPostForm("/admin/products/1/stock", csrf, ("stock", "77") :: Nil, app, admin);

            let api2 = TestSession.get("/api/products?category=coffee&per_page=10", app, browser);
            assertTrue(String.contains({substr = "\"stock\":77"}, Response.body(api2)));

            // 3. Maintenance scheduler executes all 4 periodic tasks cleanly against SQLite
            let sched = ShopApp.maintenanceScheduler();
            let tickRes = run {
                Scheduler.tick(sched)
            } with ScheduleStore.runWithDb
              with SessionStore.runWithDb
              with Cache.runWithDb
              with RateLimiter.runWithDb
              with JobStore.runWithDb
              with Sqlite.runWith(db)
              with DbError.runToResult
              with Clock.runWithIO
              with TestEffects.runSilentLogger;
            match tickRes {
                case Ok(ran) => assertEq(expected = 4, List.length(ran))
                case Err(_)  => assertTrue(false)
            }
        })

}
