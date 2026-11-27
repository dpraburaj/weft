pub mod Weft.Mailer {
    use Weft.ClientRequest
    use Weft.ClientResponse
    use Weft.Email
    use Weft.HttpClient
    use Weft.Job
    use Weft.JobError
    use Weft.JobQueue
    use Weft.JobRegistry
    use Weft.Json
    use Weft.Mailer
    use Weft.MailError

    ///
    /// Algebraic effect for sending transactional emails and notifications
    /// (inspired by Laravel's `Mail`).
    ///
    /// Drivers / Handlers:
    /// - `Mailer.runPure` (100% pure deterministic sink for tests)
    /// - `Mailer.runRecording` (Laravel's `Mail::fake()` — captures every sent `Email`)
    /// - `Mailer.runFailing` (simulates delivery failures in tests)
    /// - `Mailer.runLogging` (dev driver logging emails via `Logger`)
    /// - `Mailer.runWithHttpApi` / `Mailer.runWithResend` (HTTP API providers via `HttpClient`)
    ///
    pub eff Mailer {
        def rawSend(email: Email): Result[String, String]
    }

    // --- Ergonomic Helpers ---

    ///
    /// Sends `email`, returning the provider message ID or raising `MailError`.
    ///
    pub def send(email: Email): String \ {Mailer, MailError} =
        match Mailer.rawSend(email) {
            case Ok(msgId) => msgId
            case Err(msg)  => MailError.fail(msg)
        }

    ///
    /// Sends `email` and returns `Result[String, String]` directly without raising `MailError`.
    ///
    pub def sendResult(email: Email): Result[String, String] \ Mailer =
        Mailer.rawSend(email)

    ///
    /// Built-in background job kind used by `Mailer.queue` and `Mailer.registerJobHandler`.
    ///
    pub def jobKind(): String = "weft.mail.send"

    ///
    /// Enqueues `email` for asynchronous background delivery on the `"default"` queue
    /// (like Laravel's `Mail::queue(...)`).
    ///
    pub def queue(email: Email): Job \ JobQueue =
        JobQueue.dispatch(jobKind(), Email.toJson(email))

    ///
    /// Enqueues `email` for asynchronous background delivery on a named `queueName`.
    ///
    pub def queueOn(queueName: String, email: Email): Job \ JobQueue =
        JobQueue.dispatchOn(queueName, jobKind(), Email.toJson(email))

    ///
    /// Registers the built-in `"weft.mail.send"` job handler on `reg`, decoding the
    /// queued `Email` payload and delivering it via `Mailer` (retrying via `JobError` on failure).
    ///
    pub def registerJobHandler(reg: JobRegistry[ef]): JobRegistry[ef + {Mailer, JobError}] =
        JobRegistry.register(jobKind(), job -> {
            match Email.fromJson(Job.payload(job)) {
                case Err(errMsg) =>
                    JobError.fail("Invalid queued email payload: ${errMsg}")
                case Ok(email) =>
                    MailError.runToJobError(() -> {
                        let _ = send(email);
                        ()
                    })
            }
        }, reg)

    // --- Pure & Test Drivers ---

    ///
    /// 100% pure no-op `Mailer` handler returning deterministic message IDs (`"msg-1"`, `"msg-2"`, ...).
    ///
    pub def runPure(f: Unit -> a \ ef): a \ (ef - Mailer) =
        let (res, _) = runRecording(f);
        res

    ///
    /// 100% pure recording `Mailer` handler (Laravel's `Mail::fake()`), returning
    /// `(result, sentEmailsInOrder)`.
    ///
    pub def runRecording(f: Unit -> a \ ef): (a, List[Email]) \ (ef - Mailer) =
        region rc {
            let nextId = Ref.fresh(rc, 1);
            let sentRef = Ref.fresh(rc, Nil);
            let res = run {
                f()
            } with handler Mailer {
                def rawSend(email, k) = {
                    let id = Ref.get(nextId);
                    Ref.put(id + 1, nextId);
                    Ref.transform(xs -> email :: xs, sentRef);
                    k(Ok("msg-${id}"))
                }
            };
            (res, List.reverse(Ref.get(sentRef)))
        }

    ///
    /// 100% pure failing `Mailer` handler for testing delivery errors and retries.
    ///
    pub def runFailing(reason: String, f: Unit -> a \ ef): a \ (ef - Mailer) =
        run {
            f()
        } with handler Mailer {
            def rawSend(_email, k) = k(Err(reason))
        }

    // --- Development Log Driver ---

    ///
    /// Development `Mailer` handler (like Laravel's `log` mail driver) that logs every
    /// outgoing email via `Logger.info` without sending real network requests.
    ///
    pub def runLogging(f: Unit -> a \ ef): a \ (ef - Mailer) + Logger =
        region rc {
            let nextId = Ref.fresh(rc, 1);
            run {
                f()
            } with handler Mailer {
                def rawSend(email, k) = {
                    let id = Ref.get(nextId);
                    Ref.put(id + 1, nextId);
                    let toStr = String.intercalate(", ", Email.to(email));
                    let preview = match (Email.textBody(email), Email.htmlBody(email)) {
                        case (Some(t), _) => t
                        case (None, Some(h)) => h
                        case (None, None) => "(empty body)"
                    };
                    Logger.info("[Mail #log-${id}] From: ${Email.sender(email)} | To: ${toStr} | Subject: ${Email.subject(email)} | Body: ${preview}");
                    k(Ok("log-${id}"))
                }
            }
        }

    // --- HTTP API Providers (built on `Weft.HttpClient`) ---

    ///
    /// Generic HTTP API `Mailer` driver built on `Weft.HttpClient`.
    /// Sends `POST <endpoint>` with `Authorization: Bearer <apiKey>` and JSON encoded by `encode`.
    /// Extracts `"id"` from a JSON response body if present.
    ///
    pub def runWithHttpApi(
        endpoint: String,
        apiKey: String,
        encode: Email -> Json \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - Mailer) + ef2 + HttpClient =
        run {
            f()
        } with handler Mailer {
            def rawSend(email, k) = {
                let payload = encode(email);
                let req = ClientRequest.postJson(endpoint, payload)
                    |> ClientRequest.withBearer(apiKey);
                let res = match HttpClient.send(req) {
                    case Err(errMsg) =>
                        Err("Mail HTTP transport error: ${errMsg}")
                    case Ok(resp) =>
                        if (ClientResponse.isSuccess(resp)) {
                            let msgId = match ClientResponse.parseJson(resp) {
                                case Ok(j) =>
                                    Option.flatMap(Json.asString, Json.getField("id", j))
                                        |> Option.getWithDefault("http-ok")
                                case Err(_) =>
                                    "http-ok"
                            };
                            Ok(msgId)
                        } else {
                            Err("Mail API returned HTTP ${ClientResponse.status(resp)}: ${ClientResponse.body(resp)}")
                        }
                };
                k(res)
            }
        }

    ///
    /// Ready-to-use Resend (`https://api.resend.com/emails`) `Mailer` driver built on `HttpClient`.
    /// Testable 100% purely by pairing with `HttpClient.runRecording`!
    ///
    pub def runWithResend(apiKey: String, f: Unit -> a \ ef): a \ (ef - Mailer) + HttpClient =
        runWithHttpApi("https://api.resend.com/emails", apiKey, Email.toJson, f)

}
