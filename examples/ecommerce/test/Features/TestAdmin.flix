mod Features.TestAdmin {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Email
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestSession
    use weft::Weft.UploadedFile

    @Test
    pub def testCustomerForbiddenOnAdminDashboard(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let customer = TestSession.make(rc);
            let _ = TestHarness.loginAs("ada@example.com", "coffee123", app, customer);

            let forbiddenRes = TestSession.get("/admin", app, customer);
            assertEq(expected = 403, Status.code(Response.status(forbiddenRes)))
        })

    @Test
    pub def testAdminMultipartImageUploadAndInlineStockUpdate(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((db, app) -> region rc {
            let admin = TestSession.make(rc);
            let _ = TestHarness.loginAs("admin@weftroasters.com", "admin123", app, admin);

            let dashRes = TestSession.get("/admin", app, admin);
            assertEq(expected = 200, Status.code(Response.status(dashRes)));
            let csrf = TestHarness.extractCsrfOrFail(dashRes);

            // 1. Multipart product creation with binary PNG header bytes
            let pngBytes: Vector[Int8] = Vector#{-119i8, 80i8, 78i8, 71i8, 13i8, 10i8, 26i8, 10i8, 0i8, 1i8, 2i8, 3i8};
            let imgFile = UploadedFile.make("image", "kenya.png", "image/png", pngBytes);
            let createRes = TestSession.postMultipart(
                "/admin/products",
                ("_csrf", csrf) ::
                ("sku", "COF-KEN-05") ::
                ("name", "Kenya AA Nyeri") ::
                ("category", "coffee") ::
                ("description", "Bright blackcurrant and Meyer lemon single origin.") ::
                ("price_cents", "2600") ::
                ("stock", "17") ::
                Nil,
                imgFile :: Nil,
                app,
                admin
            );
            assertEq(expected = 303, Status.code(Response.status(createRes)));

            // 2. Binary media endpoint returns exact PNG bytes stored in SQLite BLOB
            let newPid = TestHarness.latestProductId(db);
            let mediaRes = TestSession.get("/media/products/${newPid}", app, admin);
            assertEq(expected = 200, Status.code(Response.status(mediaRes)));
            assertEq(expected = Some("image/png"), Response.header("Content-Type", mediaRes));
            assertEq(expected = pngBytes, Response.bodyBytes(mediaRes));

            // 3. HTMX inline stock update updates DB and returns refreshed stock form partial
            let stockRes = TestHarness.htmxPostForm(
                "/admin/products/${newPid}/stock",
                csrf,
                ("stock", "42") :: Nil,
                app,
                admin
            );
            assertEq(expected = 200, Status.code(Response.status(stockRes)));
            assertTrue(String.contains({substr = "value=\"42\""}, Response.body(stockRes)));
            assertEq(expected = 42, TestHarness.productStock(db, newPid))
        })

    @Test
    pub def testAdminOrderFulfillmentStatusUpdateDispatchesEmailJob(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((db, app) -> region rc {
            // 1. Customer places an order
            let cust = TestSession.make(rc);
            let _ = TestHarness.loginAs("ada@example.com", "coffee123", app, cust);
            let homeRes = TestSession.get("/", app, cust);
            let custCsrf = TestHarness.extractCsrfOrFail(homeRes);
            let _ = TestHarness.htmxPostForm("/cart/items", custCsrf, ("product_id", "1") :: ("quantity", "1") :: Nil, app, cust);
            let ckGet = TestSession.get("/checkout", app, cust);
            let ckCsrf = TestHarness.extractCsrfOrFail(ckGet);
            let _ = TestSession.postForm(
                "/checkout",
                ("_csrf", ckCsrf) :: ("shipping_name", "Ada Lovelace") ::
                ("address", "12 Analytical Engine Way") :: ("city", "London") ::
                ("postal_code", "SW1A 1AA") :: ("country", "UK") :: Nil,
                app,
                cust
            );
            let orderId = TestHarness.latestOrderId(db);
            // Clear confirmation email job first so we isolate the status email job
            let _ = TestHarness.drainJobs(db);

            // 2. Admin transitions order status paid -> shipped via HTMX
            let admin = TestSession.make(rc);
            let _ = TestHarness.loginAs("admin@weftroasters.com", "admin123", app, admin);
            let dashRes = TestSession.get("/admin", app, admin);
            let adminCsrf = TestHarness.extractCsrfOrFail(dashRes);

            let statusRes = TestHarness.htmxPostForm(
                "/admin/orders/${orderId}/status",
                adminCsrf,
                ("status", "shipped") :: Nil,
                app,
                admin
            );
            assertEq(expected = 200, Status.code(Response.status(statusRes)));
            assertTrue(String.contains({substr = "status-shipped"}, Response.body(statusRes)));

            // 3. AdminJobs handler sends rich HTML + text status update email via Weft.Mailer
            let emails = TestHarness.drainJobs(db);
            assertEq(expected = 1, List.length(emails));
            match emails {
                case msg :: Nil =>
                    assertEq(expected = "ada@example.com" :: Nil, Email.to(msg));
                    assertTrue(String.contains({substr = "shipped"}, Email.subject(msg)));
                    assertTrue(Option.nonEmpty(Email.htmlBody(msg)))
                case _ => assertTrue(false)
            };

            // 4. Dedicated admin pages render cleanly with active filtering
            let ordersFiltered = TestSession.get("/admin/orders?status=shipped", app, admin);
            assertEq(expected = 200, Status.code(Response.status(ordersFiltered)));
            assertTrue(String.contains({substr = "WR-"}, Response.body(ordersFiltered)));

            let lowStockPage = TestSession.get("/admin/products?stock=low", app, admin);
            assertEq(expected = 200, Status.code(Response.status(lowStockPage)));
            assertTrue(String.contains({substr = "Stoneware Tasting Cups"}, Response.body(lowStockPage)));

            let newProdPage = TestSession.get("/admin/products/new", app, admin);
            assertEq(expected = 200, Status.code(Response.status(newProdPage)));
            assertTrue(String.contains({substr = "Create Product"}, Response.body(newProdPage)))
        })

}
