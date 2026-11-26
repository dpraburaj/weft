pub mod Weft.Middleware {
    use Weft.App
    use Weft.Auth
    use Weft.CorsConfig
    use Weft.Csrf
    use Weft.CsrfConfig
    use Weft.DbError
    use Weft.Handler
    use Weft.HttpError
    use Weft.Json
    use Weft.Method
    use Weft.OptionalAuth
    use Weft.Principal
    use Weft.Random
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Session
    use Weft.SessionConfig
    use Weft.SessionStore
    use Weft.Status
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

}
