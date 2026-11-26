pub mod Weft.ClientRequest {
    use Weft.Body
    use Weft.ClientRequest
    use Weft.Headers
    use Weft.Json
    use Weft.Method
    use Weft.Url

    import java.util.Base64

    ///
    /// Represents an immutable outbound HTTP request for `Weft.HttpClient`.
    ///
    pub enum ClientRequest {
        case ClientRequest({
            method    = Method,
            url       = String,
            headers   = Headers,
            body      = Body,
            timeoutMs = Int64
        })
    }

    instance Eq[ClientRequest] {
        pub def eq(a: ClientRequest, b: ClientRequest): Bool =
            let ClientRequest.ClientRequest(x) = a;
            let ClientRequest.ClientRequest(y) = b;
            x#method == y#method and
            x#url == y#url and
            x#headers == y#headers and
            x#body == y#body and
            x#timeoutMs == y#timeoutMs
    }

    instance ToString[ClientRequest] {
        pub def toString(req: ClientRequest): String =
            "${method(req)} ${url(req)}"
    }

    ///
    /// Creates a `ClientRequest` with a default 15-second timeout.
    ///
    pub def make(m: Method, targetUrl: String): ClientRequest =
        ClientRequest.ClientRequest({
            method    = m,
            url       = targetUrl,
            headers   = Headers.empty(),
            body      = Body.empty(),
            timeoutMs = 15000i64
        })

    pub def get(targetUrl: String): ClientRequest    = make(Method.Get, targetUrl)
    pub def post(targetUrl: String): ClientRequest   = make(Method.Post, targetUrl)
    pub def put(targetUrl: String): ClientRequest    = make(Method.Put, targetUrl)
    pub def patch(targetUrl: String): ClientRequest  = make(Method.Patch, targetUrl)
    pub def delete(targetUrl: String): ClientRequest = make(Method.Delete, targetUrl)

    pub def postJson(targetUrl: String, payload: Json): ClientRequest =
        post(targetUrl) |> withJson(payload)

    pub def postForm(targetUrl: String, fields: List[(String, String)]): ClientRequest =
        post(targetUrl)
            |> withHeader("Content-Type", "application/x-www-form-urlencoded")
            |> withBody(Url.encodeQuery(fields))

    pub def method(req: ClientRequest): Method       = let ClientRequest.ClientRequest(r) = req; r#method
    pub def url(req: ClientRequest): String          = let ClientRequest.ClientRequest(r) = req; r#url
    pub def headers(req: ClientRequest): Headers     = let ClientRequest.ClientRequest(r) = req; r#headers
    pub def bodyValue(req: ClientRequest): Body      = let ClientRequest.ClientRequest(r) = req; r#body
    pub def body(req: ClientRequest): String         = Body.asText(bodyValue(req))
    pub def bodyBytes(req: ClientRequest): Vector[Int8] = Body.asBytes(bodyValue(req))
    pub def timeoutMs(req: ClientRequest): Int64     = let ClientRequest.ClientRequest(r) = req; r#timeoutMs

    pub def header(name: String, req: ClientRequest): Option[String] =
        Headers.get(name, headers(req))

    pub def withHeader(name: String, value: String, req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ headers = Headers.set(name, value, r#headers) | r })

    pub def addHeader(name: String, value: String, req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ headers = Headers.add(name, value, r#headers) | r })

    pub def withHeaders(h: Headers, req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ headers = h | r })

    pub def withBearer(token: String, req: ClientRequest): ClientRequest =
        withHeader("Authorization", "Bearer ${token}", req)

    pub def withBasicAuth(username: String, password: String, req: ClientRequest): ClientRequest = {
        let raw = Body.utf8Bytes("${username}:${password}");
        let encoded = unsafe IO {
            let enc = Base64.getEncoder();
            enc.encodeToString(Vector.toArray(Static, raw))
        };
        withHeader("Authorization", "Basic ${encoded}", req)
    }

    pub def withBody(b: String, req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ body = Body.text(b) | r })

    pub def withBytes(bs: Vector[Int8], req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ body = Body.bytes(bs) | r })

    pub def withJson(payload: Json, req: ClientRequest): ClientRequest =
        req
            |> withHeader("Content-Type", "application/json")
            |> withBody(Json.encode(payload))

    pub def withTimeoutMs(ms: Int64, req: ClientRequest): ClientRequest =
        let ClientRequest.ClientRequest(r) = req;
        ClientRequest.ClientRequest({ timeoutMs = ms | r })

}
