pub mod Weft.Status {
    use Weft.Status

    ///
    /// Represents an HTTP status code and its standard reason phrase.
    ///
    pub enum Status with Eq, Order {
        case Status(Int32, String)
    }

    instance ToString[Status] {
        pub def toString(s: Status): String =
            let Status.Status(code, reason) = s;
            "${code} ${reason}"
    }

    pub def ok(): Status                  = Status.Status(200, "OK")
    pub def created(): Status             = Status.Status(201, "Created")
    pub def accepted(): Status            = Status.Status(202, "Accepted")
    pub def noContent(): Status           = Status.Status(204, "No Content")
    pub def partialContent(): Status      = Status.Status(206, "Partial Content")
    pub def movedPermanently(): Status    = Status.Status(301, "Moved Permanently")
    pub def found(): Status               = Status.Status(302, "Found")
    pub def seeOther(): Status            = Status.Status(303, "See Other")
    pub def notModified(): Status         = Status.Status(304, "Not Modified")
    pub def temporaryRedirect(): Status   = Status.Status(307, "Temporary Redirect")
    pub def badRequest(): Status          = Status.Status(400, "Bad Request")
    pub def unauthorized(): Status        = Status.Status(401, "Unauthorized")
    pub def forbidden(): Status           = Status.Status(403, "Forbidden")
    pub def notFound(): Status            = Status.Status(404, "Not Found")
    pub def methodNotAllowed(): Status    = Status.Status(405, "Method Not Allowed")
    pub def requestTimeout(): Status      = Status.Status(408, "Request Timeout")
    pub def conflict(): Status             = Status.Status(409, "Conflict")
    pub def gone(): Status                 = Status.Status(410, "Gone")
    pub def payloadTooLarge(): Status      = Status.Status(413, "Payload Too Large")
    pub def unsupportedMediaType(): Status = Status.Status(415, "Unsupported Media Type")
    pub def rangeNotSatisfiable(): Status  = Status.Status(416, "Range Not Satisfiable")
    pub def unprocessableEntity(): Status  = Status.Status(422, "Unprocessable Entity")
    pub def tooManyRequests(): Status     = Status.Status(429, "Too Many Requests")
    pub def internalServerError(): Status = Status.Status(500, "Internal Server Error")
    pub def notImplemented(): Status      = Status.Status(501, "Not Implemented")
    pub def badGateway(): Status          = Status.Status(502, "Bad Gateway")
    pub def serviceUnavailable(): Status  = Status.Status(503, "Service Unavailable")
    pub def gatewayTimeout(): Status      = Status.Status(504, "Gateway Timeout")

    pub def custom(c: Int32, r: String): Status = Status.Status(c, r)

    pub def code(s: Status): Int32 =
        let Status.Status(c, _) = s;
        c

    pub def reason(s: Status): String =
        let Status.Status(_, r) = s;
        r

    pub def isSuccess(s: Status): Bool =
        let c = code(s);
        c >= 200 and c < 300

    pub def isClientError(s: Status): Bool =
        let c = code(s);
        c >= 400 and c < 500

    pub def isServerError(s: Status): Bool =
        let c = code(s);
        c >= 500 and c < 600

}
