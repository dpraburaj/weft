pub mod Weft.Req {
    use Weft.Body
    use Weft.Headers
    use Weft.HttpError
    use Weft.Json
    use Weft.Method
    use Weft.Multipart
    use Weft.MultipartForm
    use Weft.Req
    use Weft.Request
    use Weft.Status

    ///
    /// Algebraic effect providing ambient read access to the current HTTP `Request`.
    ///
    pub eff Req {
        def request(): Request
    }

    // --- Ambient Readers ---

    pub def current(): Request \ Req                           = Req.request()
    pub def method(): Method \ Req                             = Request.method(Req.request())
    pub def path(): String \ Req                               = Request.path(Req.request())
    pub def rawQuery(): String \ Req                           = Request.rawQuery(Req.request())
    pub def bodyValue(): Body \ Req                            = Request.bodyValue(Req.request())
    pub def body(): String \ Req                               = Request.body(Req.request())
    pub def bodyBytes(): Vector[Int8] \ Req                    = Request.bodyBytes(Req.request())
    pub def bodyLength(): Int32 \ Req                          = Request.bodyLength(Req.request())
    pub def headers(): Headers \ Req                           = Request.headers(Req.request())
    pub def header(name: String): Option[String] \ Req         = Request.header(name, Req.request())
    pub def contentType(): Option[String] \ Req                = Request.contentType(Req.request())
    pub def queryParams(): Map[String, String] \ Req           = Request.queryParams(Req.request())
    pub def queryParamsAll(): Map[String, List[String]] \ Req  = Request.queryParamsAll(Req.request())
    pub def queryParam(name: String): Option[String] \ Req     = Request.queryParam(name, Req.request())
    pub def queryParamAll(name: String): List[String] \ Req    = Request.queryParamAll(name, Req.request())
    pub def params(): Map[String, String] \ Req                = Request.params(Req.request())
    pub def param(name: String): Option[String] \ Req          = Request.param(name, Req.request())
    pub def cookies(): Map[String, String] \ Req               = Request.cookies(Req.request())
    pub def cookie(name: String): Option[String] \ Req         = Request.cookie(name, Req.request())
    pub def signedCookie(secret: String, name: String): Option[String] \ Req =
        cookie(name) |> Option.flatMap(Weft.Cookie.verifySigned(secret))
    pub def bearerToken(): Option[String] \ Req                = Request.bearerToken(Req.request())

    // --- Validating Extractors (`Req` + `HttpError`) ---

    pub def requireParam(name: String): String \ {Req, HttpError} =
        param(name) |> HttpError.orBadRequest("Missing path parameter '${name}'")

    pub def requireIntParam(name: String): Int32 \ {Req, HttpError} =
        let raw = requireParam(name);
        Int32.fromString(raw)
            |> HttpError.orBadRequest("Path parameter '${name}' must be an integer, got '${raw}'")

    pub def requireInt64Param(name: String): Int64 \ {Req, HttpError} =
        let raw = requireParam(name);
        Int64.fromString(raw)
            |> HttpError.orBadRequest("Path parameter '${name}' must be a 64-bit integer, got '${raw}'")

    pub def requireQuery(name: String): String \ {Req, HttpError} =
        queryParam(name) |> HttpError.orBadRequest("Missing query parameter '${name}'")

    pub def requireIntQuery(name: String): Int32 \ {Req, HttpError} =
        let raw = requireQuery(name);
        Int32.fromString(raw)
            |> HttpError.orBadRequest("Query parameter '${name}' must be an integer, got '${raw}'")

    pub def requireInt64Query(name: String): Int64 \ {Req, HttpError} =
        let raw = requireQuery(name);
        Int64.fromString(raw)
            |> HttpError.orBadRequest("Query parameter '${name}' must be a 64-bit integer, got '${raw}'")

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

    // --- URL-Encoded Form Extractors (`application/x-www-form-urlencoded`) ---

    ///
    /// Parses an `application/x-www-form-urlencoded` body into `Map[String, List[String]]`.
    /// Raises `415 Unsupported Media Type` if a different `Content-Type` header is explicitly sent.
    ///
    pub def formParamsAll(): Map[String, List[String]] \ {Req, HttpError} = {
        ensureUrlEncodedForm();
        Request.formParamsAll(Req.request())
    }

    ///
    /// Parses an `application/x-www-form-urlencoded` body into `Map[String, String]` (last value wins).
    /// Raises `415 Unsupported Media Type` if a different `Content-Type` header is explicitly sent.
    ///
    pub def formParams(): Map[String, String] \ {Req, HttpError} = {
        ensureUrlEncodedForm();
        Request.formParams(Req.request())
    }

    pub def formFieldAll(name: String): List[String] \ {Req, HttpError} =
        Map.getWithDefault(name, Nil, formParamsAll())

    pub def optionalFormField(name: String): Option[String] \ {Req, HttpError} =
        Map.get(name, formParams())

    pub def requireFormField(name: String): String \ {Req, HttpError} =
        optionalFormField(name)
            |> HttpError.orBadRequest("Missing required form field '${name}'")

    pub def requireNonEmptyFormField(name: String): String \ {Req, HttpError} =
        let v = String.trim(requireFormField(name));
        if (String.isEmpty(v))
            HttpError.badRequest("Form field '${name}' must not be empty")
        else
            v

    pub def requireIntFormField(name: String): Int32 \ {Req, HttpError} =
        let raw = requireFormField(name);
        Int32.fromString(raw)
            |> HttpError.orBadRequest("Form field '${name}' must be an integer, got '${raw}'")

    // --- Multipart Form Extractor (`multipart/form-data`) ---

    ///
    /// Parses the request body as `multipart/form-data` (preserving exact binary file bytes).
    /// Raises `415 Unsupported Media Type` for non-multipart requests or `400 Bad Request` if malformed.
    ///
    pub def multipartForm(): MultipartForm \ {Req, HttpError} =
        Multipart.fromReq()

    def ensureUrlEncodedForm(): Unit \ {Req, HttpError} =
        match contentType() {
            case None                                         => ()
            case Some("application/x-www-form-urlencoded")    => ()
            case Some(other) =>
                HttpError.raise(
                    Status.unsupportedMediaType(),
                    "Expected Content-Type 'application/x-www-form-urlencoded', got '${other}'"
                )
        }

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
