mod TestBookmarks {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Json
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestClient
    use weft::Weft.TestEffects

    ///
    /// Notice the effect signature: `Unit \ Assert` — ZERO `IO`!
    /// The entire HTTP app (routing, JSON parsing, Bearer auth, RBAC, custom
    /// `BookmarkStore` + `Notifier` domain effects, logging, timing) runs purely.
    ///
    @Test
    def testFullBookmarkWorkflowPurely(): Unit \ Assert = {
        let app = BookmarkApp.buildApp();
        let seed = { id = 1, title = "Flix", url = "https://flix.dev", createdBy = "seed" } :: Nil;

        let ((rList, rCreate, rGet, rDelete), events) = run {
            let l = TestClient.get("/bookmarks", app);

            let createReq = Request.post("/bookmarks")
                |> Request.withBearer("editor-token")
                |> Request.withHeader("Content-Type", "application/json")
                |> Request.withBody(Json.encode(Json.obj(
                    ("title", Json.str("Weft Docs")) ::
                    ("url", Json.str("https://github.com/dpraburaj/weft")) ::
                    Nil
                )));
            let c = TestClient.send(createReq, app);
            let g = TestClient.get("/bookmarks/2", app);

            let delReq = Request.delete("/bookmarks/2")
                |> Request.withBearer("editor-token");
            let d = TestClient.send(delReq, app);
            (l, c, g, d)
        } with BookmarkDomain.runStorePure(seed)
          with BookmarkDomain.runNotifierCollecting
          with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(1000i64);

        assertEq(expected = Status.ok(), Response.status(rList));
        assertTrue(String.contains({substr = "\"count\":1"}, Response.body(rList)));

        assertEq(expected = Status.created(), Response.status(rCreate));
        assertTrue(String.contains({substr = "\"createdBy\":\"ada\""}, Response.body(rCreate)));

        assertEq(expected = Status.ok(), Response.status(rGet));
        assertTrue(String.contains({substr = "\"title\":\"Weft Docs\""}, Response.body(rGet)));

        assertEq(expected = Status.noContent(), Response.status(rDelete));
        assertEq(
            expected =
                ("bookmark.created", "ada added 'Weft Docs'") ::
                ("bookmark.deleted", "ada deleted #2") ::
                Nil,
            events
        )
    }

    @Test
    def testAuthAndRoleEnforcement(): Unit \ Assert = {
        let app = BookmarkApp.buildApp();
        let payload = Json.encode(Json.obj(("title", Json.str("Test")) :: ("url", Json.str("https://example.com")) :: Nil));

        let ((rNoAuth, rViewer), events) = run {
            let noAuth = TestClient.postJson("/bookmarks", Json.obj(("title", Json.str("T")) :: ("url", Json.str("https://x.com")) :: Nil), app);
            let viewer = TestClient.send(
                Request.post("/bookmarks")
                    |> Request.withBearer("viewer-token")
                    |> Request.withHeader("Content-Type", "application/json")
                    |> Request.withBody(payload),
                app
            );
            (noAuth, viewer)
        } with BookmarkDomain.runStorePure(Nil)
          with BookmarkDomain.runNotifierCollecting
          with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(0i64);

        assertEq(expected = Status.unauthorized(), Response.status(rNoAuth));
        assertEq(expected = Status.forbidden(), Response.status(rViewer));
        assertEq(expected = Nil, events)
    }

}
