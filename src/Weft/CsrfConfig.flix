pub mod Weft.CsrfConfig {
    use Weft.CsrfConfig

    ///
    /// Configuration for synchronizer-token CSRF protection (`Weft.Csrf` & `Middleware.csrf`).
    ///
    pub enum CsrfConfig {
        case CsrfConfig({
            fieldName  = String,
            headerName = String,
            sessionKey = String
        })
    }

    ///
    /// Sensible defaults: form field `"_csrf"`, header `"X-CSRF-Token"`,
    /// and session key `"_weft_csrf_token"`.
    ///
    pub def default(): CsrfConfig =
        CsrfConfig.CsrfConfig({
            fieldName  = "_csrf",
            headerName = "X-CSRF-Token",
            sessionKey = "_weft_csrf_token"
        })

    pub def fieldName(cfg: CsrfConfig): String  = let CsrfConfig.CsrfConfig(r) = cfg; r#fieldName
    pub def headerName(cfg: CsrfConfig): String = let CsrfConfig.CsrfConfig(r) = cfg; r#headerName
    pub def sessionKey(cfg: CsrfConfig): String = let CsrfConfig.CsrfConfig(r) = cfg; r#sessionKey

    pub def withFieldName(name: String, cfg: CsrfConfig): CsrfConfig =
        let CsrfConfig.CsrfConfig(r) = cfg;
        CsrfConfig.CsrfConfig({ fieldName = name | r })

    pub def withHeaderName(name: String, cfg: CsrfConfig): CsrfConfig =
        let CsrfConfig.CsrfConfig(r) = cfg;
        CsrfConfig.CsrfConfig({ headerName = name | r })

    pub def withSessionKey(key: String, cfg: CsrfConfig): CsrfConfig =
        let CsrfConfig.CsrfConfig(r) = cfg;
        CsrfConfig.CsrfConfig({ sessionKey = key | r })

}
