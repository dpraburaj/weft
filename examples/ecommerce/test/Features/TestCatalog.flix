mod Features.TestCatalog {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Features.Catalog.CatalogFeature
    use Features.Catalog.CatalogStore
    use Features.Catalog.Product
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Status
    use weft::Weft.TestSession

    ///
    /// Demonstrates testing a feature's HTTP handlers with ZERO SQLite and ZERO `IO`
    /// by swapping `CatalogStore.runWithDb` for `CatalogStore.runPureReadOnly`.
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
        let okRes = CatalogStore.runPureReadOnly(sample :: Nil, () -> apiApp(Request.get("/products/pure-geisha")));
        assertEq(expected = 200, Status.code(Response.status(okRes)));
        assertTrue(String.contains({substr = "COF-PURE-01"}, Response.body(okRes)));
        assertTrue(String.contains({substr = "$42.00"}, Response.body(okRes)));

        let missRes = CatalogStore.runPureReadOnly(sample :: Nil, () -> apiApp(Request.get("/products/missing")));
        assertEq(expected = 404, Status.code(Response.status(missRes)));
        assertTrue(Option.exists(ct -> String.contains({substr = "application/json"}, ct), Response.header("Content-Type", missRes)))
    }

    @Test
    pub def testStaticAssetsAndStorefrontHome(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);

            // Static CSS & SVG served with MIME + ETag
            let cssRes = TestSession.get("/static/styles.css", app, browser);
            assertEq(expected = 200, Status.code(Response.status(cssRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "text/css"}, ct), Response.header("Content-Type", cssRes)));
            assertTrue(Option.nonEmpty(Response.header("ETag", cssRes)));

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
    pub def testProductDetailAndJsonCatalogApi(): Unit \ {IO, Assert} =
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

            // JSON catalog 404 uses routeErrorJson
            let apiMissRes = TestSession.get("/api/products/does-not-exist", app, browser);
            assertEq(expected = 404, Status.code(Response.status(apiMissRes)));
            assertTrue(Option.exists(ct -> String.contains({substr = "application/json"}, ct), Response.header("Content-Type", apiMissRes)));
            assertTrue(String.contains({substr = "not found"}, Response.body(apiMissRes)))
        })

}
