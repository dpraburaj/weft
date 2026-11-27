pub mod Weft.CompressionConfig {
    use Weft.CompressionConfig

    ///
    /// Configuration for `Middleware.compress` / `Middleware.compressWith`.
    ///
    pub enum CompressionConfig {
        case CompressionConfig({
            minBytes      = Int32,
            enableGzip    = Bool,
            enableDeflate = Bool
        })
    }

    instance Eq[CompressionConfig] {
        pub def eq(a: CompressionConfig, b: CompressionConfig): Bool =
            let CompressionConfig.CompressionConfig(x) = a;
            let CompressionConfig.CompressionConfig(y) = b;
            x#minBytes == y#minBytes and
            x#enableGzip == y#enableGzip and
            x#enableDeflate == y#enableDeflate
    }

    ///
    /// Default compression configuration: compress eligible responses >= 256 bytes using
    /// `gzip` (preferred) or `deflate`.
    ///
    pub def default(): CompressionConfig =
        CompressionConfig.CompressionConfig({
            minBytes      = 256,
            enableGzip    = true,
            enableDeflate = true
        })

    pub def minBytes(cfg: CompressionConfig): Int32     = let CompressionConfig.CompressionConfig(r) = cfg; r#minBytes
    pub def enableGzip(cfg: CompressionConfig): Bool    = let CompressionConfig.CompressionConfig(r) = cfg; r#enableGzip
    pub def enableDeflate(cfg: CompressionConfig): Bool = let CompressionConfig.CompressionConfig(r) = cfg; r#enableDeflate

    pub def withMinBytes(n: Int32, cfg: CompressionConfig): CompressionConfig =
        let CompressionConfig.CompressionConfig(r) = cfg;
        CompressionConfig.CompressionConfig({ minBytes = Int32.max(0, n) | r })

    pub def withGzip(flag: Bool, cfg: CompressionConfig): CompressionConfig =
        let CompressionConfig.CompressionConfig(r) = cfg;
        CompressionConfig.CompressionConfig({ enableGzip = flag | r })

    pub def withDeflate(flag: Bool, cfg: CompressionConfig): CompressionConfig =
        let CompressionConfig.CompressionConfig(r) = cfg;
        CompressionConfig.CompressionConfig({ enableDeflate = flag | r })

}
