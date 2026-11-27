pub mod Weft.TlsConfig {
    use Weft.TlsConfig

    import java.io.FileInputStream
    import java.lang.Exception
    import java.security.KeyStore
    import java.security.SecureRandom
    import javax.net.ssl.KeyManagerFactory
    import javax.net.ssl.SSLContext
    import javax.net.ssl.TrustManager

    ///
    /// TLS / HTTPS configuration for `Weft.Server`.
    ///
    /// Supports loading a PKCS12 (`.p12` / `.pfx`) or JKS keystore from disk, or supplying
    /// a pre-built `javax.net.ssl.SSLContext` (for custom trust stores / mTLS / tests).
    ///
    pub enum TlsConfig {
        case KeyStore({
            path          = String,
            storePassword = String,
            keyPassword   = String,
            storeType     = String
        })
        case Context(SSLContext)
    }

    ///
    /// Configures TLS from a PKCS12 keystore (`.p12` / `.pfx`) with a single password.
    ///
    pub def pkcs12(path: String, password: String): TlsConfig =
        TlsConfig.KeyStore({
            path          = path,
            storePassword = password,
            keyPassword   = password,
            storeType     = "PKCS12"
        })

    ///
    /// Configures TLS from a Java KeyStore (`.jks`) with separate store and key passwords.
    ///
    pub def jks(path: String, storePassword: String, keyPassword: String): TlsConfig =
        TlsConfig.KeyStore({
            path          = path,
            storePassword = storePassword,
            keyPassword   = keyPassword,
            storeType     = "JKS"
        })

    ///
    /// Configures TLS from a pre-initialized `javax.net.ssl.SSLContext`.
    ///
    pub def fromSslContext(ctx: SSLContext): TlsConfig =
        TlsConfig.Context(ctx)

    ///
    /// Builds an initialized `javax.net.ssl.SSLContext` from `cfg`.
    ///
    pub def buildSslContext(cfg: TlsConfig): Result[String, SSLContext] \ IO =
        match cfg {
            case TlsConfig.Context(ctx) =>
                Ok(ctx)
            case TlsConfig.KeyStore(ksCfg) =>
                try {
                    let ks = KeyStore.getInstance(ksCfg#storeType);
                    let storeChars = ksCfg#storePassword.toCharArray();
                    let keyChars = ksCfg#keyPassword.toCharArray();
                    let fis = new FileInputStream(ksCfg#path);
                    try {
                        ks.load(fis, storeChars);
                        fis.close()
                    } catch {
                        case ex: Exception =>
                            try { fis.close() } catch { case _: Exception => () };
                            throw ex
                    };
                    let kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
                    kmf.init(ks, keyChars);
                    let sslCtx = SSLContext.getInstance("TLS");
                    let emptyTrust: Array[TrustManager, IO] = Array#{} @ Static;
                    sslCtx.init(kmf.getKeyManagers(), emptyTrust, new SecureRandom());
                    Ok(sslCtx)
                } catch {
                    case ex: Exception =>
                        let rawMsg = ex.getMessage();
                        let msg = if (Object.isNull(rawMsg)) "Failed to initialize TLS SSLContext" else rawMsg;
                        Err("TLS configuration error (${ksCfg#path}): ${msg}")
                }
        }

}
