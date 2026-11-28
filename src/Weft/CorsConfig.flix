pub mod Weft.CorsConfig {
    use Weft.CorsConfig

    ///
    /// Configuration for Cross-Origin Resource Sharing (`Middleware.cors`).
    ///
    pub enum CorsConfig {
        case CorsConfig({
            allowOrigins     = List[String],
            allowMethods     = List[String],
            allowHeaders     = List[String],
            exposeHeaders    = List[String],
            allowCredentials = Bool,
            maxAgeSeconds    = Option[Int32]
        })
    }

    ///
    /// A permissive CORS configuration (`Access-Control-Allow-Origin: *`, credentials disabled)
    /// suitable for local development and public unauthenticated APIs.
    ///
    pub def permissive(): CorsConfig =
        CorsConfig.CorsConfig({
            allowOrigins     = "*" :: Nil,
            allowMethods     = "GET" :: "POST" :: "PUT" :: "PATCH" :: "DELETE" :: "OPTIONS" :: Nil,
            allowHeaders     = "Content-Type" :: "Authorization" :: "X-Requested-With" :: Nil,
            exposeHeaders    = Nil,
            allowCredentials = false,
            maxAgeSeconds    = Some(86400)
        })

    ///
    /// Creates a production CORS configuration restricted to an explicit origin allowlist
    /// (e.g. `"https://app.example.com" :: "https://admin.example.com" :: Nil`).
    ///
    pub def origins(allowed: List[String]): CorsConfig =
        permissive() |> withOrigins(allowed)

    pub def withOrigin(origin: String, cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowOrigins = origin :: Nil | r })

    pub def withOrigins(allowed: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowOrigins = allowed | r })

    pub def withMethods(ms: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowMethods = ms | r })

    pub def withHeaders(hs: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowHeaders = hs | r })

    pub def withExposeHeaders(hs: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ exposeHeaders = hs | r })

    pub def withCredentials(flag: Bool, cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowCredentials = flag | r })

    pub def withMaxAgeSeconds(secs: Int32, cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ maxAgeSeconds = Some(Int32.max(0, secs)) | r })

}
