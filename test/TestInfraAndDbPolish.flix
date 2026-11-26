mod TestInfraAndDbPolish {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Body
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Db
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.Env
    use Weft.HttpClient
    use Weft.HttpError
    use Weft.Job
    use Weft.JobQueue
    use Weft.JobSpec
    use Weft.JobStatus
    use Weft.JobStore
    use Weft.JobWorker
    use Weft.Json
    use Weft.Method
    use Weft.Migration
    use Weft.Page
    use Weft.Row
    use Weft.SqlBuilder
    use Weft.SqlValue
    use Weft.Status
    use Weft.TestEffects
    use Weft.Validate
    use Weft.ValidationErrors

    @Test
    def testHttpClientPureMockRecordingAndBadGateway(): Unit \ Assert = {
        let responder = req -> {
            if (ClientRequest.url(req) == "https://api.stripe.test/v1/charges") {
                Ok(ClientResponse.json(200, Json.obj(("id", Json.str("ch_123")) :: ("paid", Json.bool(true)) :: Nil)))
            } else {
                Err("connection refused")
            }
        };

        let (chargeId, sentReqs) = HttpClient.runRecording(responder, () -> {
            let req = ClientRequest.postJson(
                    "https://api.stripe.test/v1/charges",
                    Json.obj(("amount", Json.int(4999)) :: Nil)
                )
                |> ClientRequest.withBearer("sk_test_123")
                |> ClientRequest.withTimeoutMs(5000i64);
            match HttpClient.send(req) {
                case Ok(res) =>
                    assertTrue(ClientResponse.isSuccess(res));
                    match ClientResponse.parseJson(res) {
                        case Ok(j)  => Option.getWithDefault("", Option.flatMap(Json.asString, Json.getField("id", j)))
                        case Err(_) => ""
                    }
                case Err(_) => ""
            }
        });

        assertEq(expected = "ch_123", chargeId);
        assertEq(expected = 1, List.length(sentReqs));
        match List.head(sentReqs) {
            case None => Assert.fail("Expected recorded request")
            case Some(r) =>
                assertEq(expected = Method.Post, ClientRequest.method(r));
                assertEq(expected = Some("Bearer sk_test_123"), ClientRequest.header("Authorization", r));
                assertEq(expected = Some("application/json"), ClientRequest.header("Content-Type", r))
        };

        // sendOrBadGateway maps transport errors to 502 Bad Gateway
        let errRes = HttpError.runAsJson(() ->
            HttpClient.runMock(responder, () -> {
                let _ = HttpClient.sendOrBadGateway(ClientRequest.get("https://down.test/ping"));
                Weft.Response.ok("never")
            })
        );
        assertEq(expected = Status.badGateway(), Weft.Response.status(errRes))
    }

    @Test
    def testEnvDotEnvParserDefaultsAndStartupValidation(): Unit \ Assert = {
        let dotEnv =
            "# App configuration\n" +
            "PORT=9090\n" +
            "export SESSION_SECRET=\"s3cr3t-key\"\n" +
            "DEBUG='true'\n" +
            "EMPTY_VAL=\n";

        let parsed = Env.parseDotEnv(dotEnv);
        assertEq(expected = Some("9090"), Map.get("PORT", parsed));
        assertEq(expected = Some("s3cr3t-key"), Map.get("SESSION_SECRET", parsed));
        assertEq(expected = Some("true"), Map.get("DEBUG", parsed));

        // Pure Env + Validate reports all missing/invalid keys together
        let badCfg = Env.runWithMap(Map#{"PORT" => "not-a-port"}, () ->
            Validate.toResult(() -> {
                let port = Env.requireInt("PORT");
                let secret = Env.require("SESSION_SECRET");
                let db = Env.require("DATABASE_URL");
                (port, secret, db)
            })
        );
        match badCfg {
            case Ok(_) => Assert.fail("Expected missing/invalid env validation errors")
            case Err(errs) =>
                assertEq(expected = 3, ValidationErrors.count(errs));
                assertTrue(ValidationErrors.hasField("PORT", errs));
                assertTrue(ValidationErrors.hasField("SESSION_SECRET", errs));
                assertTrue(ValidationErrors.hasField("DATABASE_URL", errs))
        };

        // Valid config with defaults
        let okCfg = Env.runWithMap(parsed, () ->
            Validate.toResult(() -> {
                let port = Env.requireInt("PORT");
                let secret = Env.require("SESSION_SECRET");
                let debug = Env.getBoolOrDefault("DEBUG", false);
                let host = Env.getOrDefault("HOST", "127.0.0.1");
                (port, secret, debug, host)
            })
        );
        assertEq(expected = Ok((9090, "s3cr3t-key", true, "127.0.0.1")), okCfg)
    }

    @Test
    def testSqliteSavepointsTriggerMigrationsSqlBuilderAndPage(): Unit \ {Assert, IO} = {
        // 1. Trigger-safe and string-literal-safe SQL statement splitting
        let migSql =
            "CREATE TABLE products (id INTEGER PRIMARY KEY, sku TEXT NOT NULL UNIQUE, category TEXT NOT NULL, price_cents INTEGER NOT NULL, note TEXT);\n" +
            "CREATE TABLE audit_log (id INTEGER PRIMARY KEY, msg TEXT NOT NULL);\n" +
            "CREATE TRIGGER trg_product_insert AFTER INSERT ON products\n" +
            "BEGIN\n" +
            "  INSERT INTO audit_log (msg) VALUES ('created:' || NEW.sku || ';ok');\n" +
            "END;\n" +
            "-- comment with ; semicolon\n" +
            "INSERT INTO products (sku, category, price_cents, note) VALUES ('SKU-1', 'coffee', 1500, 'a;b');";

        let stmts = Migration.splitStatements(migSql);
        assertEq(expected = 4, List.length(stmts));

        let dbRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            let applied = Migration.runAll(Migration.make(1, "products_and_trigger", migSql) :: Nil);
            assertEq(expected = 1 :: Nil, applied);

            // Trigger fired on initial insert!
            let logs1 = Db.queryMap("SELECT msg FROM audit_log", Nil, Row.requireString("msg"));
            assertEq(expected = "created:SKU-1;ok" :: Nil, logs1);

            // 2. Nested savepoint rollback isolates inner failure without aborting outer tx
            Db.transaction(() -> {
                let _ = Db.execute(
                    "INSERT INTO products (sku, category, price_cents, note) VALUES (?, ?, ?, ?)",
                    SqlValue.text("SKU-2") :: SqlValue.text("coffee") :: SqlValue.int(2200) :: SqlValue.text("outer") :: Nil
                );
                // Inner tx inserts SKU-3 then hits duplicate SKU-1 constraint -> rolls back ONLY inner savepoint!
                let innerRes = DbError.runToResult(() ->
                    Db.transaction(() -> {
                        let _ = Db.execute(
                            "INSERT INTO products (sku, category, price_cents, note) VALUES (?, ?, ?, ?)",
                            SqlValue.text("SKU-3") :: SqlValue.text("tea") :: SqlValue.int(1200) :: SqlValue.text("inner") :: Nil
                        );
                        let _ = Db.execute(
                            "INSERT INTO products (sku, category, price_cents, note) VALUES (?, ?, ?, ?)",
                            SqlValue.text("SKU-1") :: SqlValue.text("tea") :: SqlValue.int(999) :: SqlValue.text("dup") :: Nil
                        );
                        ()
                    })
                );
                assertTrue(Result.isErr(innerRes));

                let _ = Db.execute(
                    "INSERT INTO products (sku, category, price_cents, note) VALUES (?, ?, ?, ?)",
                    SqlValue.text("SKU-4") :: SqlValue.text("tea") :: SqlValue.int(1800) :: SqlValue.text("after-sp") :: Nil
                );
                ()
            });

            // SKU-2 and SKU-4 committed; SKU-3 was rolled back by inner savepoint!
            let allSkus = Db.queryMap("SELECT sku FROM products ORDER BY sku ASC", Nil, Row.requireString("sku"));
            assertEq(expected = "SKU-1" :: "SKU-2" :: "SKU-4" :: Nil, allSkus);

            // 3. Dynamic SqlBuilder + IN clause + Page pagination
            let (inSql, inParams) = SqlBuilder.empty()
                |> SqlBuilder.appendIn("category", SqlValue.text("coffee") :: SqlValue.text("tea") :: Nil)
                |> SqlBuilder.build;

            let preds =
                (inSql, inParams) ::
                ("price_cents >= ?", SqlValue.int(1500) :: Nil) ::
                Nil;

            let (countSql, countParams) = SqlBuilder.fromSql("SELECT COUNT(*) AS cnt FROM products")
                |> SqlBuilder.appendWhere(preds)
                |> SqlBuilder.build;
            let total = Db.queryOneMap(countSql, countParams, Row.requireInt64("cnt"))
                |> Option.getWithDefault(0i64);

            let (pageSql, pageParams) = SqlBuilder.fromSql("SELECT sku FROM products")
                |> SqlBuilder.appendWhere(preds)
                |> SqlBuilder.append(" ORDER BY price_cents ASC")
                |> SqlBuilder.appendLimitOffset(2, Page.offset(1, 2))
                |> SqlBuilder.build;
            let pageItems = Db.queryMap(pageSql, pageParams, Row.requireString("sku"));
            let page = Page.make(pageItems, 1, 2, total);

            assertEq(expected = 3i64, Page.totalItems(page));
            assertEq(expected = 2, Page.totalPages(page));
            assertFalse(Page.hasPrev(page));
            assertTrue(Page.hasNext(page));
            assertEq(expected = "SKU-1" :: "SKU-4" :: Nil, Page.items(page));
            let pageJson = Page.toJson(Json.str, page);
            assertEq(expected = Some(true), Option.flatMap(Json.asBool, Json.getField("hasNext", pageJson)))
        }));
        match dbRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("SQLite savepoints/migrations/SqlBuilder test failed")
        }
    }

    @Test
    def testJobsUniqueKeyStaleRecoveryAndTransactionalOutbox(): Unit \ {Assert, IO} = {
        // 1. Pure tests: uniqueKey deduplication + stale running job recovery
        region rc {
            let nowMs = Ref.fresh(rc, 1000i64);
            run {
                let j1 = JobQueue.dispatchUnique("order:42:confirm", "email.confirm", Json.obj(("orderId", Json.int(42)) :: Nil));
                let j2 = JobQueue.dispatchUnique("order:42:confirm", "email.confirm", Json.obj(("orderId", Json.int(42)) :: Nil));
                assertEq(expected = Job.id(j1), Job.id(j2));
                assertEq(expected = 1, List.length(JobStore.listJobs(None, None)));

                // Claim job (attempts = 1/3, status = Running, updatedAt = 1000) and simulate worker crash
                let claimed = JobStore.claimNext("default", 1000i64);
                assertTrue(Option.nonEmpty(claimed));

                // Before lease timeout -> nothing reclaimed
                Ref.put(3000i64, nowMs);
                assertEq(expected = 0, JobWorker.reclaimStale(5000i64));

                // Past lease timeout -> reclaimed back to Pending!
                Ref.put(7000i64, nowMs);
                assertEq(expected = 1, JobWorker.reclaimStale(5000i64));
                match JobStore.findJob(Job.id(j1)) {
                    case Some(j) => assertEq(expected = JobStatus.Pending, Job.status(j))
                    case None    => Assert.fail("Expected reclaimed job")
                };

                // Exhaust max attempts (single-attempt job that crashes -> reclaimed straight to Dead)
                let oneShot = JobQueue.enqueue(
                    JobSpec.make("charge", Json.nullValue())
                        |> JobSpec.withMaxAttempts(1)
                        |> JobSpec.withQueue("billing")
                );
                let _ = JobStore.claimNext("billing", 7000i64);
                Ref.put(20000i64, nowMs);
                assertEq(expected = 1, JobWorker.reclaimStale(5000i64));
                match JobStore.findJob(Job.id(oneShot)) {
                    case Some(j) => assertEq(expected = JobStatus.Dead, Job.status(j))
                    case None    => Assert.fail("Expected dead reclaimed job")
                }
            } with JobQueue.runWithStore
              with JobStore.runPure
              with TestEffects.runManualClock(nowMs)
        };

        // 2. SQLite Transactional Outbox: order + job commit or roll back atomically!
        let sqlRes = DbError.runToResult(() -> Sqlite.withDb(SqliteConfig.inMemory(), () -> {
            let _ = Db.executeSql("CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, total_cents INTEGER NOT NULL)");
            JobStore.initSchema();

            // Failed checkout rolls back BOTH the order row AND the enqueued job!
            let failedRes = HttpError.runAsText(() ->
                TestEffects.runFixedClock(1000i64, () ->
                    JobQueue.runWithDb(() ->
                        Db.transactionHttp(() -> {
                            let orderId = Db.insertAndGetId("INSERT INTO orders (total_cents) VALUES (?)", SqlValue.int(5000) :: Nil);
                            let _ = JobQueue.dispatchUnique(
                                "order:${orderId}:confirm",
                                "order.confirm",
                                Json.obj(("orderId", Json.int64(orderId)) :: Nil)
                            );
                            let _: Weft.Response = HttpError.badRequest("Card declined");
                            Weft.Response.ok("never")
                        })
                    )
                )
            );
            assertEq(expected = Status.badRequest(), Weft.Response.status(failedRes));
            assertEq(expected = 0, List.length(Db.querySql("SELECT id FROM orders")));
            assertEq(expected = 0, List.length(Db.querySql("SELECT id FROM _weft_jobs")));

            // Successful checkout commits BOTH atomically + deduplicates uniqueKey!
            let okRes = HttpError.runAsText(() ->
                TestEffects.runFixedClock(2000i64, () ->
                    JobQueue.runWithDb(() ->
                        Db.transactionHttp(() -> {
                            let orderId = Db.insertAndGetId("INSERT INTO orders (total_cents) VALUES (?)", SqlValue.int(5000) :: Nil);
                            let jA = JobQueue.dispatchUnique("order:${orderId}:confirm", "order.confirm", Json.obj(("orderId", Json.int64(orderId)) :: Nil));
                            let jB = JobQueue.dispatchUnique("order:${orderId}:confirm", "order.confirm", Json.obj(("orderId", Json.int64(orderId)) :: Nil));
                            assertEq(expected = Job.id(jA), Job.id(jB));
                            Weft.Response.ok("ok")
                        })
                    )
                )
            );
            assertEq(expected = Status.ok(), Weft.Response.status(okRes));
            assertEq(expected = 1, List.length(Db.querySql("SELECT id FROM orders")));
            assertEq(expected = 1, List.length(Db.querySql("SELECT id FROM _weft_jobs")))
        }));
        match sqlRes {
            case Ok(Ok(())) => ()
            case _          => Assert.fail("SQLite transactional outbox test failed")
        }
    }

}
