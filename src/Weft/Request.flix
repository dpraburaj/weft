pub mod Weft.Request {
    use Weft.Body
    use Weft.Cookie
    use Weft.Headers
    use Weft.Method
    use Weft.Request
    use Weft.Url

    ///
    /// Represents an immutable incoming HTTP request.
    ///
    pub enum Request {
        case Request({
            method     = Method,
            path       = String,
            rawQuery   = String,
            queryMap   = Map[String, String],
            queryAll   = Map[String, List[String]],
            params     = Map[String, String],
            headers    = Headers,
            cookies    = Map[String, String],
            body       = Body,
            remoteAddr = Option[String]
        })
    }

    instance Eq[Request] {
        pub def eq(a: Request, b: Request): Bool =
            let Request.Request(x) = a;
            let Request.Request(y) = b;
            x#method == y#method and
            x#path == y#path and
            x#rawQuery == y#rawQuery and
            x#queryMap == y#queryMap and
            x#queryAll == y#queryAll and
            x#params == y#params and
            x#headers == y#headers and
            x#cookies == y#cookies and
            x#body == y#body and
            x#remoteAddr == y#remoteAddr
    }

    ///
    /// Creates a new `Request` for `method` and `rawPath` (which may include a `?query` string).
    ///
    pub def make(m: Method, rawPath: String): Request =
        let (pathPart, rawQ) = match String.indexOfLeft({substr = "?"}, rawPath) {
            case Some(idx) =>
                (String.sliceLeft({end = idx}, rawPath), String.sliceRight({start = idx + 1}, rawPath))
            case None =>
                (rawPath, "")
        };
        let parsedAll = Url.parseQueryAll(rawQ);
        let parsedSingle = Map.map(vs -> Option.getWithDefault("", List.last(vs)), parsedAll);
        Request.Request({
            method     = m,
            path       = if (String.isEmpty(pathPart)) "/" else pathPart,
            rawQuery   = rawQ,
            queryMap   = parsedSingle,
            queryAll   = parsedAll,
            params     = Map.empty(),
            headers    = Headers.empty(),
            cookies    = Map.empty(),
            body       = Body.empty(),
            remoteAddr = None
        })

    pub def get(p: String): Request    = make(Method.Get, p)
    pub def post(p: String): Request   = make(Method.Post, p)
    pub def put(p: String): Request    = make(Method.Put, p)
    pub def patch(p: String): Request  = make(Method.Patch, p)
    pub def delete(p: String): Request = make(Method.Delete, p)
    pub def head(p: String): Request   = make(Method.Head, p)
    pub def options(p: String): Request = make(Method.Options, p)

    pub def method(req: Request): Method                          = let Request.Request(r) = req; r#method
    pub def path(req: Request): String                            = let Request.Request(r) = req; r#path
    pub def rawQuery(req: Request): String                        = let Request.Request(r) = req; r#rawQuery
    pub def queryParams(req: Request): Map[String, String]        = let Request.Request(r) = req; r#queryMap
    pub def queryParamsAll(req: Request): Map[String, List[String]] = let Request.Request(r) = req; r#queryAll
    pub def params(req: Request): Map[String, String]             = let Request.Request(r) = req; r#params
    pub def headers(req: Request): Headers                        = let Request.Request(r) = req; r#headers
    pub def cookies(req: Request): Map[String, String]            = let Request.Request(r) = req; r#cookies
    pub def bodyValue(req: Request): Body                         = let Request.Request(r) = req; r#body
    pub def body(req: Request): String                            = Body.asText(bodyValue(req))
    pub def bodyBytes(req: Request): Vector[Int8]                 = Body.asBytes(bodyValue(req))
    pub def bodyLength(req: Request): Int32                       = Body.byteLength(bodyValue(req))
    pub def remoteAddr(req: Request): Option[String]              = let Request.Request(r) = req; r#remoteAddr

    ///
    /// Resolves the client IP address safely:
    /// - Returns `remoteAddr` directly unless `remoteAddr` matches an entry in `trustedProxies`
    ///   (or `trustedProxies` contains `"*"`).
    /// - Only when the direct peer is a trusted proxy does it inspect `X-Forwarded-For`
    ///   (first non-empty IP) or `X-Real-IP`.
    ///
    pub def clientIp(trustedProxies: List[String], req: Request): Option[String] = {
        let peerOpt = remoteAddr(req);
        let isTrusted = match peerOpt {
            case Some(peer) => List.exists(p -> p == "*" or p == peer, trustedProxies)
            case None       => List.exists(p -> p == "*", trustedProxies)
        };
        if (isTrusted) {
            match forwardedIp(req) {
                case Some(ip) => Some(ip)
                case None     => peerOpt
            }
        } else {
            peerOpt
        }
    }

    def forwardedIp(req: Request): Option[String] =
        match header("X-Forwarded-For", req) {
            case Some(raw) =>
                match List.head(String.splitOn({substr = ","}, raw)) {
                    case Some(first) =>
                        let trimmed = String.trim(first);
                        if (String.isEmpty(trimmed)) None else Some(trimmed)
                    case None => None
                }
            case None =>
                match header("X-Real-IP", req) {
                    case Some(ip) =>
                        let trimmed = String.trim(ip);
                        if (String.isEmpty(trimmed)) None else Some(trimmed)
                    case None => None
                }
        }

    pub def header(name: String, req: Request): Option[String] =
        Headers.get(name, headers(req))

    ///
    /// Returns the lowercased media type from the `Content-Type` header (without parameters
    /// such as `; charset=utf-8` or `; boundary=...`), if present.
    ///
    pub def contentType(req: Request): Option[String] =
        header("Content-Type", req) |> Option.map(ct -> {
            let media = match String.indexOfLeft({substr = ";"}, ct) {
                case Some(idx) => String.sliceLeft({end = idx}, ct)
                case None      => ct
            };
            String.toLowerCase(String.trim(media))
        })

    pub def queryParam(name: String, req: Request): Option[String] =
        Map.get(name, queryParams(req))

    ///
    /// Returns all values for query parameter `name` in order (empty list if absent).
    ///
    pub def queryParamAll(name: String, req: Request): List[String] =
        Map.getWithDefault(name, Nil, queryParamsAll(req))

    pub def param(name: String, req: Request): Option[String] =
        Map.get(name, params(req))

    pub def cookie(name: String, req: Request): Option[String] =
        Map.get(name, cookies(req))

    ///
    /// Parses the request body as `application/x-www-form-urlencoded` (last value wins).
    ///
    pub def formParams(req: Request): Map[String, String] =
        Url.parseQuery(body(req))

    ///
    /// Parses the request body as `application/x-www-form-urlencoded`, preserving all values per key.
    ///
    pub def formParamsAll(req: Request): Map[String, List[String]] =
        Url.parseQueryAll(body(req))

    ///
    /// Extracts a `Bearer <token>` credential from the `Authorization` header.
    ///
    pub def bearerToken(req: Request): Option[String] =
        match header("Authorization", req) {
            case Some(v) =>
                let trimmed = String.trim(v);
                if (String.startsWith({prefix = "Bearer "}, trimmed))
                    let tok = String.trim(String.sliceRight({start = 7}, trimmed));
                    if (String.isEmpty(tok)) None else Some(tok)
                else if (String.startsWith({prefix = "bearer "}, trimmed))
                    let tok = String.trim(String.sliceRight({start = 7}, trimmed));
                    if (String.isEmpty(tok)) None else Some(tok)
                else
                    None
            case None => None
        }

    pub def withHeader(name: String, value: String, req: Request): Request =
        let Request.Request(r) = req;
        let nextHeaders = Headers.set(name, value, r#headers);
        let nextCookies = if (String.toLowerCase(name) == "cookie")
            Map.unionWith((_, v2) -> v2, r#cookies, Cookie.parseHeader(value))
        else
            r#cookies;
        Request.Request({ headers = nextHeaders, cookies = nextCookies | r })

    pub def withHeaders(h: Headers, req: Request): Request =
        let Request.Request(r) = req;
        let cookieHeaders = Headers.getAll("Cookie", h);
        let parsedCookies = if (List.isEmpty(cookieHeaders))
            r#cookies
        else
            Map.unionWith((_, v2) -> v2, r#cookies, Cookie.parseHeaders(cookieHeaders));
        Request.Request({ headers = h, cookies = parsedCookies | r })

    pub def withRemoteAddr(addr: String, req: Request): Request =
        let Request.Request(r) = req;
        let trimmed = String.trim(addr);
        Request.Request({ remoteAddr = if (String.isEmpty(trimmed)) None else Some(trimmed) | r })

    pub def withBody(b: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ body = Body.text(b) | r })

    pub def withBytes(bs: Vector[Int8], req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ body = Body.bytes(bs) | r })

    pub def withBodyValue(b: Body, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ body = b | r })

    pub def withParams(ps: Map[String, String], req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ params = ps | r })

    pub def withQuery(k: String, v: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({
            queryMap = Map.insert(k, v, r#queryMap),
            queryAll = Map.insert(k, v :: Nil, r#queryAll)
            | r
        })

    pub def withQueryAll(k: String, vs: List[String], req: Request): Request =
        let Request.Request(r) = req;
        let nextSingle = match List.last(vs) {
            case Some(lastV) => Map.insert(k, lastV, r#queryMap)
            case None        => Map.remove(k, r#queryMap)
        };
        let nextAll = if (List.isEmpty(vs)) Map.remove(k, r#queryAll) else Map.insert(k, vs, r#queryAll);
        Request.Request({ queryMap = nextSingle, queryAll = nextAll | r })

    pub def addQuery(k: String, v: String, req: Request): Request =
        let existing = queryParamAll(k, req);
        withQueryAll(k, List.append(existing, v :: Nil), req)

    pub def withCookie(name: String, value: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ cookies = Map.insert(name, value, r#cookies) | r })

    pub def withBearer(token: String, req: Request): Request =
        withHeader("Authorization", "Bearer ${token}", req)

}
