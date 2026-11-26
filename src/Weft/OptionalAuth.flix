pub mod Weft.OptionalAuth {
    use Weft.Auth
    use Weft.HttpError
    use Weft.OptionalAuth
    use Weft.Principal
    use Weft.Req
    use Weft.Session

    ///
    /// Capability effect representing an optional authenticated caller (logged-in user
    /// or anonymous guest). Ideal for public storefront pages that adapt when signed in.
    ///
    pub eff OptionalAuth {
        def currentPrincipal(): Option[Principal]
    }

    pub def current(): Option[Principal] \ OptionalAuth =
        OptionalAuth.currentPrincipal()

    pub def isAuthenticated(): Bool \ OptionalAuth =
        Option.nonEmpty(current())

    pub def userId(): Option[String] \ OptionalAuth =
        Option.map(Principal.id, current())

    pub def userName(): Option[String] \ OptionalAuth =
        Option.map(Principal.name, current())

    pub def hasRole(role: String): Bool \ OptionalAuth =
        match current() {
            case Some(p) => Principal.hasRole(role, p)
            case None    => false
        }

    ///
    /// Upgrades `OptionalAuth` to a required `Principal`, raising `401 Unauthorized` for guests.
    ///
    pub def requireAuth(): Principal \ {OptionalAuth, HttpError} =
        current() |> HttpError.orUnauthorized("Authentication required")

    // --- Handlers ---

    ///
    /// Discharges `OptionalAuth` with an explicit `Option[Principal]` (great for tests).
    ///
    pub def runWith(pOpt: Option[Principal], f: Unit -> a \ ef): a \ (ef - OptionalAuth) =
        run {
            f()
        } with handler OptionalAuth {
            def currentPrincipal(k) = k(pOpt)
        }

    ///
    /// Discharges `OptionalAuth` as an anonymous guest (`None`).
    ///
    pub def runAnonymous(f: Unit -> a \ ef): a \ (ef - OptionalAuth) =
        runWith(None, f)

    ///
    /// Discharges `OptionalAuth` by computing `Option[Principal]` once via `load`.
    ///
    pub def runWithLoader(
        load: Unit -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - OptionalAuth) + ef2 = {
        let pOpt = load();
        runWith(pOpt, f)
    }

    ///
    /// Discharges `OptionalAuth` by checking a Bearer token in `Req` if present.
    /// Invalid or missing tokens resolve cleanly to `None` instead of failing with `401`.
    ///
    pub def runWithBearer(
        verify: String -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - OptionalAuth) + Req + ef2 = {
        let pOpt = match Req.bearerToken() {
            case Some(tok) => verify(tok)
            case None      => None
        };
        runWith(pOpt, f)
    }

    ///
    /// Discharges `OptionalAuth` by loading the logged-in user (if any) from `Session`.
    ///
    pub def runWithSession(
        loadUser: String -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - OptionalAuth) + Session + ef2 =
        runWithSessionKey(Auth.sessionUserIdKey(), loadUser, f)

    ///
    /// Like `runWithSession`, using a custom session key.
    ///
    pub def runWithSessionKey(
        key: String,
        loadUser: String -> Option[Principal] \ ef2,
        f: Unit -> a \ ef1
    ): a \ (ef1 - OptionalAuth) + Session + ef2 = {
        let pOpt = match Session.get(key) {
            case Some(uid) => loadUser(uid)
            case None      => None
        };
        runWith(pOpt, f)
    }

}
