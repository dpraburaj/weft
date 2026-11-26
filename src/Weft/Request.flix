pub mod Weft.Request {
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
            method   = Method,
            path     = String,
            rawQuery = String,
            queryMap = Map[String, String],
            params   = Map[String, String],
            headers  = Headers,
            cookies  = Map[String, String],
            body     = String
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
            x#params == y#params and
            x#headers == y#headers and
            x#cookies == y#cookies and
            x#body == y#body
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
        Request.Request({
            method   = m,
            path     = if (String.isEmpty(pathPart)) "/" else pathPart,
            rawQuery = rawQ,
            queryMap = Url.parseQuery(rawQ),
            params   = Map.empty(),
            headers  = Headers.empty(),
            cookies  = Map.empty(),
            body     = ""
        })

    pub def get(p: String): Request    = make(Method.Get, p)
    pub def post(p: String): Request   = make(Method.Post, p)
    pub def put(p: String): Request    = make(Method.Put, p)
    pub def patch(p: String): Request  = make(Method.Patch, p)
    pub def delete(p: String): Request = make(Method.Delete, p)
    pub def head(p: String): Request   = make(Method.Head, p)
    pub def options(p: String): Request = make(Method.Options, p)

    pub def method(req: Request): Method               = let Request.Request(r) = req; r#method
    pub def path(req: Request): String                 = let Request.Request(r) = req; r#path
    pub def rawQuery(req: Request): String             = let Request.Request(r) = req; r#rawQuery
    pub def queryParams(req: Request): Map[String, String] = let Request.Request(r) = req; r#queryMap
    pub def params(req: Request): Map[String, String]  = let Request.Request(r) = req; r#params
    pub def headers(req: Request): Headers             = let Request.Request(r) = req; r#headers
    pub def cookies(req: Request): Map[String, String] = let Request.Request(r) = req; r#cookies
    pub def body(req: Request): String                 = let Request.Request(r) = req; r#body

    pub def header(name: String, req: Request): Option[String] =
        Headers.get(name, headers(req))

    pub def queryParam(name: String, req: Request): Option[String] =
        Map.get(name, queryParams(req))

    pub def param(name: String, req: Request): Option[String] =
        Map.get(name, params(req))

    pub def cookie(name: String, req: Request): Option[String] =
        Map.get(name, cookies(req))

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
        let parsedCookies = match Headers.get("Cookie", h) {
            case Some(cv) => Map.unionWith((_, v2) -> v2, r#cookies, Cookie.parseHeader(cv))
            case None     => r#cookies
        };
        Request.Request({ headers = h, cookies = parsedCookies | r })

    pub def withBody(b: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ body = b | r })

    pub def withParams(ps: Map[String, String], req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ params = ps | r })

    pub def withQuery(k: String, v: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ queryMap = Map.insert(k, v, r#queryMap) | r })

    pub def withCookie(name: String, value: String, req: Request): Request =
        let Request.Request(r) = req;
        Request.Request({ cookies = Map.insert(name, value, r#cookies) | r })

    pub def withBearer(token: String, req: Request): Request =
        withHeader("Authorization", "Bearer ${token}", req)

}
