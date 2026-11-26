pub mod Weft.HttpError {
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.HttpError
    use Weft.Json
    use Weft.Response
    use Weft.Status

    ///
    /// Zero-shot algebraic effect for short-circuiting HTTP error responses.
    ///
    /// Route handlers and nested helpers can call `HttpError.notFound(...)`,
    /// `HttpError.badRequest(...)`, etc. without manual `Result` plumbing.
    /// The error rendering strategy (JSON, plain text, custom HTML) is decided
    /// purely by which effect handler wraps the application.
    ///
    pub eff HttpError {
        def raise(status: Status, message: String): Void
    }

    // --- Short-Circuiting Raisers ---

    pub def badRequest(msg: String): a \ HttpError          = HttpError.raise(Status.badRequest(), msg)
    pub def unauthorized(msg: String): a \ HttpError        = HttpError.raise(Status.unauthorized(), msg)
    pub def forbidden(msg: String): a \ HttpError           = HttpError.raise(Status.forbidden(), msg)
    pub def notFound(msg: String): a \ HttpError            = HttpError.raise(Status.notFound(), msg)
    pub def methodNotAllowed(msg: String): a \ HttpError    = HttpError.raise(Status.methodNotAllowed(), msg)
    pub def conflict(msg: String): a \ HttpError             = HttpError.raise(Status.conflict(), msg)
    pub def payloadTooLarge(msg: String): a \ HttpError      = HttpError.raise(Status.payloadTooLarge(), msg)
    pub def unsupportedMediaType(msg: String): a \ HttpError = HttpError.raise(Status.unsupportedMediaType(), msg)
    pub def unprocessable(msg: String): a \ HttpError        = HttpError.raise(Status.unprocessableEntity(), msg)
    pub def tooManyRequests(msg: String): a \ HttpError     = HttpError.raise(Status.tooManyRequests(), msg)
    pub def internalError(msg: String): a \ HttpError       = HttpError.raise(Status.internalServerError(), msg)

    // --- Ergonomic Unwrappers ---

    ///
    /// Unwraps an `Option`, raising an `HttpError` with `status` and `msg` on `None`.
    ///
    pub def unwrapOr(status: Status, msg: String, opt: Option[a]): a \ HttpError =
        match opt {
            case Some(v) => v
            case None    => HttpError.raise(status, msg)
        }

    pub def orNotFound(msg: String, opt: Option[a]): a \ HttpError =
        unwrapOr(Status.notFound(), msg, opt)

    pub def orBadRequest(msg: String, opt: Option[a]): a \ HttpError =
        unwrapOr(Status.badRequest(), msg, opt)

    pub def orUnauthorized(msg: String, opt: Option[a]): a \ HttpError =
        unwrapOr(Status.unauthorized(), msg, opt)

    ///
    /// Unwraps a `Result[String, a]`, raising `status` with the error message on `Err`.
    ///
    pub def fromResult(status: Status, res: Result[String, a]): a \ HttpError =
        match res {
            case Ok(v)    => v
            case Err(msg) => HttpError.raise(status, msg)
        }

    ///
    /// Guards a condition, raising `status` with `msg` if `cond` is `false`.
    ///
    pub def ensure(cond: Bool, status: Status, msg: String): Unit \ HttpError =
        if (cond) () else HttpError.raise(status, msg)

    // --- Handlers ---

    ///
    /// Handles `HttpError` using a custom renderer `(Status, String) -> Response`.
    ///
    pub def runWith(render: (Status, String) -> Response \ ef2, f: Unit -> Response \ ef1): Response \ (ef1 - HttpError) + ef2 =
        run {
            f()
        } with handler HttpError {
            def raise(st, msg, _k) = render(st, msg)
        }

    ///
    /// Handles `HttpError` by rendering structured JSON error responses:
    /// `{"status": 404, "reason": "Not Found", "error": "..."}`.
    ///
    pub def runAsJson(f: Unit -> Response \ ef): Response \ (ef - HttpError) =
        runWith((st, msg) -> {
            let payload = Json.obj(
                ("status", Json.int(Status.code(st))) ::
                ("reason", Json.str(Status.reason(st))) ::
                ("error",  Json.str(msg)) ::
                Nil
            );
            Json.toResponseWithStatus(st, payload)
        }, f)

    ///
    /// Handles `HttpError` by rendering plain-text error responses.
    ///
    pub def runAsText(f: Unit -> Response \ ef): Response \ (ef - HttpError) =
        runWith((st, msg) ->
            Response.text(msg) |> Response.withStatus(st)
        , f)

    ///
    /// Handles `HttpError` by rendering a clean, HTML-escaped error page.
    ///
    pub def runAsHtml(f: Unit -> Response \ ef): Response \ (ef - HttpError) =
        runWith((st, msg) -> {
            let titleStr = "${Status.code(st)} ${Status.reason(st)}";
            let doc = Html.page(titleStr, () -> {
                Html.main_(() -> {
                    Html.h1Text(titleStr);
                    Html.pText(msg)
                })
            });
            HtmlDoc.toResponseWithStatus(st, doc)
        }, f)

}
