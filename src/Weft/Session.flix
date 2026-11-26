pub mod Weft.Session {
    use Time.Clock
    use Weft.App
    use Weft.Cookie
    use Weft.Random
    use Weft.Request
    use Weft.Response
    use Weft.Session
    use Weft.SessionConfig
    use Weft.SessionData
    use Weft.SessionStore

    ///
    /// Ambient algebraic effect for cookie-backed HTTP sessions with flash messages
    /// and session-ID rotation (to prevent session fixation on login).
    ///
    /// Sessions are created lazily: anonymous visitors who never mutate the session
    /// do not trigger `SessionStore.saveSession` or emit a `Set-Cookie` header.
    ///
    pub eff Session {
        def sessionId(): String
        def get(key: String): Option[String]
        def put(key: String, value: String): Unit
        def remove(key: String): Unit
        def clear(): Unit
        def regenerate(): String
        def putFlash(key: String, message: String): Unit
        def takeFlash(key: String): Option[String]
        def peekFlashes(): Map[String, String]
        def destroy(): Unit
    }

    ///
    /// Convenience helper: checks whether `key` exists in the current session.
    ///
    pub def contains(key: String): Bool \ Session =
        Option.nonEmpty(Session.get(key))

    ///
    /// Convenience helper: gets `key` from the session or returns `defaultVal`.
    ///
    pub def getOrDefault(key: String, defaultVal: String): String \ Session =
        Option.getWithDefault(defaultVal, Session.get(key))

    ///
    /// App-level middleware that discharges the `Session` effect using signed cookies
    /// and the configured `SessionStore`.
    ///
    /// Place AFTER `Middleware.errorJson` / `Middleware.errorHtml` so error responses
    /// and redirects still persist flash messages and session updates cleanly.
    ///
    pub def middleware(
        cfg: SessionConfig,
        app: App[ef]
    ): App[(ef - Session) + {SessionStore, Random, Clock}] = req ->
        runWithRequest(cfg, req, () -> app(req))

    ///
    /// Runs `f` with the `Session` effect populated from `req`'s signed session cookie,
    /// persisting any mutations to `SessionStore` and attaching the `Set-Cookie` header
    /// to the returned `Response`.
    ///
    pub def runWithRequest(
        cfg: SessionConfig,
        req: Request,
        f: Unit -> Response \ ef
    ): Response \ (ef - Session) + {SessionStore, Random, Clock} = {
        let nowMs = Clock.now();
        let incomingSid = Request.cookie(SessionConfig.cookieName(cfg), req)
            |> Option.flatMap(Cookie.verifySigned(SessionConfig.secret(cfg)));
        let loadedOpt = match incomingSid {
            case Some(sid) => SessionStore.loadSession(sid, nowMs)
            case None      => None
        };

        region rc {
            let initId = Option.map(SessionData.id, loadedOpt);
            let initValues = match loadedOpt {
                case Some(s) => SessionData.values(s)
                case None    => Map.empty()
            };
            let initFlashes = match loadedOpt {
                case Some(s) => SessionData.flashes(s)
                case None    => Map.empty()
            };
            let initCreatedAt = match loadedOpt {
                case Some(s) => SessionData.createdAtMs(s)
                case None    => nowMs
            };

            let idRef = Ref.fresh(rc, initId);
            let valuesRef = Ref.fresh(rc, initValues);
            let flashesRef = Ref.fresh(rc, initFlashes);
            let createdAtRef = Ref.fresh(rc, initCreatedAt);
            let dirtyRef = Ref.fresh(rc, false);
            let destroyedRef = Ref.fresh(rc, false);
            let staleIdsRef = Ref.fresh(rc, Nil);

            let res = run {
                f()
            } with handler Session {
                def sessionId(k) = {
                    let sid = match Ref.get(idRef) {
                        case Some(existing) => existing
                        case None =>
                            let fresh = Random.tokenBase64Url(32);
                            Ref.put(Some(fresh), idRef);
                            Ref.put(true, dirtyRef);
                            Ref.put(false, destroyedRef);
                            fresh
                    };
                    k(sid)
                }
                def get(key, k) =
                    k(Map.get(key, Ref.get(valuesRef)))
                def put(key, value, k) = {
                    Ref.transform(m -> Map.insert(key, value, m), valuesRef);
                    Ref.put(true, dirtyRef);
                    Ref.put(false, destroyedRef);
                    k()
                }
                def remove(key, k) = {
                    if (Map.memberOf(key, Ref.get(valuesRef))) {
                        Ref.transform(m -> Map.remove(key, m), valuesRef);
                        Ref.put(true, dirtyRef)
                    } else ();
                    k()
                }
                def clear(k) = {
                    Ref.put(Map.empty(), valuesRef);
                    Ref.put(Map.empty(), flashesRef);
                    Ref.put(true, dirtyRef);
                    k()
                }
                def regenerate(k) = {
                    match Ref.get(idRef) {
                        case Some(oldId) => Ref.transform(xs -> oldId :: xs, staleIdsRef)
                        case None        => ()
                    };
                    let newId = Random.tokenBase64Url(32);
                    Ref.put(Some(newId), idRef);
                    Ref.put(true, dirtyRef);
                    Ref.put(false, destroyedRef);
                    k(newId)
                }
                def putFlash(key, message, k) = {
                    Ref.transform(m -> Map.insert(key, message, m), flashesRef);
                    Ref.put(true, dirtyRef);
                    Ref.put(false, destroyedRef);
                    k()
                }
                def takeFlash(key, k) = {
                    let fls = Ref.get(flashesRef);
                    match Map.get(key, fls) {
                        case None => k(None)
                        case Some(msg) =>
                            Ref.put(Map.remove(key, fls), flashesRef);
                            Ref.put(true, dirtyRef);
                            k(Some(msg))
                    }
                }
                def peekFlashes(k) =
                    k(Ref.get(flashesRef))
                def destroy(k) = {
                    match Ref.get(idRef) {
                        case Some(oldId) => Ref.transform(xs -> oldId :: xs, staleIdsRef)
                        case None        => ()
                    };
                    Ref.put(None, idRef);
                    Ref.put(Map.empty(), valuesRef);
                    Ref.put(Map.empty(), flashesRef);
                    Ref.put(false, dirtyRef);
                    Ref.put(true, destroyedRef);
                    k()
                }
            };

            // Delete any rotated or destroyed session IDs from the store
            List.forEach(oldId -> SessionStore.deleteSession(oldId), Ref.get(staleIdsRef));

            if (Ref.get(destroyedRef)) {
                let expired = buildExpiredCookie(cfg);
                Response.withCookie(expired, res)
            } else if (Ref.get(dirtyRef)) {
                let finalId = match Ref.get(idRef) {
                    case Some(sid) => sid
                    case None      => Random.tokenBase64Url(32)
                };
                let saveNow = Clock.now();
                let ttlMs = Int32.toInt64(SessionConfig.ttlSeconds(cfg)) * 1000i64;
                let data = SessionData.make(
                    finalId,
                    Ref.get(valuesRef),
                    Ref.get(flashesRef),
                    saveNow + ttlMs,
                    Ref.get(createdAtRef),
                    saveNow
                );
                SessionStore.saveSession(data);
                let cookie = buildSessionCookie(cfg, finalId);
                Response.withCookie(cookie, res)
            } else {
                res
            }
        }
    }

    // --- Internal Cookie Builders ---

    def buildSessionCookie(cfg: SessionConfig, sessionId: String): Cookie = {
        let c0 = Cookie.makeSigned(SessionConfig.secret(cfg), SessionConfig.cookieName(cfg), sessionId)
            |> Cookie.withPath(SessionConfig.path(cfg))
            |> Cookie.withMaxAge(SessionConfig.ttlSeconds(cfg))
            |> Cookie.withHttpOnly(SessionConfig.httpOnly(cfg))
            |> Cookie.withSecure(SessionConfig.secure(cfg))
            |> Cookie.withSameSite(SessionConfig.sameSite(cfg));
        match SessionConfig.domain(cfg) {
            case Some(d) => Cookie.withDomain(d, c0)
            case None    => c0
        }
    }

    def buildExpiredCookie(cfg: SessionConfig): Cookie = {
        let c0 = Cookie.expired(SessionConfig.cookieName(cfg))
            |> Cookie.withPath(SessionConfig.path(cfg))
            |> Cookie.withHttpOnly(SessionConfig.httpOnly(cfg))
            |> Cookie.withSecure(SessionConfig.secure(cfg))
            |> Cookie.withSameSite(SessionConfig.sameSite(cfg));
        match SessionConfig.domain(cfg) {
            case Some(d) => Cookie.withDomain(d, c0)
            case None    => c0
        }
    }

}
