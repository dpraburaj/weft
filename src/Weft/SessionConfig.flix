pub mod Weft.SessionConfig {
    use Weft.SameSite
    use Weft.SessionConfig

    ///
    /// Configuration for signed cookie-backed sessions (`Middleware.session`).
    ///
    pub enum SessionConfig {
        case SessionConfig({
            cookieName = String,
            secret     = String,
            ttlSeconds = Int32,
            path       = String,
            domain     = Option[String],
            httpOnly   = Bool,
            secure     = Bool,
            sameSite   = SameSite
        })
    }

    ///
    /// Creates a `SessionConfig` signed with `secret` and sensible defaults:
    /// - cookie `"weft_session"`, `Path=/`, `HttpOnly=true`, `SameSite=Lax`
    /// - 7-day TTL (`604800` seconds)
    /// - `Secure=false` by default for local HTTP dev (call `withSecure(true)` in HTTPS prod!)
    ///
    pub def default(secret: String): SessionConfig =
        SessionConfig.SessionConfig({
            cookieName = "weft_session",
            secret     = secret,
            ttlSeconds = 604800,
            path       = "/",
            domain     = None,
            httpOnly   = true,
            secure     = false,
            sameSite   = SameSite.Lax
        })

    pub def cookieName(cfg: SessionConfig): String     = let SessionConfig.SessionConfig(r) = cfg; r#cookieName
    pub def secret(cfg: SessionConfig): String         = let SessionConfig.SessionConfig(r) = cfg; r#secret
    pub def ttlSeconds(cfg: SessionConfig): Int32      = let SessionConfig.SessionConfig(r) = cfg; r#ttlSeconds
    pub def path(cfg: SessionConfig): String           = let SessionConfig.SessionConfig(r) = cfg; r#path
    pub def domain(cfg: SessionConfig): Option[String] = let SessionConfig.SessionConfig(r) = cfg; r#domain
    pub def httpOnly(cfg: SessionConfig): Bool         = let SessionConfig.SessionConfig(r) = cfg; r#httpOnly
    pub def secure(cfg: SessionConfig): Bool           = let SessionConfig.SessionConfig(r) = cfg; r#secure
    pub def sameSite(cfg: SessionConfig): SameSite     = let SessionConfig.SessionConfig(r) = cfg; r#sameSite

    pub def withCookieName(name: String, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ cookieName = name | r })

    pub def withTtlSeconds(secs: Int32, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ ttlSeconds = secs | r })

    pub def withPath(p: String, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ path = p | r })

    pub def withDomain(d: String, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ domain = Some(d) | r })

    pub def withHttpOnly(flag: Bool, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ httpOnly = flag | r })

    pub def withSecure(flag: Bool, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ secure = flag | r })

    pub def withSameSite(ss: SameSite, cfg: SessionConfig): SessionConfig =
        let SessionConfig.SessionConfig(r) = cfg;
        SessionConfig.SessionConfig({ sameSite = ss | r })

}
