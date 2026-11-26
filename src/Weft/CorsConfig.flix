pub mod Weft.CorsConfig {
    use Weft.CorsConfig

    ///
    /// Configuration for Cross-Origin Resource Sharing (`Middleware.cors`).
    ///
    pub enum CorsConfig {
        case CorsConfig({
            allowOrigin      = String,
            allowMethods     = List[String],
            allowHeaders     = List[String],
            exposeHeaders    = List[String],
            allowCredentials = Bool,
            maxAgeSeconds    = Option[Int32]
        })
    }

    ///
    /// A permissive CORS configuration suitable for local development and public APIs.
    ///
    pub def permissive(): CorsConfig =
        CorsConfig.CorsConfig({
            allowOrigin      = "*",
            allowMethods     = "GET" :: "POST" :: "PUT" :: "PATCH" :: "DELETE" :: "OPTIONS" :: Nil,
            allowHeaders     = "Content-Type" :: "Authorization" :: "X-Requested-With" :: Nil,
            exposeHeaders    = Nil,
            allowCredentials = false,
            maxAgeSeconds    = Some(86400)
        })

    pub def withOrigin(origin: String, cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowOrigin = origin | r })

    pub def withMethods(ms: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowMethods = ms | r })

    pub def withHeaders(hs: List[String], cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowHeaders = hs | r })

    pub def withCredentials(flag: Bool, cfg: CorsConfig): CorsConfig =
        let CorsConfig.CorsConfig(r) = cfg;
        CorsConfig.CorsConfig({ allowCredentials = flag | r })

}
