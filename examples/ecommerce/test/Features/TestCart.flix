mod Features.TestCart {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestSession

    @Test
    pub def testCsrfRejectionOnForgedCartMutation(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);
            let _ = TestSession.get("/", app, browser);

            // Missing CSRF token must be rejected with 403 Forbidden
            let forgedRes = TestSession.postForm("/cart/items", ("product_id", "1") :: ("quantity", "1") :: Nil, app, browser);
            assertEq(expected = 403, Status.code(Response.status(forgedRes)))
        })

    @Test
    pub def testHtmxAddUpdateDeleteAndPromoCodes(): Unit \ {IO, Assert} =
        TestHarness.withTestEnv((_, app) -> region rc {
            let browser = TestSession.make(rc);
            let homeRes = TestSession.get("/", app, browser);
            let csrf = TestHarness.extractCsrfOrFail(homeRes);

            // 1. HTMX Add to Cart returns live `#cart-badge` partial with count 2
            let addRes = TestHarness.htmxPostForm(
                "/cart/items",
                csrf,
                ("product_id", "1") :: ("quantity", "2") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(addRes)));
            assertTrue(String.contains({substr = "id=\"cart-badge\""}, Response.body(addRes)));
            assertTrue(String.contains({substr = ">2<"}, Response.body(addRes)));

            // 2. Cart page shows subtotal $44.00 + $8.00 shipping = $52.00
            let cartRes = TestSession.get("/cart", app, browser);
            assertEq(expected = 200, Status.code(Response.status(cartRes)));
            let cartBody = Response.body(cartRes);
            assertTrue(String.contains({substr = "$44.00"}, cartBody));
            assertTrue(String.contains({substr = "$8.00"}, cartBody));
            assertTrue(String.contains({substr = "$52.00"}, cartBody));

            // 3. HTMX increment quantity to 3 ($66.00) with OOB badge swap
            let qtyRes = TestHarness.htmxPostForm(
                "/cart/items/1/qty",
                csrf,
                ("quantity", "3") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(qtyRes)));
            let qtyBody = Response.body(qtyRes);
            assertTrue(String.contains({substr = "hx-swap-oob=\"true\""}, qtyBody));
            assertTrue(String.contains({substr = "$66.00"}, qtyBody));

            // 4. Exceeding stock shows graceful inline error without failing
            let overStockRes = TestHarness.htmxPostForm(
                "/cart/items/1/qty",
                csrf,
                ("quantity", "999") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(overStockRes)));
            assertTrue(String.contains({substr = "available"}, Response.body(overStockRes)));

            // 5. Apply WELCOME10 (10% off $66.00 = -$6.60, + $8.00 shipping = $67.40)
            let promoRes = TestHarness.htmxPostForm(
                "/cart/promo",
                csrf,
                ("code", "WELCOME10") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(promoRes)));
            let promoBody = Response.body(promoRes);
            assertTrue(String.contains({substr = "-$6.60"}, promoBody));
            assertTrue(String.contains({substr = "$67.40"}, promoBody));

            // 6. Apply FREESHIP removes shipping ($66.00 total)
            let shipRes = TestHarness.htmxPostForm(
                "/cart/promo",
                csrf,
                ("code", "FREESHIP") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(shipRes)));
            assertTrue(String.contains({substr = "FREE"}, Response.body(shipRes)));

            // 7. Unknown promo shows friendly error
            let badPromoRes = TestHarness.htmxPostForm(
                "/cart/promo",
                csrf,
                ("code", "NOPE99") :: Nil,
                app,
                browser
            );
            assertEq(expected = 200, Status.code(Response.status(badPromoRes)));
            assertTrue(String.contains({substr = "Unknown promo code"}, Response.body(badPromoRes)));

            // 8. HTMX DELETE removes item and resets OOB cart badge to 0
            let delRes = TestHarness.htmxDelete("/cart/items/1", csrf, app, browser);
            assertEq(expected = 200, Status.code(Response.status(delRes)));
            let delBody = Response.body(delRes);
            assertTrue(String.contains({substr = "Your cart is empty"}, delBody));
            assertTrue(String.contains({substr = "hx-swap-oob=\"true\""}, delBody));
            assertTrue(String.contains({substr = ">0<"}, delBody))
        })

}
