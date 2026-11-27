pub mod Weft.Middleware {
    use Weft.Accept
    use Weft.App
    use Weft.Auth
    use Weft.Body
    use Weft.Compression
    use Weft.CompressionConfig
    use Weft.CorsConfig
    use Weft.Csrf
    use Weft.CsrfConfig
    use Weft.DbError
    use Weft.Handler
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.HttpError
    use Weft.Json
    use Weft.MailError
    use Weft.Method
    use Weft.OptionalAuth
    use Weft.Principal
    use Weft.Random
    use Weft.RateLimitConfig
    use Weft.RateLimitDecision
    use Weft.RateLimiter
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Session
    use Weft.SessionConfig
    use Weft.SessionStore
    use Weft.Status
    use Weft.StorageError
    use Weft.ValidationError
    use Weft.ValidationErrors
    use Time.Clock

    // --- Effect-Discharging App Middleware ---

    ///
    /// Discharges `HttpError` by rendering structured JSON error payloads.
    ///
    pub def errorJson(app: App[ef]): App[ef - HttpError] = req ->
        run {
            app(req)
        } with HttpError.runAsJson

    ///
    /// Discharges `HttpError` by rendering plain-text error payloads.
    ///
    pub def errorText(app: App[ef]): App[ef - HttpError] = req ->
        run {
            app(req)
        } with HttpError.runAsText

    ///
    /// Discharges `HttpError` by rendering HTML error pages.
    ///
    pub def errorHtml(app: App[ef]): App[ef - HttpError] = req ->
        run {
            app(req)
        } with HttpError.runAsHtml

    ///
    /// Discharges `HttpError` using a custom `(Status, String) -> Response` renderer.
    ///
    pub def errorWith(render: (Status, String) -> Response \ ef2, app: App[ef1]): App[(ef1 - HttpError) + ef2] = req ->
        run {
            app(req)
        } with HttpError.runWith(render)

    ///
    /// Discharges `HttpError` using HTTP `Accept` content negotiation:
    /// renders HTML error pages for browser requests (`Accept.prefersHtml`) and
    /// structured JSON error payloads for API clients.
    ///
    pub def errorNegotiated(app: App[ef]): App[ef - HttpError] = req ->
        if (Accept.prefersHtml(req))
            run { app(req) } with HttpError.runAsHtml
        else
            run { app(req) } with HttpError.runAsJson

    ///
    /// Like `errorNegotiated`, using custom HTML and JSON error renderers (e.g. a branded
    /// storefront error page for browsers and structured JSON for APIs).
    ///
    pub def errorNegotiatedWith(
        renderHtml: (Status, String) -> Response \ ef2,
        renderJson: (Status, String) -> Response \ ef2,
        app: App[ef1]
    ): App[(ef1 - HttpError) + ef2] = req ->
        if (Accept.prefersHtml(req))
            run { app(req) } with HttpError.runWith(renderHtml)
        else
            run { app(req) } with HttpError.runWith(renderJson)

    ///
    /// Route-level error middleware discharging `HttpError` as JSON on a specific sub-router
    /// (e.g. `/api/*` always returns JSON errors while storefront routes return HTML).
    ///
    pub def routeErrorJson(h: Handler[ef]): Handler[ef - HttpError] = () ->
        run { h() } with HttpError.runAsJson

    ///
    /// Route-level error middleware discharging `HttpError` as HTML on a specific sub-router.
    ///
    pub def routeErrorHtml(h: Handler[ef]): Handler[ef - HttpError] = () ->
        run { h() } with HttpError.runAsHtml

    ///
    /// Route-level error middleware discharging `HttpError` with a custom renderer.
    ///
    pub def routeErrorWith(
        render: (Status, String) -> Response \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - HttpError) + ef2] = () ->
        run { h() } with HttpError.runWith(render)

    ///
    /// Discharges `ValidationError` by rendering structured `422 Unprocessable Entity` JSON
    /// responses containing `"errors": { "<field>": [...] }`.
    ///
    pub def validationErrorJson(app: App[ef]): App[ef - ValidationError] = req ->
        run {
            app(req)
        } with ValidationError.runAsJson

    ///
    /// Discharges `ValidationError` with a custom `ValidationErrors -> Response` renderer.
    ///
    pub def validationErrorWith(
        render: ValidationErrors -> Response \ ef2,
        app: App[ef1]
    ): App[(ef1 - ValidationError) + ef2] = req ->
        run {
            app(req)
        } with ValidationError.runWith(render)

    ///
    /// Discharges `DbError` by translating database errors into `HttpError`:
    /// - `ConstraintViolation` -> `409 Conflict`
    /// - other database failures -> `500 Internal Server Error`
    ///
    /// Place before `Middleware.errorJson` (or `Middleware.errorText`) so database
    /// failures are formatted identically to all other HTTP errors.
    ///
    pub def dbErrorToHttp(app: App[ef]): App[(ef - DbError) + HttpError] = req ->
        run {
            app(req)
        } with DbError.runToHttpError

    ///
    /// Production-safe `DbError` middleware: logs full DB details via `Logger` and returns
    /// redacted `409` / `500` `HttpError` responses without leaking internal SQL/schema messages.
    ///
    pub def dbErrorToHttpSafe(app: App[ef]): App[(ef - DbError) + {HttpError, Logger}] = req ->
        run {
            app(req)
        } with DbError.runToHttpErrorSafe

    ///
    /// Discharges `StorageError` by translating storage failures into `HttpError`
    /// (`NotFound` -> `404`, `InvalidPath` -> `400`, `PermissionDenied` -> `403`, `IoError` -> `500`).
    ///
    pub def storageErrorToHttp(app: App[ef]): App[(ef - StorageError) + HttpError] = req ->
        run {
            app(req)
        } with StorageError.runToHttpError

    ///
    /// Discharges `MailError` by translating mail delivery failures into `502 Bad Gateway` via `HttpError`.
    ///
    pub def mailErrorToHttp(app: App[ef]): App[(ef - MailError) + HttpError] = req ->
        run {
            app(req)
        } with MailError.runToHttpError

    ///
    /// Discharges Flix's standard `Abort` effect, converting any abort into a
    /// `500 Internal Server Error` JSON response.
    ///
    pub def recoverAbort(app: App[ef]): App[ef - Abort] = req ->
        match Abort.runWithResult(() -> app(req)) {
            case Ok(res)  => res
            case Err(msg) =>
                let payload = Json.obj(
                    ("status", Json.int(500)) ::
                    ("reason", Json.str("Internal Server Error")) ::
                    ("error",  Json.str(RichString.toString(msg))) ::
                    Nil
                );
                Json.toResponseWithStatus(Status.internalServerError(), payload)
        }

    ///
    /// Discharges Flix's standard `Abort` effect, logging the abort reason via `Logger`
    /// and returning an `Accept`-negotiated redacted `500 Internal Server Error` response
    /// (HTML for browsers, JSON for API clients).
    ///
    pub def recoverAbortNegotiated(app: App[ef]): App[(ef - Abort) + Logger] = req ->
        match Abort.runWithResult(() -> app(req)) {
            case Ok(res) => res
            case Err(msg) =>
                Logger.fatal("Request aborted on ${Request.method(req)} ${Request.path(req)}: ${RichString.toString(msg)}");
                if (Accept.prefersHtml(req)) {
                    let doc = Html.page("500 Internal Server Error", () ->
                        Html.main_(() -> {
                            Html.h1Text("500 Internal Server Error");
                            Html.pText("An unexpected error occurred.")
                        })
                    );
                    HtmlDoc.toResponseWithStatus(Status.internalServerError(), doc)
                } else {
                    let payload = Json.obj(
                        ("status", Json.int(500)) ::
                        ("reason", Json.str("Internal Server Error")) ::
                        ("error",  Json.str("Internal Server Error")) ::
                        Nil
                    );
                    Json.toResponseWithStatus(Status.internalServerError(), payload)
                }
        }

    // --- Effect-Discharging Route Middleware (for `Router.withMiddleware`) ---

    ///
    /// Route middleware that discharges the `Auth` effect by verifying a Bearer token
    /// from `Req`. Raises `401 Unauthorized` via `HttpError` if missing or invalid.
    ///
    /// Use with `Router.withMiddleware(Middleware.bearerAuth(verify))` to protect an
    /// entire sub-router while keeping public routes completely auth-free.
    ///
    pub def bearerAuth(
        verify: String -> Option[Principal] \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - Auth) + {Req, HttpError} + ef2] = () ->
        Auth.runWithBearer(verify, h)

    ///
    /// Route middleware that discharges `Auth` from the active `Session`, resolving
    /// the stored user ID via `loadUser` or raising `401 Unauthorized`.
    ///
    pub def sessionAuth(
        loadUser: String -> Option[Principal] \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - Auth) + {Session, HttpError} + ef2] = () ->
        Auth.runWithSession(loadUser, h)

    ///
    /// SSR route middleware that discharges `Auth` from the active `Session`, redirecting
    /// unauthenticated users with `303 See Other` to `loginUrl` (instead of raising `401`).
    ///
    pub def sessionAuthOrRedirect(
        loginUrl: String,
        loadUser: String -> Option[Principal] \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - Auth) + Session + ef2] = () -> {
        let pOpt = match Session.get(Auth.sessionUserIdKey()) {
            case Some(uid) => loadUser(uid)
            case None      => None
        };
        match pOpt {
            case Some(p) => Auth.runWithPrincipal(p, h)
            case None    => Response.seeOther(loginUrl)
        }
    }

    ///
    /// Route middleware that discharges `OptionalAuth` from the active `Session`
    /// without failing for anonymous visitors.
    ///
    pub def optionalSessionAuth(
        loadUser: String -> Option[Principal] \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - OptionalAuth) + Session + ef2] = () ->
        OptionalAuth.runWithSession(loadUser, h)

    ///
    /// Route middleware that discharges `OptionalAuth` from a Bearer token in `Req`
    /// (missing or invalid tokens resolve to `None`).
    ///
    pub def optionalBearerAuth(
        verify: String -> Option[Principal] \ ef2,
        h: Handler[ef1]
    ): Handler[(ef1 - OptionalAuth) + Req + ef2] = () ->
        OptionalAuth.runWithBearer(verify, h)

    ///
    /// Route middleware that enforces CSRF synchronizer-token verification against `Session`
    /// for unsafe HTTP methods (`POST`, `PUT`, `PATCH`, `DELETE`).
    /// Use on SSR sub-routers while keeping webhook/Bearer-API sub-routers CSRF-free.
    ///
    pub def csrf(cfg: CsrfConfig, h: Handler[ef]): Handler[ef + {Req, Session, HttpError}] = () -> {
        Csrf.verify(cfg);
        checked_ecast(h())
    }

    ///
    /// App-level middleware enforcing CSRF synchronizer-token verification against `Session`.
    /// Place before `errorJson`/`errorHtml` and inside `Middleware.session`.
    ///
    pub def csrfApp(cfg: CsrfConfig, app: App[ef]): App[ef + {Session, HttpError}] = req -> {
        Csrf.verifyRequest(cfg, req);
        checked_ecast(app(req))
    }

    ///
    /// App-level middleware discharging the `Session` effect using signed cookies and
    /// `SessionStore`. Place AFTER `errorJson`/`errorHtml` so flashes and session updates
    /// persist across redirects and error responses.
    ///
    pub def session(
        cfg: SessionConfig,
        app: App[ef]
    ): App[(ef - Session) + {SessionStore, Random, Clock}] =
        Session.middleware(cfg, app)

    ///
    /// Route middleware that guards a route or sub-router by requiring a specific role.
    ///
    pub def requireRole(role: String, h: Handler[ef]): Handler[ef + {Auth, HttpError}] = () -> {
        Auth.requireRole(role);
        checked_ecast(h())
    }

    ///
    /// Route middleware that rejects requests whose body exceeds `maxBytes` with
    /// `413 Payload Too Large` via `HttpError`. Useful for tightening or customizing
    /// per-subrouter body caps (e.g. 1 MiB for JSON routes, 20 MiB for uploads).
    ///
    pub def limitBodySize(maxBytes: Int32, h: Handler[ef]): Handler[ef + {Req, HttpError}] = () -> {
        let len = Req.bodyLength();
        if (len > maxBytes)
            HttpError.payloadTooLarge("Request body size (${len} bytes) exceeds limit of ${maxBytes} bytes")
        else
            checked_ecast(h())
    }

    ///
    /// App-level middleware that rejects requests whose body exceeds `maxBytes` with
    /// `413 Payload Too Large` via `HttpError`. Place before `errorJson`/`errorHtml`.
    ///
    pub def maxBodySize(maxBytes: Int32, app: App[ef]): App[ef + HttpError] = req -> {
        let len = Request.bodyLength(req);
        if (len > maxBytes)
            HttpError.payloadTooLarge("Request body size (${len} bytes) exceeds limit of ${maxBytes} bytes")
        else
            checked_ecast(app(req))
    }

    // --- Cross-Cutting HTTP Middleware (Effectful via Flix stdlib `Logger` & `Clock`) ---

    ///
    /// Logs every handled request along with status and elapsed milliseconds using
    /// Flix's standard `Logger` and `Clock` effects.
    ///
    pub def requestLogger(app: App[ef]): App[ef + {Logger, Clock}] = req -> {
        let startMs = Clock.now();
        let res = app(req);
        let elapsedMs = Clock.now() - startMs;
        let m = Request.method(req);
        let p = Request.path(req);
        let st = Response.status(res);
        let msg = "${m} ${p} -> ${st} (${elapsedMs}ms)";
        if (Status.isServerError(st))
            Logger.fatal(msg)
        else if (Status.isClientError(st))
            Logger.warn(msg)
        else
            Logger.info(msg);
        res
    }

    ///
    /// Measures request duration using Flix's `Clock` effect and injects an
    /// `X-Response-Time: <N>ms` header on the response.
    ///
    pub def timingHeader(app: App[ef]): App[ef + Clock] = req -> {
        let startMs = Clock.now();
        let res = app(req);
        let elapsedMs = Clock.now() - startMs;
        Response.withHeader("X-Response-Time", "${elapsedMs}ms", res)
    }

    ///
    /// Handles CORS preflight `OPTIONS` requests and attaches CORS response headers.
    ///
    pub def cors(cfg: CorsConfig, app: App[ef]): App[ef] = req -> {
        let CorsConfig.CorsConfig(c) = cfg;
        def applyCors(res) = {
            let r1 = res
                |> Response.withHeader("Access-Control-Allow-Origin", c#allowOrigin)
                |> Response.withHeader("Access-Control-Allow-Methods", String.intercalate(", ", c#allowMethods))
                |> Response.withHeader("Access-Control-Allow-Headers", String.intercalate(", ", c#allowHeaders));
            let r2 = if (List.isEmpty(c#exposeHeaders)) r1
                else Response.withHeader("Access-Control-Expose-Headers", String.intercalate(", ", c#exposeHeaders), r1);
            let r3 = if (c#allowCredentials)
                Response.withHeader("Access-Control-Allow-Credentials", "true", r2)
                else r2;
            match c#maxAgeSeconds {
                case Some(secs) => Response.withHeader("Access-Control-Max-Age", "${secs}", r3)
                case None       => r3
            }
        };
        if (Request.method(req) == Method.Options)
            applyCors(Response.noContent())
        else
            applyCors(app(req))
    }

    ///
    /// Attaches common defensive HTTP security headers (`X-Content-Type-Options`,
    /// `X-Frame-Options`, `Referrer-Policy`).
    ///
    pub def securityHeaders(app: App[ef]): App[ef] = req ->
        app(req)
            |> Response.withHeader("X-Content-Type-Options", "nosniff")
            |> Response.withHeader("X-Frame-Options", "DENY")
            |> Response.withHeader("Referrer-Policy", "no-referrer")

    ///
    /// Sets a static response header on every response.
    ///
    pub def addResponseHeader(name: String, value: String, app: App[ef]): App[ef] = req ->
        app(req) |> Response.withHeader(name, value)

    // --- Response Compression Middleware (Gzip / Deflate) ---

    ///
    /// Compresses eligible responses (`>= 256` bytes, compressible `Content-Type`,
    /// non-streaming) using `gzip` or `deflate` based on the request's `Accept-Encoding` header.
    ///
    pub def compress(app: App[ef]): App[ef] =
        compressWith(CompressionConfig.default(), app)

    ///
    /// Like `compress`, using a custom `CompressionConfig`.
    ///
    /// - Preserves/appends `Vary: Accept-Encoding`.
    /// - Skips `HEAD`, `204`, `304`, streaming responses (`Body.Stream`), already-encoded
    ///   responses, non-compressible media types (PNG/JPEG/ZIP/SSE), and bodies smaller
    ///   than `CompressionConfig.minBytes(cfg)`.
    /// - Weakens strong `ETag` headers (`"..."` -> `W/"..."`) per RFC 9110 when transforming the body.
    ///
    pub def compressWith(cfg: CompressionConfig, app: App[ef]): App[ef] = req -> {
        let res = app(req);
        let code = Status.code(Response.status(res));
        let skipStatus = Request.method(req) == Method.Head or code == 204 or code == 304;
        let alreadyEncoded = Option.nonEmpty(Response.header("Content-Encoding", res));
        if (skipStatus or alreadyEncoded or Response.isStream(res))
            res
        else if (not Compression.isCompressibleContentType(Response.header("Content-Type", res)))
            res
        else {
            let minB = CompressionConfig.minBytes(cfg);
            if (not Body.meetsMinBytes(minB, Response.bodyValue(res)))
                res
            else {
                match Compression.negotiateEncoding(cfg, Request.header("Accept-Encoding", req)) {
                    case None =>
                        appendVaryAcceptEncoding(res)
                    case Some(enc) =>
                        let rawBytes = Response.bodyBytes(res);
                        let rawLen = Vector.length(rawBytes);
                        let compressed = if (enc == "gzip")
                            Compression.gzip(rawBytes)
                        else
                            Compression.deflate(rawBytes);
                        if (Vector.length(compressed) >= rawLen)
                            appendVaryAcceptEncoding(res)
                        else {
                            let r1 = res
                                |> Response.withBytes(compressed)
                                |> Response.withHeader("Content-Encoding", enc)
                                |> appendVaryAcceptEncoding;
                            match Response.header("ETag", r1) {
                                case Some(et) => Response.withHeader("ETag", Compression.weakenEtag(et), r1)
                                case None     => r1
                            }
                        }
                }
            }
        }
    }

    def appendVaryAcceptEncoding(res: Response): Response =
        match Response.header("Vary", res) {
            case None =>
                Response.withHeader("Vary", "Accept-Encoding", res)
            case Some(existing) =>
                let already = String.splitOn({substr = ","}, existing)
                    |> List.exists(tok -> {
                        let t = String.toLowerCase(String.trim(tok));
                        t == "accept-encoding" or t == "*"
                    });
                if (already) res else Response.withHeader("Vary", "${existing}, Accept-Encoding", res)
        }

    // --- Rate Limiting / Throttling Middleware ---

    ///
    /// App-level rate-limiting middleware keyed by client IP (`X-Forwarded-For` first entry,
    /// `X-Real-IP`, or `"global"` fallback).
    ///
    /// Attaches `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset` to every
    /// response, and returns `429 Too Many Requests` with `Retry-After` when exceeded
    /// (content-negotiated HTML vs JSON via `Accept`).
    ///
    pub def throttle(cfg: RateLimitConfig, app: App[ef]): App[ef + {RateLimiter, Clock}] =
        throttleBy(cfg, defaultThrottleKey, app)

    ///
    /// App-level rate-limiting middleware using a custom key extractor `keyFn`
    /// (e.g. per API key, per route + IP, or per tenant).
    ///
    pub def throttleBy(
        cfg: RateLimitConfig,
        keyFn: Request -> String \ ef2,
        app: App[ef1]
    ): App[ef1 + ef2 + {RateLimiter, Clock}] = req -> {
        let key = keyFn(req);
        let decision = RateLimiter.check(cfg, key);
        if (RateLimitDecision.isAllowed(decision)) {
            let res = app(req);
            RateLimitDecision.applyHeaders(decision, res)
        } else {
            tooManyRequestsResponse(req, decision)
        }
    }

    ///
    /// Route-level rate-limiting middleware for `Router.withMiddleware`.
    /// `keyFn` may use any active effects (such as `Req` or `Auth.userId()`).
    ///
    pub def throttleRoute(
        cfg: RateLimitConfig,
        keyFn: Unit -> String \ ef2,
        h: Handler[ef1]
    ): Handler[ef1 + ef2 + {Req, RateLimiter, Clock}] = () -> {
        let key = keyFn();
        let decision = RateLimiter.check(cfg, key);
        if (RateLimitDecision.isAllowed(decision)) {
            let res = checked_ecast(h());
            RateLimitDecision.applyHeaders(decision, res)
        } else {
            tooManyRequestsResponse(Req.request(), decision)
        }
    }

    def defaultThrottleKey(req: Request): String =
        match Request.header("X-Forwarded-For", req) {
            case Some(raw) =>
                match List.head(String.splitOn({substr = ","}, raw)) {
                    case Some(first) =>
                        let trimmed = String.trim(first);
                        if (String.isEmpty(trimmed)) "global" else trimmed
                    case None => "global"
                }
            case None =>
                match Request.header("X-Real-IP", req) {
                    case Some(ip) =>
                        let trimmed = String.trim(ip);
                        if (String.isEmpty(trimmed)) "global" else trimmed
                    case None => "global"
                }
        }

    def tooManyRequestsResponse(req: Request, decision: RateLimitDecision): Response = {
        let secs = RateLimitDecision.retryAfterSeconds(decision);
        let msg = "Too many requests. Please retry after ${secs}s.";
        let base = if (Accept.prefersHtml(req)) {
            let doc = Html.page("429 Too Many Requests", () ->
                Html.main_(() -> {
                    Html.h1Text("429 Too Many Requests");
                    Html.pText(msg)
                })
            );
            HtmlDoc.toResponseWithStatus(Status.tooManyRequests(), doc)
        } else {
            let payload = Json.obj(
                ("status",       Json.int(429)) ::
                ("reason",       Json.str("Too Many Requests")) ::
                ("error",        Json.str(msg)) ::
                ("retryAfterMs", Json.int64(RateLimitDecision.retryAfterMs(decision))) ::
                Nil
            );
            Json.toResponseWithStatus(Status.tooManyRequests(), payload)
        };
        RateLimitDecision.applyHeaders(decision, base)
    }

}
