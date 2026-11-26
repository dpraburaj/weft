pub mod Weft.ClientResponse {
    use Weft.Body
    use Weft.ClientResponse
    use Weft.Headers
    use Weft.Json

    ///
    /// Represents an immutable HTTP response received from `Weft.HttpClient`.
    ///
    pub enum ClientResponse {
        case ClientResponse({
            status  = Int32,
            headers = Headers,
            body    = Body
        })
    }

    instance Eq[ClientResponse] {
        pub def eq(a: ClientResponse, b: ClientResponse): Bool =
            let ClientResponse.ClientResponse(x) = a;
            let ClientResponse.ClientResponse(y) = b;
            x#status == y#status and
            x#headers == y#headers and
            x#body == y#body
    }

    instance ToString[ClientResponse] {
        pub def toString(res: ClientResponse): String =
            "ClientResponse(status=${status(res)}, bytes=${Body.byteLength(bodyValue(res))})"
    }

    pub def make(st: Int32, h: Headers, b: Body): ClientResponse =
        ClientResponse.ClientResponse({ status = st, headers = h, body = b })

    pub def ok(text: String): ClientResponse =
        make(200, Headers.singleton("Content-Type", "text/plain; charset=utf-8"), Body.text(text))

    pub def json(st: Int32, payload: Json): ClientResponse =
        make(st, Headers.singleton("Content-Type", "application/json; charset=utf-8"), Body.text(Json.encode(payload)))

    pub def bytes(st: Int32, contentType: String, data: Vector[Int8]): ClientResponse =
        make(st, Headers.singleton("Content-Type", contentType), Body.bytes(data))

    pub def status(res: ClientResponse): Int32       = let ClientResponse.ClientResponse(r) = res; r#status
    pub def isSuccess(res: ClientResponse): Bool     = status(res) >= 200 and status(res) < 300
    pub def headers(res: ClientResponse): Headers    = let ClientResponse.ClientResponse(r) = res; r#headers
    pub def bodyValue(res: ClientResponse): Body     = let ClientResponse.ClientResponse(r) = res; r#body
    pub def body(res: ClientResponse): String        = Body.asText(bodyValue(res))
    pub def bodyBytes(res: ClientResponse): Vector[Int8] = Body.asBytes(bodyValue(res))

    pub def header(name: String, res: ClientResponse): Option[String] =
        Headers.get(name, headers(res))

    pub def parseJson(res: ClientResponse): Result[String, Json] =
        Json.parse(body(res))

}
