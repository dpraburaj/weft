mod TestDbPoolingAndPostgres {
    use Assert.assertEq
    use Assert.assertFalse
    use Assert.assertTrue
    use Weft.Db
    use Weft.Db.ConnectionPool
    use Weft.Db.Jdbc
    use Weft.Db.PoolConfig
    use Weft.Db.PoolStats
    use Weft.Db.Postgres
    use Weft.Db.PostgresConfig
    use Weft.Db.Sqlite
    use Weft.Db.SqliteConfig
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.Json
    use Weft.Row
    use Weft.SqlValue

    import java.io.{File => JFile}
    import java.lang.Runnable
    import java.lang.System
    import java.lang.Thread
    import java.sql.SQLException
    import java.util.Properties
    import java.util.concurrent.CountDownLatch
    import java.util.concurrent.TimeUnit
    import org.sqlite.JDBC

    def makeTempDbPath(tag: String): String \ IO = {
        let dir = System.getProperty("java.io.tmpdir");
        let f = new JFile(dir, "weft-${tag}-${System.nanoTime()}.db");
        f.getAbsolutePath()
    }

    def cleanupSqliteFiles(path: String): Unit \ IO = {
        let _ = (new JFile(path)).delete();
        let _ = (new JFile("${path}-wal")).delete();
        let _ = (new JFile("${path}-shm")).delete();
        ()
    }

    // =========================================================================
    // 1. Generic ConnectionPool: Pre-warm, Borrow/Release, Timeout, Discard, Stats
    // =========================================================================

    @Test
    def testConnectionPoolLifecycleTimeoutDiscardAndStats(): Unit \ {Assert, IO} = {
        let dbPath = makeTempDbPath("pool");
        let jdbcUrl = "jdbc:sqlite:${dbPath}";
        let factory = () -> {
            let driver = new JDBC();
            let conn = driver.connect(jdbcUrl, new Properties());
            Ok(conn)
        };
        let cfg = PoolConfig.make(2)
            |> PoolConfig.withMinIdle(1)
            |> PoolConfig.withAcquireTimeoutMs(80i64)
            |> PoolConfig.withValidationTimeoutSec(0);

        match ConnectionPool.open(cfg, factory) {
            case Err(msg) =>
                cleanupSqliteFiles(dbPath);
                Assert.fail("Failed to open ConnectionPool: ${msg}")
            case Ok(pool) =>
                let s0 = ConnectionPool.stats(pool);
                assertEq(expected = 2, PoolStats.maxConnections(s0));
                assertEq(expected = 0, PoolStats.activeConnections(s0));
                assertEq(expected = 1, PoolStats.idleConnections(s0));
                assertEq(expected = 1i64, PoolStats.totalCreated(s0));
                assertFalse(PoolStats.isClosed(s0));
                assertEq(expected = Some(2), Option.flatMap(Json.asInt, Json.getField("maxConnections", PoolStats.toJson(s0))));

                // Borrow 2 connections (reuses 1 pre-warmed, creates 1 new)
                let c1 = match ConnectionPool.borrow(pool) {
                    case Ok(c) => c
                    case Err((_, e)) => Assert.fail("Borrow 1 failed: ${e}"); unreachable!()
                };
                let c2 = match ConnectionPool.borrow(pool) {
                    case Ok(c) => c
                    case Err((_, e)) => Assert.fail("Borrow 2 failed: ${e}"); unreachable!()
                };
                let s1 = ConnectionPool.stats(pool);
                assertEq(expected = 2, PoolStats.activeConnections(s1));
                assertEq(expected = 0, PoolStats.idleConnections(s1));
                assertEq(expected = 2i64, PoolStats.totalCreated(s1));

                // 3rd borrow times out cleanly
                match ConnectionPool.borrow(pool) {
                    case Err((DbErrorKind.ConnectionFailed, msg)) =>
                        assertTrue(String.contains({substr = "Timed out"}, msg))
                    case _ =>
                        Assert.fail("Expected ConnectionFailed timeout when pool exhausted")
                };

                // Release c1 -> returned to idle and reused on next borrow (totalCreated stays 2)
                ConnectionPool.release(pool, c1);
                assertEq(expected = 1, PoolStats.activeConnections(ConnectionPool.stats(pool)));
                assertEq(expected = 1, PoolStats.idleConnections(ConnectionPool.stats(pool)));

                let c1Again = match ConnectionPool.borrow(pool) {
                    case Ok(c) => c
                    case Err((_, e)) => Assert.fail("Borrow reuse failed: ${e}"); unreachable!()
                };
                assertEq(expected = 2i64, PoolStats.totalCreated(ConnectionPool.stats(pool)));

                // Evict c2 -> closes it and frees permit so next borrow opens a fresh connection (#3)
                ConnectionPool.evict(pool, c2);
                let c3 = match ConnectionPool.borrow(pool) {
                    case Ok(c) => c
                    case Err((_, e)) => Assert.fail("Borrow replacement failed: ${e}"); unreachable!()
                };
                assertEq(expected = 3i64, PoolStats.totalCreated(ConnectionPool.stats(pool)));

                ConnectionPool.release(pool, c1Again);
                ConnectionPool.release(pool, c3);
                ConnectionPool.close(pool);
                assertTrue(PoolStats.isClosed(ConnectionPool.stats(pool)));

                // Closed pool rejects future borrows
                match ConnectionPool.borrow(pool) {
                    case Err((DbErrorKind.ConnectionFailed, _)) => ()
                    case _ => Assert.fail("Expected ConnectionFailed on closed pool")
                };
                cleanupSqliteFiles(dbPath)
        }
    }

    // =========================================================================
    // 2. Shared Pooled JDBC Engine: Pinning, Nested Savepoints, Leak Cleanup & SQLSTATE
    // =========================================================================

    @Test
    def testJdbcRunPooledDbTransactionsSavepointsLeakCleanupAndSqlState(): Unit \ {Assert, IO} = {
        // SQLSTATE classification unit checks (PostgreSQL & standard SQLSTATE codes)
        assertEq(
            expected = DbErrorKind.ConstraintViolation,
            fst(Jdbc.classifySqlException(new SQLException("duplicate key value violates unique constraint", "23505")))
        );
        assertEq(
            expected = DbErrorKind.ConnectionFailed,
            fst(Jdbc.classifySqlException(new SQLException("connection failure", "08006")))
        );
        assertEq(
            expected = DbErrorKind.TransactionFailed,
            fst(Jdbc.classifySqlException(new SQLException("could not serialize access", "40001")))
        );
        assertEq(
            expected = DbErrorKind.QueryFailed,
            fst(Jdbc.classifySqlException(new SQLException("undefined table", "42P01")))
        );

        let dbPath = makeTempDbPath("pooled-jdbc");
        let jdbcUrl = "jdbc:sqlite:${dbPath}";
        let factory = () -> {
            let driver = new JDBC();
            let conn = driver.connect(jdbcUrl, new Properties());
            let st = conn.createStatement();
            let _ = st.execute("PRAGMA journal_mode = WAL");
            let _ = st.execute("PRAGMA busy_timeout = 5000");
            Jdbc.safeCloseStmt(st);
            Ok(conn)
        };
        let cfg = PoolConfig.make(4) |> PoolConfig.withMinIdle(1) |> PoolConfig.withValidationTimeoutSec(0);

        match ConnectionPool.open(cfg, factory) {
            case Err(msg) =>
                cleanupSqliteFiles(dbPath);
                Assert.fail("Failed to open pool: ${msg}")
            case Ok(pool) =>
                let res = DbError.runToResult(() ->
                    Jdbc.runPooledDb(true, Jdbc.doInsertAndGetIdSqlite, pool, () -> {
                        let _ = Db.executeSql("CREATE TABLE accounts (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)");
                        let id1 = Db.insertAndGetId("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("alice") :: Nil);
                        assertEq(expected = 1i64, id1);

                        // Nested savepoint isolates inner duplicate-key error
                        Db.transaction(() -> {
                            let _ = Db.execute("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("bob") :: Nil);
                            let innerErr = DbError.runToResult(() ->
                                Db.transaction(() -> {
                                    let _ = Db.execute("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("charlie") :: Nil);
                                    let _ = Db.execute("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("alice") :: Nil);
                                    ()
                                })
                            );
                            match innerErr {
                                case Err((DbErrorKind.ConstraintViolation, _)) => ()
                                case _ => Assert.fail("Expected ConstraintViolation inside nested savepoint")
                            };
                            let _ = Db.execute("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("dave") :: Nil);
                            ()
                        });

                        let names = Db.queryMap("SELECT name FROM accounts ORDER BY name ASC", Nil, Row.requireString("name"));
                        assertEq(expected = "alice" :: "bob" :: "dave" :: Nil, names)
                    })
                );
                assertTrue(Result.isOk(res));

                // Uncommitted manual beginTx is automatically rolled back & returned on scope exit (zero leaks!)
                let _ = DbError.runToResult(() ->
                    Jdbc.runPooledDb(true, Jdbc.doInsertAndGetIdSqlite, pool, () -> {
                        Db.beginTx();
                        let _ = Db.execute("INSERT INTO accounts (name) VALUES (?)", SqlValue.text("leaked") :: Nil);
                        ()
                    })
                );
                assertEq(expected = 0, PoolStats.activeConnections(ConnectionPool.stats(pool)));
                let namesAfter = DbError.runToResult(() ->
                    Jdbc.runPooledDb(true, Jdbc.doInsertAndGetIdSqlite, pool, () ->
                        Db.queryMap("SELECT name FROM accounts ORDER BY name ASC", Nil, Row.requireString("name"))
                    )
                );
                assertEq(expected = Ok("alice" :: "bob" :: "dave" :: Nil), namesAfter);

                ConnectionPool.close(pool);
                cleanupSqliteFiles(dbPath)
        }
    }

    // =========================================================================
    // 3. SQLite WAL Concurrent Reader Pool (Parallel Reads During Open Write Tx!)
    // =========================================================================

    @Test
    def testSqliteWalConcurrentReaderPoolAndInTxReadYourWrites(): Unit \ {Assert, IO} = {
        let dbPath = makeTempDbPath("wal-readers");
        let cfg = SqliteConfig.file(dbPath) |> SqliteConfig.withReadPoolSize(4);

        match Sqlite.open(cfg) {
            case Err(msg) =>
                cleanupSqliteFiles(dbPath);
                Assert.fail("Failed to open WAL SQLite DB: ${msg}")
            case Ok(db) =>
                // Reader pool is active and ping succeeds
                match Sqlite.readerPoolStats(db) {
                    case None => Assert.fail("Expected WAL reader pool stats")
                    case Some(st) => assertEq(expected = 4, PoolStats.maxConnections(st))
                };
                assertEq(expected = Ok(()), Sqlite.ping(db));

                // Seed initial row
                let seedRes = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                    let _ = Db.executeSql("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL)");
                    let _ = Db.execute("INSERT INTO items (title) VALUES (?)", SqlValue.text("initial") :: Nil);
                    ()
                }));
                assertTrue(Result.isOk(seedRes));

                // Open a write transaction on thread A and hold it open while thread B reads concurrently via WAL reader pool!
                let txStarted = new CountDownLatch(1);
                let readerDone = new CountDownLatch(1);
                let inTxCountRef = Ref.fresh(Static, 0);
                let concurrentReadCountRef = Ref.fresh(Static, -1);

                let writerTask = new Runnable {
                    def $run(_this: Runnable): Unit \ IO = {
                        let _ = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                            Db.transaction(() -> {
                                let _ = Db.execute("INSERT INTO items (title) VALUES (?)", SqlValue.text("uncommitted") :: Nil);
                                // Inside the write tx, reads route to writer conn and see uncommitted row (count == 2)
                                let cnt = Db.queryOneMap("SELECT COUNT(*) AS c FROM items", Nil, Row.requireInt("c"))
                                    |> Option.getWithDefault(0);
                                Ref.put(cnt, inTxCountRef);
                                txStarted.countDown();
                                // Wait for concurrent reader to finish BEFORE committing!
                                let _ = readerDone.await(5i64, TimeUnit.SECONDS);
                                ()
                            })
                        ));
                        ()
                    }
                };
                let writerThread = Thread.ofVirtual().start(writerTask);

                assertTrue(txStarted.await(5i64, TimeUnit.SECONDS));

                // Concurrent read on main thread runs through WAL reader pool WITHOUT blocking on writerThread's lock!
                // Because writer hasn't committed yet, WAL snapshot isolation returns count == 1!
                let readRes = DbError.runToResult(() -> Sqlite.runWith(db, () -> {
                    let cnt = Db.queryOneMap("SELECT COUNT(*) AS c FROM items", Nil, Row.requireInt("c"))
                        |> Option.getWithDefault(-1);
                    Ref.put(cnt, concurrentReadCountRef)
                }));
                assertTrue(Result.isOk(readRes));
                readerDone.countDown();
                writerThread.join(5000i64);

                assertEq(expected = 2, Ref.get(inTxCountRef));
                assertEq(expected = 1, Ref.get(concurrentReadCountRef));

                // After commit, WAL reader pool observes both committed rows!
                let afterRes = DbError.runToResult(() -> Sqlite.runWith(db, () ->
                    Db.queryOneMap("SELECT COUNT(*) AS c FROM items", Nil, Row.requireInt("c"))
                        |> Option.getWithDefault(0)
                ));
                assertEq(expected = Ok(2), afterRes);

                Sqlite.close(db);
                cleanupSqliteFiles(dbPath)
        }
    }

    // =========================================================================
    // 4. PostgreSQL Config Parsing & Driver Error Handling
    // =========================================================================

    @Test
    def testPostgresConfigDatabaseUrlParsingAndDriverLoading(): Unit \ {Assert, IO} = {
        match PostgresConfig.fromDatabaseUrl("postgres://alice:s3cr%3At@db.example.com:5433/weft_prod?sslmode=require") {
            case Err(e) => Assert.fail("Expected valid DATABASE_URL, got: ${e}")
            case Ok(cfg) =>
                assertEq(expected = "jdbc:postgresql://db.example.com:5433/weft_prod?sslmode=require", PostgresConfig.jdbcUrl(cfg));
                assertEq(expected = "alice", PostgresConfig.username(cfg));
                assertEq(expected = "s3cr:t", PostgresConfig.password(cfg));
                assertEq(expected = Some("require"), PostgresConfig.sslMode(cfg))
        };

        match PostgresConfig.fromDatabaseUrl("postgresql://localhost/myapp") {
            case Err(e) => Assert.fail("Expected valid postgresql:// URL, got: ${e}")
            case Ok(cfg) =>
                assertEq(expected = "jdbc:postgresql://localhost:5432/myapp", PostgresConfig.jdbcUrl(cfg));
                assertEq(expected = "", PostgresConfig.username(cfg));
                assertEq(expected = None, PostgresConfig.sslMode(cfg))
        };

        assertTrue(Result.isErr(PostgresConfig.fromDatabaseUrl("mysql://localhost/app")));
        assertTrue(Result.isErr(PostgresConfig.fromDatabaseUrl("postgres://localhost/")));

        let customCfg = PostgresConfig.local("weft_dev", "postgres", "secret")
            |> PostgresConfig.withMaxConnections(20)
            |> PostgresConfig.withMinIdle(4)
            |> PostgresConfig.withApplicationName("weft-api")
            |> PostgresConfig.withSslMode("prefer");
        assertEq(expected = 20, PoolConfig.maxConnections(PostgresConfig.poolConfig(customCfg)));
        assertEq(expected = 4, PoolConfig.minIdle(PostgresConfig.poolConfig(customCfg)));
        assertEq(expected = "weft-api", PostgresConfig.applicationName(customCfg));

        // Verify org.postgresql.Driver loads and returns clean Err against closed local port
        let unreachableCfg = PostgresConfig.make("127.0.0.1", 1, "weft_nope", "postgres", "postgres")
            |> PostgresConfig.withMinIdle(1)
            |> PostgresConfig.withConnectTimeoutSec(1);
        match Postgres.open(unreachableCfg) {
            case Err(msg) =>
                assertTrue(String.contains({substr = "Failed to connect to PostgreSQL"}, msg))
            case Ok(db) =>
                Postgres.close(db);
                Assert.fail("Expected connection failure on closed port 1")
        }
    }

}
