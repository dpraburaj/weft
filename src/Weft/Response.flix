pub mod Weft.Response {
    use Weft.Cookie
    use Weft.Headers
    use Weft.Response
    use Weft.Status

    ///
    /// Represents an immutable outgoing HTTP response.
    ///
    pub enum Response {
        case Response({
            status  = Status,
            headers = Headers,
            body    = String
        })
    }

    instance Eq[Response] {
        pub def eq(a: Response, b: Response): Bool =
            let Response.Response(x) = a;
            let Response.Response(y) = b;
            x#status == y#status and
            x#headers == y#headers and
            x#body == y#body
    }

    ///
    /// Constructs a `Response` with the given status, headers, and body.
    ///
    pub def make(st: Status, h: Headers, b: String): Response =
        Response.Response({ status = st, headers = h, body = b })

    ///
    /// Returns a `200 OK` plain-text response.
    ///
    pub def text(b: String): Response =
        make(Status.ok(), Headers.singleton("Content-Type", "text/plain; charset=utf-8"), b)

    ///
    /// Alias for `Response.text`.
    ///
    pub def ok(b: String): Response = text(b)

    ///
    /// Returns a `200 OK` HTML response.
    ///
    pub def html(b: String): Response =
        make(Status.ok(), Headers.singleton("Content-Type", "text/html; charset=utf-8"), b)

    ///
    /// Returns a `200 OK` JSON response from a pre-encoded JSON string.
    ///
    pub def jsonString(b: String): Response =
        make(Status.ok(), Headers.singleton("Content-Type", "application/json; charset=utf-8"), b)

    ///
    /// Returns a `201 Created` plain-text response.
    ///
    pub def created(b: String): Response =
        text(b) |> withStatus(Status.created())

    ///
    /// Returns a `204 No Content` empty response.
    ///
    pub def noContent(): Response =
        make(Status.noContent(), Headers.empty(), "")

    ///
    /// Returns a `302 Found` redirect response to `location`.
    ///
    pub def redirect(location: String): Response =
        make(Status.found(), Headers.singleton("Location", location), "")

    ///
    /// Returns a `301 Moved Permanently` redirect response to `location`.
    ///
    pub def permanentRedirect(location: String): Response =
        make(Status.movedPermanently(), Headers.singleton("Location", location), "")

    pub def status(res: Response): Status  = let Response.Response(r) = res; r#status
    pub def headers(res: Response): Headers = let Response.Response(r) = res; r#headers
    pub def body(res: Response): String    = let Response.Response(r) = res; r#body

    pub def header(name: String, res: Response): Option[String] =
        Headers.get(name, headers(res))

    pub def withStatus(st: Status, res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ status = st | r })

    pub def withHeader(name: String, value: String, res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ headers = Headers.set(name, value, r#headers) | r })

    pub def addHeader(name: String, value: String, res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ headers = Headers.add(name, value, r#headers) | r })

    pub def withContentType(ct: String, res: Response): Response =
        withHeader("Content-Type", ct, res)

    pub def withCookie(c: Cookie, res: Response): Response =
        addHeader("Set-Cookie", Cookie.toHeaderValue(c), res)

    pub def withBody(b: String, res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ body = b | r })

}
