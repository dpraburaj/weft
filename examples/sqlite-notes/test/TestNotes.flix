mod TestNotes {
    use Assert.assertEq
    use Assert.assertTrue
    use weft::Weft.Db.Sqlite
    use weft::Weft.Db.SqliteConfig
    use weft::Weft.DbError
    use weft::Weft.HttpError
    use weft::Weft.Json
    use weft::Weft.Migration
    use weft::Weft.Request
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestClient
    use weft::Weft.TestEffects

    def withTestDb(f: (Request -> Response \ IO) -> Unit \ {Assert, IO}): Unit \ {Assert, IO} =
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail("Failed to open in-memory SQLite: ${e}")
            case Ok(db) =>
                let migRes = run {
                    Migration.runAll(NotesApp.migrations())
                } with Sqlite.runWith(db)
                  with DbError.runToResult;
                assertTrue(Result.isOk(migRes));

                let app = NotesApp.buildApp();
                let runApp = req ->
                    run {
                        app(req)
                    } with Sqlite.runWith(db)
                      with DbError.runToHttpError
                      with HttpError.runAsJson
                      with TestEffects.runSilentLogger
                      with TestEffects.runFixedClock(1000i64);

                f(runApp);
                Sqlite.close(db)
        }

    @Test
    def testCrudConflictAndRbac(): Unit \ {Assert, IO} =
        withTestDb(app -> {
            let notePayload = Json.encode(Json.obj(
                ("slug", Json.str("first-note")) ::
                ("title", Json.str("First Note")) ::
                ("body", Json.str("Stored in SQLite!")) ::
                Nil
            ));

            // 1. Create note as writer -> 201 Created
            let rCreate = TestClient.send(
                Request.post("/api/notes")
                    |> Request.withBearer("writer-token")
                    |> Request.withHeader("Content-Type", "application/json")
                    |> Request.withBody(notePayload),
                app
            );
            assertEq(expected = Status.created(), Response.status(rCreate));
            assertTrue(String.contains({substr = "\"author\":\"bob\""}, Response.body(rCreate)));

            // 2. Duplicate slug -> ConstraintViolation -> 409 Conflict JSON
            let rDup = TestClient.send(
                Request.post("/api/notes")
                    |> Request.withBearer("writer-token")
                    |> Request.withHeader("Content-Type", "application/json")
                    |> Request.withBody(notePayload),
                app
            );
            assertEq(expected = Status.conflict(), Response.status(rDup));

            // 3. Writer cannot delete (requires admin) -> 403 Forbidden
            let rForbidden = TestClient.send(
                Request.delete("/api/notes/1") |> Request.withBearer("writer-token"),
                app
            );
            assertEq(expected = Status.forbidden(), Response.status(rForbidden));

            // 4. Admin can delete -> 204 No Content
            let rDeleted = TestClient.send(
                Request.delete("/api/notes/1") |> Request.withBearer("admin-token"),
                app
            );
            assertEq(expected = Status.noContent(), Response.status(rDeleted))
        })

    @Test
    def testBatchTransactionRollsBackOnMidBatchError(): Unit \ {Assert, IO} =
        withTestDb(app -> {
            // Second item has empty title -> triggers HttpError mid-transaction -> rolls back first item!
            let badBatch = Json.obj(
                ("notes", Json.arr(
                    Json.obj(("slug", Json.str("ok-one")) :: ("title", Json.str("Valid")) :: ("body", Json.str("Body")) :: Nil) ::
                    Json.obj(("slug", Json.str("bad-two")) :: ("title", Json.str("   ")) :: ("body", Json.str("Body")) :: Nil) ::
                    Nil
                )) :: Nil
            );

            let rBad = TestClient.send(
                Request.post("/api/notes/batch")
                    |> Request.withBearer("writer-token")
                    |> Request.withHeader("Content-Type", "application/json")
                    |> Request.withBody(Json.encode(badBatch)),
                app
            );
            assertEq(expected = Status.badRequest(), Response.status(rBad));

            // Verify zero rows were persisted because the transaction rolled back!
            let rList = TestClient.get("/api/notes", app);
            assertEq(expected = Status.ok(), Response.status(rList));
            assertTrue(String.contains({substr = "\"count\":0"}, Response.body(rList)))
        })

}
