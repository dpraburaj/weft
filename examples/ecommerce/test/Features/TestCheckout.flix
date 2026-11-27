mod Features.TestCheckout {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestSession

    @Test
    pub def testCheckoutAuthGuardAndValidationAndAtomicSuccess(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((db, app) -> region rc {
            let browser = TestSession.make(rc);

            // 1. Unauthenticated /checkout redirects to /login
            let unauthRes = TestSession.get("/checkout", app, browser);
            assertEq(expected = 303, Status.code(Response.status(unauthRes)));
            assertEq(expected = Some("/login"), Response.header("Location", unauthRes));

            // 2. Sign in as Ada and add 2× Ethiopia Yirgacheffe (initial stock 24) + WELCOME10
            let _ = TestHarness.loginAs("ada@example.com", "coffee123", app, browser);
            let homeRes = TestSession.get("/", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(homeRes);
            let _ = TestHarness.htmxPostForm("/cart/items", csrf, ("product_id", "1") :: ("quantity", "2") :: Nil, app, browser);
            let _ = TestHarness.htmxPostForm("/cart/promo", csrf, ("code", "WELCOME10") :: Nil, app, browser);

            // 3. Invalid checkout form returns 422 with inline field errors
            let checkoutGet = TestSession.get("/checkout", app, browser);
            assertEq(expected = 200, Status.code(Response.status(checkoutGet)));
            let ckCsrf = TestHarness.extractCsrfOrFail(checkoutGet);

            let badCk = TestSession.postForm(
                "/checkout",
                ("_csrf", ckCsrf) :: ("shipping_name", "") :: ("address", "1") ::
                ("city", "") :: ("postal_code", "") :: ("country", "") :: Nil,
                app,
                browser
            );
            assertEq(expected = 422, Status.code(Response.status(badCk)));
            assertTrue(String.contains({substr = "field-error"}, Response.body(badCk)));
            assertEq(expected = 0i64, TestHarness.orderCount(db));

            // 4. Valid checkout places order atomically, decrements stock 24 -> 22, clears cart
            let okCk = TestSession.postForm(
                "/checkout",
                ("_csrf", ckCsrf) :: ("shipping_name", "Ada Lovelace") ::
                ("address", "12 Analytical Engine Way") :: ("city", "London") ::
                ("postal_code", "SW1A 1AA") :: ("country", "United Kingdom") :: Nil,
                app,
                browser
            );
            assertEq(expected = 303, Status.code(Response.status(okCk)));
            let receiptLoc = Response.header("Location", okCk) |> Option.getWithDefault("");
            assertTrue(String.startsWith({prefix = "/orders/"}, receiptLoc));
            assertEq(expected = 22, TestHarness.productStock(db, 1i64));
            assertEq(expected = 1i64, TestHarness.orderCount(db));

            // 5. Receipt page shows order number & flash confirmation
            let receiptRes = TestSession.get(receiptLoc, app, browser);
            assertEq(expected = 200, Status.code(Response.status(receiptRes)));
            let receiptBody = Response.body(receiptRes);
            assertTrue(String.contains({substr = "WR-"}, receiptBody));
            assertTrue(String.contains({substr = "Ethiopia Yirgacheffe Washed"}, receiptBody));

            // 6. Transactional outbox job sends confirmation email via Mailer effect
            let emails = TestHarness.drainJobs(db);
            assertEq(expected = 1, List.length(emails));
            match emails {
                case msg :: Nil =>
                    assertEq(expected = "ada@example.com", msg#to);
                    assertTrue(String.contains({substr = "Confirmed"}, msg#subject))
                case _ => assertTrue(false)
            }
        })

    @Test
    pub def testInsufficientStockAtomicRollback(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((db, app) -> region rc {
            let browser = TestSession.make(rc);
            let _ = TestHarness.loginAs("ada@example.com", "coffee123", app, browser);
            let homeRes = TestSession.get("/", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(homeRes);

            // Add 2 units of product #1 while stock is 24
            let _ = TestHarness.htmxPostForm("/cart/items", csrf, ("product_id", "1") :: ("quantity", "2") :: Nil, app, browser);

            // Simulate concurrent buyer exhausting inventory down to 1 before checkout
            TestHarness.forceProductStock(db, 1i64, 1);

            let ckGet = TestSession.get("/checkout", app, browser);
            let ckCsrf = TestHarness.extractCsrfOrFail(ckGet);
            let conflictRes = TestSession.postForm(
                "/checkout",
                ("_csrf", ckCsrf) :: ("shipping_name", "Ada Lovelace") ::
                ("address", "12 Analytical Engine Way") :: ("city", "London") ::
                ("postal_code", "SW1A 1AA") :: ("country", "UK") :: Nil,
                app,
                browser
            );
            assertEq(expected = 409, Status.code(Response.status(conflictRes)));
            assertTrue(String.contains({substr = "Insufficient stock"}, Response.body(conflictRes)));

            // Verify complete rollback: stock remains 1, 0 orders created, 0 emails queued
            assertEq(expected = 1, TestHarness.productStock(db, 1i64));
            assertEq(expected = 0i64, TestHarness.orderCount(db));
            let emails = TestHarness.drainJobs(db);
            assertEq(expected = 0, List.length(emails))
        })

    @Test
    pub def testOrderOwnershipEnforced(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((db, app) -> region rc {
            // 1. Ada places an order
            let ada = TestSession.make(rc);
            let _ = TestHarness.loginAs("ada@example.com", "coffee123", app, ada);
            let adaHome = TestSession.get("/", app, ada);
            let adaCsrf = TestHarness.extractCsrfOrFail(adaHome);
            let _ = TestHarness.htmxPostForm("/cart/items", adaCsrf, ("product_id", "1") :: ("quantity", "1") :: Nil, app, ada);
            let ckGet = TestSession.get("/checkout", app, ada);
            let ckCsrf = TestHarness.extractCsrfOrFail(ckGet);
            let okCk = TestSession.postForm(
                "/checkout",
                ("_csrf", ckCsrf) :: ("shipping_name", "Ada Lovelace") ::
                ("address", "12 Analytical Engine Way") :: ("city", "London") ::
                ("postal_code", "SW1A 1AA") :: ("country", "UK") :: Nil,
                app,
                ada
            );
            assertEq(expected = 303, Status.code(Response.status(okCk)));
            let orderId = TestHarness.latestOrderId(db);

            // 2. Register a second customer ("bob") and attempt to view Ada's order -> 403 Forbidden
            let bob = TestSession.make(rc);
            let regGet = TestSession.get("/register", app, bob);
            let regCsrf = TestHarness.extractCsrfOrFail(regGet);
            let _ = TestSession.postForm(
                "/register",
                ("_csrf", regCsrf) :: ("name", "Bob Buyer") :: ("email", "bob@example.com") :: ("password", "password123") :: Nil,
                app,
                bob
            );
            let snoopRes = TestSession.get("/orders/${orderId}", app, bob);
            assertEq(expected = 403, Status.code(Response.status(snoopRes)))
        })

}
