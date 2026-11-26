pub mod Weft.HttpClient {
    use Weft.Body
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Headers
    use Weft.HttpClient
    use Weft.HttpError
    use Weft.Json
    use Weft.Status

    import java.lang.Exception
    import java.net.URI
    import java.net.http.{HttpClient => JHttpClient}
    import java.net.http.{HttpClient$Redirect => JRedirect}
    import java.net.http.{HttpHeaders => JHttpHeaders}
    import java.net.http.{HttpRequest => JHttpRequest}
    import java.net.http.{HttpRequest$BodyPublishers => JBodyPublishers}
    import java.net.http.{HttpResponse$BodyHandlers => JBodyHandlers}
    import java.time.Duration
    import java.util.{List => JList}
    import java.util.{Map => JMap}

    ///
    /// Algebraic effect for outbound HTTP requests (payment gateways, email APIs,
    /// shipping calculators, OAuth providers, object storage).
    ///
    /// Production code handles this with `HttpClient.runWithJdk` (`IO`);
    /// tests handle it 100% purely with `HttpClient.runMock` or `HttpClient.runRecording`.
    ///
    pub eff HttpClient {
        def send(req: ClientRequest): Result[String, ClientResponse]
    }

    // --- Ergonomic Helpers ---

    pub def get(url: String): Result[String, ClientResponse] \ HttpClient =
        HttpClient.send(ClientRequest.get(url))

    pub def postJson(url: String, payload: Json): Result[String, ClientResponse] \ HttpClient =
        HttpClient.send(ClientRequest.postJson(url, payload))

    pub def postForm(url: String, fields: List[(String, String)]): Result[String, ClientResponse] \ HttpClient =
        HttpClient.send(ClientRequest.postForm(url, fields))

    ///
    /// Sends `req` and translates any transport failure into `502 Bad Gateway` via `HttpError`.
    ///
    pub def sendOrBadGateway(req: ClientRequest): ClientResponse \ {HttpClient, HttpError} =
        match HttpClient.send(req) {
            case Ok(res)  => res
            case Err(msg) => HttpError.raise(Status.badGateway(), "Upstream HTTP error: ${msg}")
        }

    // --- Pure Test Handlers ---

    ///
    /// 100% pure mock handler for `HttpClient` (zero sockets, zero `IO`).
    ///
    pub def runMock(
        responder: ClientRequest -> Result[String, ClientResponse] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - HttpClient) + ef2 =
        run {
            f()
        } with handler HttpClient {
            def send(req, k) = k(responder(req))
        }

    ///
    /// 100% pure mock handler that ALSO records every outbound `ClientRequest` in order,
    /// returning `(result, sentRequests)`.
    ///
    pub def runRecording(
        responder: ClientRequest -> Result[String, ClientResponse] \ ef2,
        f: Unit -> a \ ef1
    ): (a, List[ClientRequest]) \ (ef1 - HttpClient) + ef2 =
        region rc {
            let logRef = Ref.fresh(rc, Nil);
            let result = run {
                f()
            } with handler HttpClient {
                def send(req, k) = {
                    Ref.transform(xs -> req :: xs, logRef);
                    k(responder(req))
                }
            };
            (result, List.reverse(Ref.get(logRef)))
        }

    // --- Production JDK 21 HttpClient Handler ---

    ///
    /// Handles `HttpClient` using JDK 21's built-in `java.net.http.HttpClient`.
    ///
    pub def runWithJdk(f: Unit -> a \ ef): a \ (ef - HttpClient) + IO = {
        let b0 = JHttpClient.newBuilder();
        let b1 = b0.followRedirects(JRedirect.NORMAL);
        let b2 = b1.connectTimeout(Duration.ofSeconds(10i64));
        let client = b2.build();
        run {
            f()
        } with handler HttpClient {
            def send(req, k) = k(executeJdk(client, req))
        }
    }

    def executeJdk(client: JHttpClient, req: ClientRequest): Result[String, ClientResponse] \ IO =
        try {
            let uri = URI.create(ClientRequest.url(req));
            let b0 = JHttpRequest.newBuilder(uri);
            let timeoutMs = ClientRequest.timeoutMs(req);
            let b1 = if (timeoutMs > 0i64) b0.timeout(Duration.ofMillis(timeoutMs)) else b0;
            List.forEach(match (k, v) -> {
                let _ = b1.header(k, v);
                ()
            }, Headers.toList(ClientRequest.headers(req)));
            let bodyBytes = ClientRequest.bodyBytes(req);
            let publisher = if (Vector.isEmpty(bodyBytes))
                JBodyPublishers.noBody()
            else
                JBodyPublishers.ofByteArray(Vector.toArray(Static, bodyBytes));
            let methodStr = "${ClientRequest.method(req)}";
            let jReq = b1.method(methodStr, publisher).build();
            let bodyHandler = JBodyHandlers.ofByteArray();
            let jResp = client.send(jReq, bodyHandler);
            let status = jResp.statusCode();
            let respHeaders = readJdkHeaders(jResp.headers());
            let respArr: Array[Int8, IO] = jResp.body();
            let respBody = Body.bytes(Array.toVector(respArr));
            Ok(ClientResponse.make(status, respHeaders, respBody))
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                let msg = if (Object.isNull(rawMsg)) "HTTP client request failed" else rawMsg;
                Err(msg)
        }

    def readJdkHeaders(jHeaders: JHttpHeaders): Headers \ IO = {
        let m: JMap[String, JList[String]] = jHeaders.map();
        let keyIter = m.keySet().iterator();
        def loopKeys(acc: Headers): Headers \ IO = {
            if (keyIter.hasNext()) {
                let key: String = keyIter.next();
                let vals: JList[String] = m.get(key);
                let nextAcc = if (Object.isNull(vals))
                    acc
                else {
                    let valIter = vals.iterator();
                    def loopVals(hAcc: Headers): Headers \ IO = {
                        if (valIter.hasNext()) {
                            let v: String = valIter.next();
                            loopVals(Headers.add(key, v, hAcc))
                        } else {
                            hAcc
                        }
                    };
                    loopVals(acc)
                };
                loopKeys(nextAcc)
            } else {
                acc
            }
        };
        loopKeys(Headers.empty())
    }

}
