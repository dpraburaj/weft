pub mod Weft.Router {
    use Weft.App
    use Weft.Handler
    use Weft.HttpError
    use Weft.IntoResponse
    use Weft.Method
    use Weft.Req
    use Weft.Request
    use Weft.Res
    use Weft.Response
    use Weft.Router
    use Weft.Status
    use Weft.Url

    ///
    /// An immutable, effect-polymorphic HTTP router.
    ///
    /// Adding routes automatically accumulates their effects via Boolean effect union
    /// (`ef1 + ef2`). Attaching effect-discharging middleware via `Router.withMiddleware`
    /// removes discharged effects from the router's type!
    ///
    pub enum Router[ef: Eff] {
        case Router(List[Route[ef]])
    }

    ///
    /// Compiled path pattern segment.
    ///
    enum PathSegment {
        case Literal(String)
        case Param(String)
        case Wildcard(String)
    }

    ///
    /// A single route entry carrying its compiled pattern and effect-polymorphic handler.
    /// `None` for method matches any HTTP method.
    ///
    enum Route[ef: Eff] {
        case Route(Option[Method], String, List[PathSegment], Handler[ef])
    }

    // --- Construction ---

    ///
    /// Returns an empty pure router (`Router[{}]`).
    ///
    pub def empty(): Router[{}] = Router.Router(Nil)

    ///
    /// Registers a route for a specific HTTP `method` and `pattern`.
    /// The handler may return any type implementing `IntoResponse` (`Response`, `Json`,
    /// `String`, `(Status, Json)`, `(Status, String)`, `Unit`).
    ///
    /// The resulting router's effect set is `ef1 + ef2`.
    ///
    pub def route(method: Method, pattern: String, h: Unit -> a \ ef1, router: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        addEntry(Some(method), pattern, () -> IntoResponse.intoResponse(h()), router)

    ///
    /// Registers a route matching any HTTP method.
    ///
    pub def any(pattern: String, h: Unit -> a \ ef1, router: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        addEntry(None, pattern, () -> IntoResponse.intoResponse(h()), router)

    pub def get(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Get, pattern, h, r)

    pub def post(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Post, pattern, h, r)

    pub def put(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Put, pattern, h, r)

    pub def patch(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Patch, pattern, h, r)

    pub def delete(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Delete, pattern, h, r)

    pub def options(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Options, pattern, h, r)

    pub def head(pattern: String, h: Unit -> a \ ef1, r: Router[ef2]): Router[ef1 + ef2] with IntoResponse[a] =
        route(Method.Head, pattern, h, r)

    // --- Composition & Scoping ---

    ///
    /// Merges `other` onto `base`. Routes in `base` are matched before routes in `other`.
    /// Effects of both routers are combined (`ef1 + ef2`).
    ///
    pub def merge(other: Router[ef2], base: Router[ef1]): Router[ef1 + ef2] =
        let Router.Router(rs1) = base;
        let Router.Router(rs2) = other;
        let w1 = List.map(widenRoute, rs1);
        let w2 = List.map(widenRoute, rs2);
        Router.Router(List.append(w1, w2))

    ///
    /// Prefixes every route in `sub` with `prefix` (e.g. `"/api/v1"`).
    ///
    pub def prefix(p: String, sub: Router[ef]): Router[ef] =
        let Router.Router(rs) = sub;
        let prefixed = List.map(r -> {
            let Route.Route(m, pat, _, h) = r;
            let full = Url.joinPaths(p, pat);
            Route.Route(m, full, compilePattern(full), h)
        }, rs);
        Router.Router(prefixed)

    ///
    /// Mounts `sub` under `p` and merges it into `base`.
    ///
    /// Example:
    /// ```
    /// Router.empty()
    ///     |> Router.get("/health", _ -> "ok")
    ///     |> Router.scope("/api/v1", apiRouter)
    /// ```
    ///
    pub def scope(p: String, sub: Router[ef2], base: Router[ef1]): Router[ef1 + ef2] =
        merge(prefix(p, sub), base)

    ///
    /// Wraps every route handler in `router` with `mw`.
    ///
    /// Because `mw` transforms `Handler[ef1] -> Handler[ef2]`, this can discharge
    /// effects (such as `Auth`) on a specific sub-router before mounting it!
    ///
    pub def withMiddleware(mw: Handler[ef1] -> Handler[ef2], router: Router[ef1]): Router[ef2] =
        let Router.Router(rs) = router;
        let mapped = List.map(r -> {
            let Route.Route(m, pat, segs, h) = r;
            Route.Route(m, pat, segs, mw(h))
        }, rs);
        Router.Router(mapped)

    ///
    /// Returns the list of registered `(methodLabel, pattern)` route descriptions
    /// (useful for debugging or startup banners).
    ///
    pub def describe(router: Router[ef]): List[(String, String)] =
        let Router.Router(rs) = router;
        List.map(r -> {
            let Route.Route(m, pat, _, _) = r;
            let label = match m {
                case Some(meth) => "${meth}"
                case None       => "*"
            };
            (label, pat)
        }, rs)

    // --- Dispatching ---

    enum MatchOutcome[ef: Eff] {
        case ExactMatch(Handler[ef], Map[String, String])
        case HeadFallback(Handler[ef], Map[String, String])
        case WrongMethod(List[Method])
        case NoMatch
    }

    ///
    /// Compiles a `Router[ef]` into an `App[(ef - Req - Res) + HttpError]`.
    ///
    /// - Automatically handles `Req` (populated with matched `:param` / `*wildcard` values)
    ///   and `Res` (applying any ambient headers/cookies/status set during the handler).
    /// - Automatically supports `HEAD` fallback for `GET` routes (stripping body).
    /// - Returns `405 Method Not Allowed` with an RFC-compliant `Allow` header when a path
    ///   matches a different HTTP method.
    /// - Raises `HttpError.notFound` when no route matches so your chosen error middleware
    ///   renders 404 responses consistently with all other errors.
    ///
    pub def toApp(router: Router[ef]): App[(ef - Req - Res) + HttpError] = req -> {
        let Router.Router(routes) = router;
        let reqMethod = Request.method(req);
        let reqSegs = Url.splitPath(Request.path(req));
        match findMatch(reqMethod, reqSegs, routes) {
            case MatchOutcome.ExactMatch(h, params) =>
                let matchedReq = Request.withParams(params, req);
                run {
                    checked_ecast(h())
                } with Res.runCollecting
                  with Req.runWith(matchedReq)
            case MatchOutcome.HeadFallback(h, params) =>
                let matchedReq = Request.withParams(params, req);
                let res = run {
                    checked_ecast(h())
                } with Res.runCollecting
                  with Req.runWith(matchedReq);
                Response.withBody("", res)
            case MatchOutcome.WrongMethod(allowed) =>
                let withHead = if (List.memberOf(Method.Get, allowed) and not List.memberOf(Method.Head, allowed))
                    List.append(allowed, Method.Head :: Nil)
                else
                    allowed;
                let allowHeader = withHead
                    |> List.distinct
                    |> List.map(m -> "${m}")
                    |> String.intercalate(", ");
                Response.text("Method ${reqMethod} not allowed for ${Request.path(req)}")
                    |> Response.withStatus(Status.methodNotAllowed())
                    |> Response.withHeader("Allow", allowHeader)
            case MatchOutcome.NoMatch =>
                HttpError.notFound("Route not found: ${reqMethod} ${Request.path(req)}")
        }
    }

    // --- Internal Helpers ---

    def addEntry(m: Option[Method], pattern: String, h: Handler[ef1], router: Router[ef2]): Router[ef1 + ef2] =
        let Router.Router(existing) = router;
        let normalized = Url.normalizePath(pattern);
        let segs = compilePattern(normalized);
        let newRoute: Route[ef1 + ef2] = Route.Route(m, normalized, segs, () -> checked_ecast(h()));
        let widened = List.map(widenRoute, existing);
        Router.Router(List.append(widened, newRoute :: Nil))

    def widenRoute(r: Route[ef1]): Route[ef1 + ef2] =
        let Route.Route(m, pat, segs, h) = r;
        Route.Route(m, pat, segs, () -> checked_ecast(h()))

    def compilePattern(pattern: String): List[PathSegment] =
        Url.splitPattern(pattern) |> List.map(seg -> {
            if (String.startsWith({prefix = ":"}, seg))
                PathSegment.Param(String.sliceRight({start = 1}, seg))
            else if (String.startsWith({prefix = "*"}, seg))
                PathSegment.Wildcard(String.sliceRight({start = 1}, seg))
            else
                PathSegment.Literal(seg)
        })

    def matchSegments(pattern: List[PathSegment], path: List[String], acc: Map[String, String]): Option[Map[String, String]] =
        match (pattern, path) {
            case (Nil, Nil) =>
                Some(acc)
            case (PathSegment.Wildcard(name) :: Nil, rest) =>
                let joined = String.intercalate("/", rest);
                if (String.isEmpty(name))
                    Some(acc)
                else
                    Some(Map.insert(name, joined, acc))
            case (PathSegment.Literal(expected) :: pTail, actual :: sTail) =>
                if (expected == actual)
                    matchSegments(pTail, sTail, acc)
                else
                    None
            case (PathSegment.Param(name) :: pTail, actual :: sTail) =>
                matchSegments(pTail, sTail, Map.insert(name, actual, acc))
            case _ =>
                None
        }

    def findMatch(reqMethod: Method, reqSegs: List[String], routes: List[Route[ef]]): MatchOutcome[ef] =
        def loop(rs, headCandidate, allowedMethods) = match rs {
            case Nil =>
                match headCandidate {
                    case Some((h, params)) => MatchOutcome.HeadFallback(h, params)
                    case None => match allowedMethods {
                        case Nil => MatchOutcome.NoMatch
                        case ms  => MatchOutcome.WrongMethod(List.reverse(ms))
                    }
                }
            case Route.Route(mOpt, _, segs, h) :: rest =>
                match matchSegments(segs, reqSegs, Map.empty()) {
                    case None =>
                        loop(rest, headCandidate, allowedMethods)
                    case Some(params) =>
                        match mOpt {
                            case None =>
                                MatchOutcome.ExactMatch(h, params)
                            case Some(m) if m == reqMethod =>
                                MatchOutcome.ExactMatch(h, params)
                            case Some(Method.Get) if reqMethod == Method.Head =>
                                let nextHead = match headCandidate {
                                    case Some(_) => headCandidate
                                    case None    => Some((h, params))
                                };
                                loop(rest, nextHead, Method.Get :: allowedMethods)
                            case Some(m) =>
                                loop(rest, headCandidate, m :: allowedMethods)
                        }
                }
        };
        loop(routes, None, Nil)

}
