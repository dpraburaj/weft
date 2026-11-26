pub mod Weft.Response {
    use Weft.Body
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
            body    = Body
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
    /// Constructs a `Response` with the given status, headers, and UTF-8 text body.
    ///
    pub def make(st: Status, h: Headers, b: String): Response =
        Response.Response({ status = st, headers = h, body = Body.text(b) })

    ///
    /// Constructs a `Response` with the given status, headers, and `Body` (text or binary).
    ///
    pub def makeBody(st: Status, h: Headers, b: Body): Response =
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
    /// Returns a `200 OK` binary response with the given `Content-Type` and raw bytes.
    ///
    pub def bytes(contentType: String, data: Vector[Int8]): Response =
        makeBody(Status.ok(), Headers.singleton("Content-Type", contentType), Body.bytes(data))

    ///
    /// Returns a `201 Created` plain-text response.
    ///
    pub def created(b: String): Response =
        text(b) |> withStatus(Status.created())

    ///
    /// Returns a `204 No Content` empty response.
    ///
    pub def noContent(): Response =
        makeBody(Status.noContent(), Headers.empty(), Body.empty())

    ///
    /// Returns a `304 Not Modified` empty response.
    ///
    pub def notModified(): Response =
        makeBody(Status.notModified(), Headers.empty(), Body.empty())

    ///
    /// Returns a `302 Found` redirect response to `location`.
    ///
    pub def redirect(location: String): Response =
        makeBody(Status.found(), Headers.singleton("Location", location), Body.empty())

    ///
    /// Returns a `303 See Other` redirect response (ideal for Post/Redirect/Get forms).
    ///
    pub def seeOther(location: String): Response =
        makeBody(Status.seeOther(), Headers.singleton("Location", location), Body.empty())

    ///
    /// Returns a `301 Moved Permanently` redirect response to `location`.
    ///
    pub def permanentRedirect(location: String): Response =
        makeBody(Status.movedPermanently(), Headers.singleton("Location", location), Body.empty())

    pub def status(res: Response): Status       = let Response.Response(r) = res; r#status
    pub def headers(res: Response): Headers     = let Response.Response(r) = res; r#headers
    pub def bodyValue(res: Response): Body      = let Response.Response(r) = res; r#body
    pub def body(res: Response): String         = Body.asText(bodyValue(res))
    pub def bodyBytes(res: Response): Vector[Int8] = Body.asBytes(bodyValue(res))
    pub def bodyLength(res: Response): Int32    = Body.byteLength(bodyValue(res))

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
        Response.Response({ body = Body.text(b) | r })

    pub def withBytes(bs: Vector[Int8], res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ body = Body.bytes(bs) | r })

    pub def withBodyValue(b: Body, res: Response): Response =
        let Response.Response(r) = res;
        Response.Response({ body = b | r })

}
