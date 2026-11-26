mod TestHello {
    use Assert.assertEq
    use Assert.assertTrue
    use Logger.Severity
    use weft::Weft.Json
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestClient
    use weft::Weft.TestEffects

    @Test
    def testGreetingAndDeterministicLogging(): Unit \ Assert = {
        let app = HelloApp.buildApp();

        // 100% pure test: zero IO, deterministic stepping clock, captured logs!
        let (res, logs) = run {
            TestClient.get("/hello/Flix?loud=true", app)
        } with TestEffects.runCollectingLogger
          with TestEffects.runSteppingClock(1000i64, 5i64);

        assertEq(expected = Status.ok(), Response.status(res));
        assertEq(expected = Some("5ms"), Response.header("X-Response-Time", res));
        assertEq(
            expected = Ok(Json.obj(("message", Json.str("HELLO, FLIX!")) :: ("loud", Json.bool(true)) :: Nil)),
            Json.parse(Response.body(res))
        );
        assertEq(expected = (Severity.Info, "GET /hello/Flix -> 200 OK (15ms)") :: Nil, logs)
    }

    @Test
    def testEchoAndValidationErrors(): Unit \ Assert = {
        let app = HelloApp.buildApp();

        let okRes = run {
            TestClient.postJson("/echo", Json.obj(("text", Json.str("algebraic effects")) :: Nil), app)
        } with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(0i64);

        assertEq(expected = Status.created(), Response.status(okRes));
        assertEq(
            expected = Ok(Json.obj(("echo", Json.str("algebraic effects")) :: ("length", Json.int(17)) :: Nil)),
            Json.parse(Response.body(okRes))
        );

        let badRes = run {
            TestClient.postJson("/echo", Json.obj(("text", Json.str("   ")) :: Nil), app)
        } with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(0i64);

        assertEq(expected = Status.badRequest(), Response.status(badRes));
        assertTrue(String.contains({substr = "must not be empty"}, Response.body(badRes)))
    }

    @Test
    def testAmbientThemeCookie(): Unit \ Assert = {
        let app = HelloApp.buildApp();

        let res = run {
            TestClient.get("/theme/dark", app)
        } with TestEffects.runSilentLogger
          with TestEffects.runFixedClock(0i64);

        assertEq(expected = Status.ok(), Response.status(res));
        assertEq(expected = Some("dark"), Response.header("X-Theme", res));
        assertTrue(Option.nonEmpty(Response.header("Set-Cookie", res)))
    }

}
