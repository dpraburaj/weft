pub mod Weft.Req {
    use Weft.Headers
    use Weft.HttpError
    use Weft.Json
    use Weft.Method
    use Weft.Req
    use Weft.Request

    ///
    /// Algebraic effect providing ambient read access to the current HTTP `Request`.
    ///
    pub eff Req {
        def request(): Request
    }

    // --- Ambient Readers ---

    pub def current(): Request \ Req                   = Req.request()
    pub def method(): Method \ Req                     = Request.method(Req.request())
    pub def path(): String \ Req                       = Request.path(Req.request())
    pub def rawQuery(): String \ Req                   = Request.rawQuery(Req.request())
    pub def body(): String \ Req                       = Request.body(Req.request())
    pub def headers(): Headers \ Req                   = Request.headers(Req.request())
    pub def header(name: String): Option[String] \ Req = Request.header(name, Req.request())
    pub def queryParams(): Map[String, String] \ Req   = Request.queryParams(Req.request())
    pub def queryParam(name: String): Option[String] \ Req = Request.queryParam(name, Req.request())
    pub def params(): Map[String, String] \ Req        = Request.params(Req.request())
    pub def param(name: String): Option[String] \ Req  = Request.param(name, Req.request())
    pub def cookies(): Map[String, String] \ Req       = Request.cookies(Req.request())
    pub def cookie(name: String): Option[String] \ Req = Request.cookie(name, Req.request())
    pub def bearerToken(): Option[String] \ Req        = Request.bearerToken(Req.request())

    // --- Validating Extractors (`Req` + `HttpError`) ---

    pub def requireParam(name: String): String \ {Req, HttpError} =
        param(name) |> HttpError.orBadRequest("Missing path parameter '${name}'")

    pub def requireIntParam(name: String): Int32 \ {Req, HttpError} =
        let raw = requireParam(name);
        Int32.fromString(raw)
            |> HttpError.orBadRequest("Path parameter '${name}' must be an integer, got '${raw}'")

    pub def requireQuery(name: String): String \ {Req, HttpError} =
        queryParam(name) |> HttpError.orBadRequest("Missing query parameter '${name}'")

    pub def requireIntQuery(name: String): Int32 \ {Req, HttpError} =
        let raw = requireQuery(name);
        Int32.fromString(raw)
            |> HttpError.orBadRequest("Query parameter '${name}' must be an integer, got '${raw}'")

    pub def optionalIntQuery(name: String): Option[Int32] \ {Req, HttpError} =
        match queryParam(name) {
            case None      => None
            case Some(raw) =>
                let n = Int32.fromString(raw)
                    |> HttpError.orBadRequest("Query parameter '${name}' must be an integer, got '${raw}'");
                Some(n)
        }

    pub def requireHeader(name: String): String \ {Req, HttpError} =
        header(name) |> HttpError.orBadRequest("Missing required header '${name}'")

    pub def requireBearerToken(): String \ {Req, HttpError} =
        bearerToken() |> HttpError.orUnauthorized("Missing or invalid Bearer token")

    ///
    /// Parses the request body as JSON, or raises `400 Bad Request` via `HttpError`.
    ///
    pub def jsonBody(): Json \ {Req, HttpError} =
        Json.parseOrBadRequest(body())

    // --- Handler ---

    ///
    /// Discharges the `Req` effect by supplying `req` to every `Req.request()` call.
    ///
    pub def runWith(req: Request, f: Unit -> a \ ef): a \ (ef - Req) =
        run {
            f()
        } with handler Req {
            def request(k) = k(req)
        }

}
