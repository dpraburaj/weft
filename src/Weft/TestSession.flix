pub mod Weft.TestSession {
    use Weft.App
    use Weft.Headers
    use Weft.Json
    use Weft.Method
    use Weft.Multipart
    use Weft.Request
    use Weft.Response
    use Weft.Status
    use Weft.TestClient
    use Weft.TestSession
    use Weft.UploadedFile
    use Weft.Url

    ///
    /// Pure, region-scoped stateful test browser for multi-step HTTP journeys
    /// (zero sockets, zero `IO`).
    ///
    /// Automatically persists `Set-Cookie` headers across requests (including
    /// `Max-Age=0` deletions and intermediate redirect hops), supports optional
    /// redirect following (`301`/`302`/`303`/`307`/`308`), and attaches default headers.
    ///
    pub enum TestSession[r: Region] {
        case TestSession({
            cookies         = Ref[Map[String, String], r],
            defaultHeaders  = Ref[Headers, r],
            followRedirects = Ref[Bool, r],
            maxRedirects    = Ref[Int32, r]
        })
    }

    ///
    /// Creates a fresh stateful `TestSession[r]` in local region `rc`.
    /// Redirect following defaults to `false` (enable with `TestSession.withFollowRedirects(true)`).
    ///
    pub def make(rc: Region[r]): TestSession[r] \ r =
        TestSession.TestSession({
            cookies         = Ref.fresh(rc, Map.empty()),
            defaultHeaders  = Ref.fresh(rc, Headers.empty()),
            followRedirects = Ref.fresh(rc, false),
            maxRedirects    = Ref.fresh(rc, 10)
        })

    // --- Configuration (Chainable) ---

    ///
    /// Enables or disables automatic redirect following (`301`/`302`/`303`/`307`/`308`).
    ///
    pub def withFollowRedirects(enabled: Bool, s: TestSession[r]): TestSession[r] \ r = {
        let TestSession.TestSession(st) = s;
        Ref.put(enabled, st#followRedirects);
        s
    }

    ///
    /// Sets the maximum number of redirect hops before returning the last redirect response.
    ///
    pub def withMaxRedirects(n: Int32, s: TestSession[r]): TestSession[r] \ r = {
        let TestSession.TestSession(st) = s;
        Ref.put(Int32.max(0, n), st#maxRedirects);
        s
    }

    ///
    /// Sets a default header attached to every subsequent request unless overridden per-request.
    ///
    pub def withHeader(name: String, value: String, s: TestSession[r]): TestSession[r] \ r = {
        let TestSession.TestSession(st) = s;
        Ref.transform(h -> Headers.set(name, value, h), st#defaultHeaders);
        s
    }

    ///
    /// Sets a default `Authorization: Bearer <token>` header on the session.
    ///
    pub def withBearer(token: String, s: TestSession[r]): TestSession[r] \ r =
        withHeader("Authorization", "Bearer ${token}", s)

    ///
    /// Removes all default headers from the session.
    ///
    pub def clearHeaders(s: TestSession[r]): Unit \ r = {
        let TestSession.TestSession(st) = s;
        Ref.put(Headers.empty(), st#defaultHeaders)
    }

    // --- Cookie Jar Inspection & Manipulation ---

    pub def cookies(s: TestSession[r]): Map[String, String] \ r = {
        let TestSession.TestSession(st) = s;
        Ref.get(st#cookies)
    }

    pub def cookie(name: String, s: TestSession[r]): Option[String] \ r =
        Map.get(name, cookies(s))

    pub def setCookie(name: String, value: String, s: TestSession[r]): Unit \ r = {
        let TestSession.TestSession(st) = s;
        Ref.transform(m -> Map.insert(name, value, m), st#cookies)
    }

    pub def deleteCookie(name: String, s: TestSession[r]): Unit \ r = {
        let TestSession.TestSession(st) = s;
        Ref.transform(m -> Map.remove(name, m), st#cookies)
    }

    pub def clearCookies(s: TestSession[r]): Unit \ r = {
        let TestSession.TestSession(st) = s;
        Ref.put(Map.empty(), st#cookies)
    }

    // --- Sending Requests ---

    ///
    /// Sends `req` through `app` with stored cookies and default headers, updating the
    /// cookie jar from any `Set-Cookie` response headers and following redirects if enabled.
    ///
    pub def send(req: Request, app: App[ef], s: TestSession[r]): Response \ ef + r = {
        let TestSession.TestSession(st) = s;
        if (Ref.get(st#followRedirects))
            sendFollowing(req, app, s)
        else
            sendNoRedirect(req, app, s)
    }

    ///
    /// Sends `req` through `app` without following redirects (still updates the cookie jar).
    ///
    pub def sendNoRedirect(req: Request, app: App[ef], s: TestSession[r]): Response \ ef + r = {
        let prepared = attachSessionState(req, s);
        let res = app(prepared);
        absorbCookies(res, s);
        res
    }

    ///
    /// Sends `req` through `app` and follows redirects (`301`/`302`/`303`/`307`/`308`)
    /// up to `maxRedirects`, persisting cookies set on every hop.
    ///
    pub def sendFollowing(req: Request, app: App[ef], s: TestSession[r]): Response \ ef + r = {
        let TestSession.TestSession(st) = s;
        let maxHops = Ref.get(st#maxRedirects);
        def loop(curReq: Request, hopsRemaining: Int32): Response \ ef + r = {
            let res = sendNoRedirect(curReq, app, s);
            let code = Status.code(Response.status(res));
            let isRedirect = code == 301 or code == 302 or code == 303 or code == 307 or code == 308;
            if (isRedirect and hopsRemaining > 0) {
                match Response.header("Location", res) {
                    case None => res
                    case Some(loc) =>
                        let nextReq = if (code == 307 or code == 308) {
                            Request.make(Request.method(curReq), loc)
                                |> Request.withHeaders(Request.headers(curReq))
                                |> Request.withBodyValue(Request.bodyValue(curReq))
                        } else {
                            Request.get(loc)
                        };
                        loop(nextReq, hopsRemaining - 1)
                }
            } else {
                res
            }
        };
        loop(req, maxHops)
    }

    // --- Ergonomic HTTP Verb Helpers ---

    pub def get(path: String, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(Request.get(path), app, s)

    pub def head(path: String, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(Request.head(path), app, s)

    pub def delete(path: String, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(Request.delete(path), app, s)

    pub def postText(path: String, body: String, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(
            Request.post(path)
                |> Request.withHeader("Content-Type", "text/plain")
                |> Request.withBody(body),
            app,
            s
        )

    pub def postBytes(
        path: String,
        contentType: String,
        data: Vector[Int8],
        app: App[ef],
        s: TestSession[r]
    ): Response \ ef + r =
        send(
            Request.post(path)
                |> Request.withHeader("Content-Type", contentType)
                |> Request.withBytes(data),
            app,
            s
        )

    pub def postForm(
        path: String,
        fields: List[(String, String)],
        app: App[ef],
        s: TestSession[r]
    ): Response \ ef + r =
        send(
            Request.post(path)
                |> Request.withHeader("Content-Type", "application/x-www-form-urlencoded")
                |> Request.withBody(Url.encodeQuery(fields)),
            app,
            s
        )

    pub def postMultipart(
        path: String,
        fields: List[(String, String)],
        files: List[UploadedFile],
        app: App[ef],
        s: TestSession[r]
    ): Response \ ef + r = {
        let boundary = "WeftSessionBoundary7MA4YWxkTrZu0gW";
        let payload = Multipart.encode(boundary, fields, files);
        send(
            Request.post(path)
                |> Request.withHeader("Content-Type", "multipart/form-data; boundary=${boundary}")
                |> Request.withBytes(payload),
            app,
            s
        )
    }

    pub def postJson(path: String, payload: Json, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(
            Request.post(path)
                |> Request.withHeader("Content-Type", "application/json")
                |> Request.withBody(Json.encode(payload)),
            app,
            s
        )

    pub def putJson(path: String, payload: Json, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(
            Request.put(path)
                |> Request.withHeader("Content-Type", "application/json")
                |> Request.withBody(Json.encode(payload)),
            app,
            s
        )

    pub def patchJson(path: String, payload: Json, app: App[ef], s: TestSession[r]): Response \ ef + r =
        send(
            Request.patch(path)
                |> Request.withHeader("Content-Type", "application/json")
                |> Request.withBody(Json.encode(payload)),
            app,
            s
        )

    ///
    /// Extracts a CSRF token from an HTML response (checks `<meta name="csrf-token" content="...">`
    /// and `<input ... name="_csrf" ... value="...">`).
    ///
    pub def extractCsrfToken(res: Response): Option[String] =
        TestClient.extractCsrfToken(res)

    // --- Internal Cookie Jar & Header Helpers ---

    def attachSessionState(req: Request, s: TestSession[r]): Request \ r = {
        let TestSession.TestSession(st) = s;
        // Merge default headers under explicit request headers (request wins)
        let mergedHeaders = Headers.merge(Ref.get(st#defaultHeaders), Request.headers(req));
        let r1 = Request.withHeaders(mergedHeaders, req);
        // Merge session cookies under explicit request cookies (request wins)
        let jar = Ref.get(st#cookies);
        Map.foldLeftWithKey((acc, name, value) ->
            if (Option.nonEmpty(Request.cookie(name, acc))) acc
            else Request.withCookie(name, value, acc)
        , r1, jar)
    }

    def absorbCookies(res: Response, s: TestSession[r]): Unit \ r = {
        let TestSession.TestSession(st) = s;
        let setCookies = Headers.getAll("Set-Cookie", Response.headers(res));
        List.forEach(rawHeader -> {
            let parts = String.splitOn({substr = ";"}, rawHeader) |> List.map(String.trim);
            match parts {
                case nameVal :: attrs =>
                    match String.indexOfLeft({substr = "="}, nameVal) {
                        case None => ()
                        case Some(idx) =>
                            let k = String.trim(String.sliceLeft({end = idx}, nameVal));
                            let v = String.trim(String.sliceRight({start = idx + 1}, nameVal));
                            if (String.isEmpty(k))
                                ()
                            else if (isExpiredCookie(attrs))
                                Ref.transform(m -> Map.remove(k, m), st#cookies)
                            else
                                Ref.transform(m -> Map.insert(k, v, m), st#cookies)
                    }
                case Nil => ()
            }
        }, setCookies)
    }

    def isExpiredCookie(attrs: List[String]): Bool =
        List.exists(attr -> {
            match String.indexOfLeft({substr = "="}, attr) {
                case None => false
                case Some(idx) =>
                    let k = String.toLowerCase(String.trim(String.sliceLeft({end = idx}, attr)));
                    let v = String.trim(String.sliceRight({start = idx + 1}, attr));
                    if (k == "max-age")
                        match Int32.fromString(v) {
                            case Some(n) => n <= 0
                            case None    => false
                        }
                    else
                        false
            }
        }, attrs)

}
