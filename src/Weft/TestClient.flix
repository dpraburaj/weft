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

}
