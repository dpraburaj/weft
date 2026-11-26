pub mod Weft.Auth {
    use Weft.Auth
    use Weft.HttpError
    use Weft.Principal
    use Weft.Req

    ///
    /// Capability effect representing an authenticated caller.
    ///
    pub eff Auth {
        def principal(): Principal
    }

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
    /// Discharges `Auth` by supplying a known `Principal` (ideal for tests and internal calls).
    ///
    pub def runWithPrincipal(p: Principal, f: Unit -> a \ ef): a \ (ef - Auth) =
        run {
            f()
        } with handler Auth {
            def principal(k) = k(p)
        }

    ///
    /// Discharges `Auth` by extracting a Bearer token from `Req`, verifying it with `verify`,
    /// and raising `401 Unauthorized` via `HttpError` if missing or rejected.
    ///
    pub def runWithBearer(verify: String -> Option[Principal] \ ef2, f: Unit -> a \ ef1): a \ (ef1 - Auth) + {Req, HttpError} + ef2 =
        let token = Req.requireBearerToken();
        let p = verify(token) |> HttpError.orUnauthorized("Invalid or expired Bearer token");
        runWithPrincipal(p, f)

}
