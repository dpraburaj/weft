pub mod Weft.StaticConfig {
    use Weft.StaticConfig

    ///
    /// Configuration for `Weft.StaticFiles`.
    ///
    pub enum StaticConfig {
        case StaticConfig({
            indexFile      = Option[String],
            cacheControl   = Option[String],
            enableEtag     = Bool,
            enableDotfiles = Bool
        })
    }

    ///
    /// Sensible defaults: serves `index.html`, caches for 1 hour, enables `ETag`,
    /// and blocks dotfiles (`.env`, `.git`, etc.).
    ///
    pub def default(): StaticConfig =
        StaticConfig.StaticConfig({
            indexFile      = Some("index.html"),
            cacheControl   = Some("public, max-age=3600"),
            enableEtag     = true,
            enableDotfiles = false
        })

    pub def indexFile(cfg: StaticConfig): Option[String]    = let StaticConfig.StaticConfig(r) = cfg; r#indexFile
    pub def cacheControl(cfg: StaticConfig): Option[String] = let StaticConfig.StaticConfig(r) = cfg; r#cacheControl
    pub def enableEtag(cfg: StaticConfig): Bool             = let StaticConfig.StaticConfig(r) = cfg; r#enableEtag
    pub def enableDotfiles(cfg: StaticConfig): Bool         = let StaticConfig.StaticConfig(r) = cfg; r#enableDotfiles

    pub def withIndexFile(idx: Option[String], cfg: StaticConfig): StaticConfig =
        let StaticConfig.StaticConfig(r) = cfg;
        StaticConfig.StaticConfig({ indexFile = idx | r })

    pub def withCacheControl(cc: Option[String], cfg: StaticConfig): StaticConfig =
        let StaticConfig.StaticConfig(r) = cfg;
        StaticConfig.StaticConfig({ cacheControl = cc | r })

    pub def withEtag(enabled: Bool, cfg: StaticConfig): StaticConfig =
        let StaticConfig.StaticConfig(r) = cfg;
        StaticConfig.StaticConfig({ enableEtag = enabled | r })

    pub def withDotfiles(enabled: Bool, cfg: StaticConfig): StaticConfig =
        let StaticConfig.StaticConfig(r) = cfg;
        StaticConfig.StaticConfig({ enableDotfiles = enabled | r })

}
