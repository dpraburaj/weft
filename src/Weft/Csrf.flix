pub mod Weft.Csrf {
    use Weft.Crypto
    use Weft.CsrfConfig
    use Weft.Html
    use Weft.HttpError
    use Weft.Method
    use Weft.Multipart
    use Weft.MultipartForm
    use Weft.Random
    use Weft.Req
    use Weft.Request
    use Weft.Session

    ///
    /// Returns the active session's CSRF token using the default `CsrfConfig`,
    /// generating and storing a fresh 32-byte token in `Session` if none exists yet.
    ///
    pub def token(): String \ {Session, Random} =
        tokenWith(CsrfConfig.default())

    ///
    /// Returns (or lazily generates and stores) the session's CSRF token using `cfg`.
    ///
    pub def tokenWith(cfg: CsrfConfig): String \ {Session, Random} = {
        let key = CsrfConfig.sessionKey(cfg);
        match Session.get(key) {
            case Some(tok) if not String.isEmpty(tok) => tok
            case _ =>
                let fresh = Random.tokenBase64Url(32);
                Session.put(key, fresh);
                fresh
        }
    }

    ///
    /// Emits `<input type="hidden" name="_csrf" value="...">` inside a `Weft.Html.form`.
    ///
    pub def hiddenInput(): Unit \ {Html, Session, Random} =
        hiddenInputWith(CsrfConfig.default())

    ///
    /// Like `hiddenInput`, using a custom `CsrfConfig`.
    ///
    pub def hiddenInputWith(cfg: CsrfConfig): Unit \ {Html, Session, Random} = {
        let tok = tokenWith(cfg);
        Html.input(() -> {
            Html.type_("hidden");
            Html.name(CsrfConfig.fieldName(cfg));
            Html.value(tok)
        })
    }

    ///
    /// Emits `<meta name="csrf-token" content="...">` inside `<head>` (ideal for HTMX/JS).
    ///
    pub def metaTag(): Unit \ {Html, Session, Random} =
        metaTagWith(CsrfConfig.default())

    ///
    /// Like `metaTag`, using a custom `CsrfConfig`.
    ///
    pub def metaTagWith(cfg: CsrfConfig): Unit \ {Html, Session, Random} = {
        let tok = tokenWith(cfg);
        Html.meta("csrf-token", tok)
    }

    ///
    /// Validates CSRF token for the current `Req` against `Session`.
    ///
    /// - Safe HTTP methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) are allowed without a token.
    /// - Unsafe methods (`POST`, `PUT`, `PATCH`, `DELETE`, ...) must present the session's
    ///   token via the configured header (`X-CSRF-Token`), URL-encoded form field (`_csrf`),
    ///   or `multipart/form-data` field (`_csrf`), verified in constant time.
    /// - Raises `403 Forbidden` via `HttpError` if missing or mismatched.
    ///
    pub def verify(cfg: CsrfConfig): Unit \ {Req, Session, HttpError} =
        verifyRequest(cfg, Req.current())

    ///
    /// Validates CSRF token for an explicit `Request` against `Session`.
    ///
    pub def verifyRequest(cfg: CsrfConfig, req: Request): Unit \ {Session, HttpError} =
        if (isSafeMethod(Request.method(req)))
            ()
        else {
            let expected = Session.get(CsrfConfig.sessionKey(cfg))
                |> HttpError.unwrapOr(Weft.Status.forbidden(), "Missing CSRF token in session");
            let submitted = extractSubmittedToken(cfg, req)
                |> HttpError.unwrapOr(Weft.Status.forbidden(), "Missing CSRF token in request");
            if (not String.isEmpty(expected) and Crypto.constantTimeEq(expected, submitted))
                ()
            else
                HttpError.forbidden("Invalid CSRF token")
        }

    // --- Internal Helpers ---

    def isSafeMethod(m: Method): Bool = match m {
        case Method.Get             => true
        case Method.Head            => true
        case Method.Options         => true
        case Method.Custom("TRACE") => true
        case _                      => false
    }

    def extractSubmittedToken(cfg: CsrfConfig, req: Request): Option[String] =
        match Request.header(CsrfConfig.headerName(cfg), req) {
            case Some(h) if not String.isEmpty(String.trim(h)) =>
                Some(String.trim(h))
            case _ =>
                let fieldName = CsrfConfig.fieldName(cfg);
                match Request.contentType(req) {
                    case Some("multipart/form-data") =>
                        match Multipart.parseRequest(req) {
                            case Ok(form) => MultipartForm.field(fieldName, form)
                            case Err(_)   => None
                        }
                    case Some("application/x-www-form-urlencoded") =>
                        Map.get(fieldName, Request.formParams(req))
                    case None =>
                        Map.get(fieldName, Request.formParams(req))
                    case _ =>
                        None
                }
        }

}
