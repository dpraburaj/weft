pub mod Weft.TestClient {
    use Weft.App
    use Weft.Json
    use Weft.Multipart
    use Weft.Request
    use Weft.Response
    use Weft.UploadedFile
    use Weft.Url

    ///
    /// Executes an `App[ef]` directly in memory — zero sockets, zero ports, zero `IO`!
    ///
    pub def send(req: Request, app: App[ef]): Response \ ef =
        app(req)

    pub def get(path: String, app: App[ef]): Response \ ef =
        app(Request.get(path))

    pub def head(path: String, app: App[ef]): Response \ ef =
        app(Request.head(path))

    pub def options(path: String, app: App[ef]): Response \ ef =
        app(Request.options(path))

    pub def delete(path: String, app: App[ef]): Response \ ef =
        app(Request.delete(path))

    pub def postText(path: String, body: String, app: App[ef]): Response \ ef =
        app(Request.post(path) |> Request.withHeader("Content-Type", "text/plain") |> Request.withBody(body))

    pub def postBytes(path: String, contentType: String, data: Vector[Int8], app: App[ef]): Response \ ef =
        app(Request.post(path)
            |> Request.withHeader("Content-Type", contentType)
            |> Request.withBytes(data))

    pub def postForm(path: String, fields: List[(String, String)], app: App[ef]): Response \ ef =
        app(Request.post(path)
            |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
            |> Request.withBody(Url.encodeQuery(fields)))

    pub def postMultipart(
        path: String,
        fields: List[(String, String)],
        files: List[UploadedFile],
        app: App[ef]
    ): Response \ ef = {
        let boundary = "WeftTestBoundary7MA4YWxkTrZu0gW";
        let payload = Multipart.encode(boundary, fields, files);
        app(Request.post(path)
            |> Request.withHeader("Content-Type", "multipart/form-data; boundary=${boundary}")
            |> Request.withBytes(payload))
    }

    pub def postJson(path: String, payload: Json, app: App[ef]): Response \ ef =
        app(Request.post(path)
            |> Request.withHeader("Content-Type", "application/json")
            |> Request.withBody(Json.encode(payload)))

    pub def putJson(path: String, payload: Json, app: App[ef]): Response \ ef =
        app(Request.put(path)
            |> Request.withHeader("Content-Type", "application/json")
            |> Request.withBody(Json.encode(payload)))

    pub def patchJson(path: String, payload: Json, app: App[ef]): Response \ ef =
        app(Request.patch(path)
            |> Request.withHeader("Content-Type", "application/json")
            |> Request.withBody(Json.encode(payload)))

    // --- HTML / CSRF Extraction Helpers for Tests ---

    ///
    /// Extracts a CSRF token from an HTML response body, checking
    /// `<meta name="csrf-token" content="...">` first and then
    /// `<input ... name="_csrf" ... value="...">`.
    ///
    pub def extractCsrfToken(res: Response): Option[String] = {
        let html = Response.body(res);
        match extractMetaContent("csrf-token", html) {
            case Some(tok) => Some(tok)
            case None      => extractInputValue("_csrf", res)
        }
    }

    ///
    /// Extracts the `value="..."` attribute from an `<input ... name="<fieldName>" ...>` tag
    /// in an HTML response body.
    ///
    pub def extractInputValue(fieldName: String, res: Response): Option[String] = {
        let html = Response.body(res);
        let nameAttr = "name=\"${fieldName}\"";
        match String.indexOfLeft({substr = nameAttr}, html) {
            case None => None
            case Some(nameIdx) =>
                let tagStart = match String.indexOfRight({substr = "<input"}, String.sliceLeft({end = nameIdx}, html)) {
                    case Some(i) => i
                    case None    => nameIdx
                };
                let afterStart = String.sliceRight({start = tagStart}, html);
                let tag = match String.indexOfLeft({substr = ">"}, afterStart) {
                    case Some(endIdx) => String.sliceLeft({end = endIdx}, afterStart)
                    case None         => afterStart
                };
                extractQuotedAttr("value", tag)
        }
    }

    def extractMetaContent(metaName: String, html: String): Option[String] = {
        let nameAttr = "name=\"${metaName}\"";
        match String.indexOfLeft({substr = nameAttr}, html) {
            case None => None
            case Some(nameIdx) =>
                let tagStart = match String.indexOfRight({substr = "<meta"}, String.sliceLeft({end = nameIdx}, html)) {
                    case Some(i) => i
                    case None    => nameIdx
                };
                let afterStart = String.sliceRight({start = tagStart}, html);
                let tag = match String.indexOfLeft({substr = ">"}, afterStart) {
                    case Some(endIdx) => String.sliceLeft({end = endIdx}, afterStart)
                    case None         => afterStart
                };
                extractQuotedAttr("content", tag)
        }
    }

    def extractQuotedAttr(attrName: String, tag: String): Option[String] = {
        let prefix = "${attrName}=\"";
        match String.indexOfLeft({substr = prefix}, tag) {
            case None => None
            case Some(idx) =>
                let rest = String.sliceRight({start = idx + String.length(prefix)}, tag);
                match String.indexOfLeft({substr = "\""}, rest) {
                    case Some(endIdx) => Some(String.sliceLeft({end = endIdx}, rest))
                    case None         => None
                }
        }
    }

}
