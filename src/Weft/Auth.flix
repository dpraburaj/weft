pub mod Weft.Auth {
    use Weft.Auth
    use Weft.HttpError
    use Weft.Principal
    use Weft.Req
    use Weft.Session

    ///
    /// Capability effect representing an authenticated caller.
    ///
    pub eff Auth {
        def principal(): Principal
    }

    ///
    /// Default session key storing the logged-in user's ID.
    ///
    pub def sessionUserIdKey(): String = "_weft_auth_user_id"

    pub def current(): Principal \ Auth             = Auth.principal()
    pub def userId(): String \ Auth                 = Principal.id(Auth.principal())
    pub def userName(): String \ Auth               = Principal.name(Auth.principal())
    pub def roles(): List[String] \ Auth            = Principal.roles(Auth.principal())
    pub def hasRole(role: String): Bool \ Auth      = Principal.hasRole(role, Auth.principal())

    ///
    /// Ensures the authenticated principal has `role`, raising `403 Forbidden` otherwise.
    ///
    pub def requireRole(role: String): Unit \ {Auth, HttpError} =
        if (hasRole(role))
            ()
        else
            HttpError.forbidden("Missing required role '${role}'")

    ///
    /// Logs a user into the current `Session`, rotating the session ID first to prevent
    /// session fixation while preserving pre-login session data (such as a guest cart).
    ///
    pub def loginSession(uid: String): Unit \ Session = {
        let _ = Session.regenerate();
        Session.put(sessionUserIdKey(), uid)
    }

    ///
    /// Logs out the current user by destroying the active `Session`.
    ///
    pub def logoutSession(): Unit \ Session =
        Session.destroy()

    ///
    /// Discharges `Auth` by supplying a known `Principal` (ideal for tests and internal calls).
    ///
    pub def runWithPrincipal(p: Principal, f: Unit -> a \ ef): a \ (ef - Auth) =
        run {
            f()
        } with handler Auth {
            def principal(k) = k(p)
        }

    ///
    /// Discharges `Auth` by invoking a generic principal loader `load`, raising
    /// `401 Unauthorized` via `HttpError` if `None` is returned.
    ///
    pub def runWithLoader(
        load: Unit -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - Auth) + HttpError + ef2 = {
        let p = load() |> HttpError.orUnauthorized("Authentication required");
        runWithPrincipal(p, f)
    }

    ///
    /// Discharges `Auth` by extracting a Bearer token from `Req`, verifying it with `verify`,
    /// and raising `401 Unauthorized` via `HttpError` if missing or rejected.
    ///
    pub def runWithBearer(verify: String -> Option[Principal] \ ef2, f: Unit -> a \ ef1): a \ (ef1 - Auth) + {Req, HttpError} + ef2 =
        let token = Req.requireBearerToken();
        let p = verify(token) |> HttpError.orUnauthorized("Invalid or expired Bearer token");
        runWithPrincipal(p, f)

    ///
    /// Discharges `Auth` by reading the logged-in user ID from `Session` (under `sessionUserIdKey()`),
    /// resolving it via `loadUser`, and raising `401 Unauthorized` if absent or unknown.
    ///
    pub def runWithSession(
        loadUser: String -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - Auth) + {Session, HttpError} + ef2 =
        runWithSessionKey(sessionUserIdKey(), loadUser, f)

    ///
    /// Like `runWithSession`, using a custom session key for the user ID.
    ///
    pub def runWithSessionKey(
        key: String,
        loadUser: String -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - Auth) + {Session, HttpError} + ef2 = {
        let uid = Session.get(key) |> HttpError.orUnauthorized("Authentication required");
        let p = loadUser(uid) |> HttpError.orUnauthorized("Invalid or expired user session");
        runWithPrincipal(p, f)
    }

}
