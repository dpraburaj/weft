mod HelloApp {
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Cookie
    use weft::Weft.HttpError
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.Req
    use weft::Weft.Res
    use weft::Weft.Router
    use weft::Weft.Status
    use weft::Weft.WithStatus

    ///
    /// GET /hello/:name?loud=true
    ///
    def greet(): Json \ {Req, HttpError} = {
        let name = Req.requireParam("name");
        let loud = Req.queryParam("loud") == Some("true");
        let raw = "Hello, ${name}!";
        let message = if (loud) String.toUpperCase(raw) else raw;
        Json.obj(
            ("message", Json.str(message)) ::
            ("loud", Json.bool(loud)) ::
            Nil
        )
    }

    ///
    /// POST /echo  {"text": "..."}
    ///
    def echo(): WithStatus[Json] \ {Req, HttpError} = {
        let body = Req.jsonBody();
        let text = Json.requireNonEmptyString("text", body);
        WithStatus.WithStatus(
            Status.created(),
            Json.obj(
                ("echo", Json.str(text)) ::
                ("length", Json.int(String.length(text))) ::
                Nil
            )
        )
    }

    ///
    /// GET /theme/:mode — demonstrates ambient response headers & cookies via `Res`.
    ///
    def setTheme(): Json \ {Req, Res, HttpError} = {
        let mode = Req.requireParam("mode");
        HttpError.ensure(
            mode == "light" or mode == "dark",
            Status.badRequest(),
            "Theme must be 'light' or 'dark'"
        );
        Res.setCookie(Cookie.make("theme", mode) |> Cookie.withMaxAge(86400));
        Res.setHeader("X-Theme", mode);
        Json.obj(("theme", Json.str(mode)) :: Nil)
    }

    ///
    /// Builds the HTTP application with effect row `{Logger, Clock}` (no `IO`!).
    /// Because `IO` is absent, this exact app can be tested 100% purely.
    ///
    pub def buildApp(): App[{Logger, Clock}] =
        Router.empty()
            |> Router.get("/health", () -> Json.obj(("status", Json.str("ok")) :: Nil))
            |> Router.get("/hello/:name", greet)
            |> Router.post("/echo", echo)
            |> Router.get("/theme/:mode", setTheme)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.timingHeader
            |> Middleware.requestLogger

}

def main(): Unit \ IO = {
    use Time.Clock;
    use weft::Weft.App;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;

    let app = HelloApp.buildApp();
    let ioApp: App[IO] = req ->
        run {
            app(req)
        } with Logger.runWithIO
          with Clock.runWithIO;

    println("Starting Weft Hello World server on http://127.0.0.1:8080");
    println("Try:");
    println("  curl http://127.0.0.1:8080/health");
    println("  curl 'http://127.0.0.1:8080/hello/Flix?loud=true'");
    println("  curl -X POST http://127.0.0.1:8080/echo -H 'Content-Type: application/json' -d '{\"text\":\"hi weft\"}'");
    println("  curl -i http://127.0.0.1:8080/theme/dark");

    match Server.serve(ServerConfig.local(8080), ioApp) {
        case Ok(())   => ()
        case Err(msg) => println("Server error: ${msg}")
    }
}
