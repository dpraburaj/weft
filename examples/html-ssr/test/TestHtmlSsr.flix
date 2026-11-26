mod TestHtmlSsr {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestClient
    use weft::Weft.TestEffects

    @Test
    def testRenderAddAndToggleTasksPurely(): Unit \ Assert = {
        let app = HtmlSsrApp.buildApp();
        let seed = { id = 1, title = "Write Flix", done = false } :: Nil;

        let (rHome, rAdd, rAfterAdd, rToggle, rAfterToggle) = run {
            let h1 = TestClient.get("/", app);
            let addReq = Request.post("/tasks")
                |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
                |> Request.withBody("title=Ship+%3CWeft%3E");
            let a = TestClient.send(addReq, app);
            let h2 = TestClient.get("/?flash=Added", app);
            let t = TestClient.postText("/tasks/1/toggle", "", app);
            let h3 = TestClient.get("/", app);
            (h1, a, h2, t, h3)
        } with HtmlSsrApp.runStorePure(seed)
          with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(1000i64);

        assertEq(expected = Status.ok(), Response.status(rHome));
        assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", rHome));
        assertTrue(String.contains({substr = "Write Flix"}, Response.body(rHome)));

        assertEq(expected = Status.found(), Response.status(rAdd));
        assertEq(expected = Some("/?flash=Added"), Response.header("Location", rAdd));

        // Escaped title + flash alert banner rendered safely
        assertTrue(String.contains({substr = "Ship &lt;Weft&gt;"}, Response.body(rAfterAdd)));
        assertTrue(String.contains({substr = "<div class=\"alert\">Added</div>"}, Response.body(rAfterAdd)));

        assertEq(expected = Status.found(), Response.status(rToggle));
        assertTrue(String.contains({substr = "<span class=\"done\">Write Flix</span>"}, Response.body(rAfterToggle)))
    }

}
