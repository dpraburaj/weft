mod TestSqliteDb {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Db
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.HttpError
    use Weft.Json
    use Weft.Middleware
    use Weft.Migration
    use Weft.Req
    use Weft.Response
    use Weft.Router
    use Weft.Row
    use Weft.SqlValue
    use Weft.Status
    use Weft.TestClient

    import java.io.File

    @Test
    def testSqliteCrudAndAllSqlValueTypes(): Unit \ {Assert, IO} = {
        let res = run {
            Sqlite.withDb(SqliteConfig.inMemory(), () -> {
                let _ = Db.executeSql(
                    "CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, score REAL, big INTEGER, active INTEGER, note TEXT)"
                );
                let id1 = Db.insertAndGetId(
                    "INSERT INTO items (name, score, big, active, note) VALUES (?, ?, ?, ?, ?)",
                    SqlValue.text("Ada's \"SQL\"'; DROP TABLE items; --") ::
                    SqlValue.float(98.5) ::
                    SqlValue.int64(9000000000i64) ::
                    SqlValue.bool(true) ::
                    SqlValue.nullVal() ::
                    Nil
                );
                assertEq(expected = 1i64, id1);

                match Db.queryOne("SELECT id, name, score, big, active, note FROM items WHERE id = ?", SqlValue.int64(id1) :: Nil) {
                    case None => Assert.fail("Expected inserted row")
                    case Some(row) =>
                        assertEq(expected = 1, Row.requireInt("id", row));
                        assertEq(expected = "Ada's \"SQL\"'; DROP TABLE items; --", Row.requireString("name", row));
                        assertEq(expected = 98.5, Row.requireFloat("score", row));
                        assertEq(expected = 9000000000i64, Row.requireInt64("big", row));
                        assertTrue(Row.requireBool("active", row));
                        assertTrue(Row.isNull("note", row));
                        assertEq(expected = None, Row.optionalString("note", row))
                };

                let updated = Db.execute("UPDATE items SET active = ?, note = ? WHERE id = ?",
                    SqlValue.bool(false) :: SqlValue.text("updated") :: SqlValue.int64(id1) :: Nil);
                assertEq(expected = 1, updated);

                match Db.queryOne("SELECT active, note FROM items WHERE id = ?", SqlValue.int64(id1) :: Nil) {
                    case None => Assert.fail("Expected updated row")
                    case Some(row) =>
                        assertFalse(Row.requireBool("active", row));
                        assertEq(expected = Some("updated"), Row.optionalString("note", row))
                }
            })
        } with DbError.runToResult;

        match res {
            case Ok(Ok(()))        => ()
            case Ok(Err(openErr))  => Assert.fail("Open failed: ${openErr}")
            case Err((kind, msg))  => Assert.fail("Unexpected DbError (${kind}): ${msg}")
        }
    }

    @Test
    def testSqliteTransactionsCommitAndRollbackOnEffects(): Unit \ {Assert, IO} = {
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail(e)
            case Ok(db) =>
                let setup = run {
                    let _ = Db.executeSql("CREATE TABLE ledger (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL UNIQUE)");
                    Db.transaction(() -> {
                        let _ = Db.execute("INSERT INTO ledger (label) VALUES (?)", SqlValue.text("committed") :: Nil);
                        ()
                    })
                } with Sqlite.runWith(db)
                  with DbError.runToResult;
                assertTrue(Result.isOk(setup));

                // Transaction that fails mid-way with DbError (UNIQUE constraint) MUST roll back earlier insert!
                let failedTx = run {
                    Db.transaction(() -> {
                        let _ = Db.execute("INSERT INTO ledger (label) VALUES (?)", SqlValue.text("should-rollback-db") :: Nil);
                        let _ = Db.execute("INSERT INTO ledger (label) VALUES (?)", SqlValue.text("committed") :: Nil);
                        ()
                    })
                } with Sqlite.runWith(db)
                  with DbError.runToResult;
                match failedTx {
                    case Err((DbErrorKind.ConstraintViolation, _)) => ()
                    case other => Assert.fail("Expected ConstraintViolation, got: ${other}")
                };

                // Transaction that fails mid-way with HttpError MUST also roll back via transactionHttp!
                let httpRes = run {
                    Db.transactionHttp(() -> {
                        let _ = Db.execute("INSERT INTO ledger (label) VALUES (?)", SqlValue.text("should-rollback-http") :: Nil);
                        HttpError.badRequest("aborting tx via HttpError")
                    })
                } with Sqlite.runWith(db)
                  with DbError.runToHttpError
                  with HttpError.runAsJson;
                assertEq(expected = Status.badRequest(), Response.status(httpRes));

                // Verify ONLY "committed" exists in the table!
                let labelsRes = run {
                    Db.queryMap("SELECT label FROM ledger ORDER BY id", Nil, r -> Row.requireString("label", r))
                } with Sqlite.runWith(db)
                  with DbError.runToResult;
                assertEq(expected = Ok("committed" :: Nil), labelsRes);
                Sqlite.close(db)
        }
    }

    @Test
    def testSqliteMigrationsIdempotent(): Unit \ {Assert, IO} = {
        let migs =
            Migration.make(2, "add_email_index", "CREATE UNIQUE INDEX idx_users_email ON users(email)") ::
            Migration.make(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL)") ::
            Nil;

        let res = run {
            Sqlite.withDb(SqliteConfig.inMemory(), () -> {
                // Out-of-order input list should apply in ascending version order [1, 2]
                let firstRun = Migration.runAll(migs);
                assertEq(expected = 1 :: 2 :: Nil, firstRun);

                // Second run is a clean idempotent no-op
                let secondRun = Migration.runAll(migs);
                assertEq(expected = Nil, secondRun)
            })
        } with DbError.runToResult;

        match res {
            case Ok(Ok(()))       => ()
            case Ok(Err(e))       => Assert.fail("Open failed: ${e}")
            case Err((kind, msg)) => Assert.fail("Migration failed (${kind}): ${msg}")
        }
    }

    @Test
    def testDbErrorToHttpMiddlewareMapsConstraintTo409(): Unit \ {Assert, IO} = {
        match Sqlite.open(SqliteConfig.inMemory()) {
            case Err(e) => Assert.fail(e)
            case Ok(db) =>
                let _ = run {
                    Db.executeSql("CREATE TABLE tags (name TEXT PRIMARY KEY)")
                } with Sqlite.runWith(db)
                  with DbError.runToResult;

                let app = Router.empty()
                    |> Router.post("/tags", () -> {
                        let body = Req.jsonBody();
                        let name = Json.requireNonEmptyString("name", body);
                        let _ = Db.execute("INSERT INTO tags (name) VALUES (?)", SqlValue.text(name) :: Nil);
                        Response.created(name)
                    })
                    |> Router.toApp
                    |> Middleware.dbErrorToHttp
                    |> Middleware.errorJson;

                let runReq = req -> run {
                    app(req)
                } with Sqlite.runWith(db)
                  with DbError.runToHttpError
                  with HttpError.runAsJson;

                let payload = Json.obj(("name", Json.str("flix")) :: Nil);
                let r1 = TestClient.postJson("/tags", payload, runReq);
                assertEq(expected = Status.created(), Response.status(r1));

                // Duplicate primary key -> ConstraintViolation -> 409 Conflict JSON!
                let r2 = TestClient.postJson("/tags", payload, runReq);
                assertEq(expected = Status.conflict(), Response.status(r2));
                assertTrue(String.contains({substr = "409"}, Response.body(r2)));
                Sqlite.close(db)
        }
    }

    @Test
    def testSqliteFilePersistenceAcrossReopen(): Unit \ {Assert, IO} = {
        let tmpPath = "/tmp/weft_sqlite_persist_test.db";
        let f = new File(tmpPath);
        if (f.exists()) { let _ = f.delete(); () } else ();

        // Session 1: open file DB, migrate, insert
        let s1 = run {
            Sqlite.withDb(SqliteConfig.file(tmpPath), () -> {
                let _ = Db.executeSql("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
                let _ = Db.execute("INSERT INTO kv (k, v) VALUES (?, ?)", SqlValue.text("lang") :: SqlValue.text("Flix") :: Nil);
                ()
            })
        } with DbError.runToResult;
        match s1 {
            case Ok(Ok(()))       => ()
            case Ok(Err(e))       => Assert.fail("Session 1 open failed: ${e}")
            case Err((kind, msg)) => Assert.fail("Session 1 failed (${kind}): ${msg}")
        };

        // Session 2: reopen same file DB and verify persisted row
        let s2 = run {
            Sqlite.withDb(SqliteConfig.file(tmpPath), () -> {
                Db.queryOneMap("SELECT v FROM kv WHERE k = ?", SqlValue.text("lang") :: Nil, r -> Row.requireString("v", r))
            })
        } with DbError.runToResult;
        assertEq(expected = Ok(Ok(Some("Flix"))), s2);

        // Cleanup temp file (and WAL/SHM sidecars if created)
        let _ = f.delete();
        let _ = (new File("${tmpPath}-wal")).delete();
        let _ = (new File("${tmpPath}-shm")).delete();
        ()
    }

}
