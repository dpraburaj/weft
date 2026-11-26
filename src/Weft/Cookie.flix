pub mod Weft.Cookie {
    use Weft.Cookie
    use Weft.Crypto
    use Weft.SameSite

    ///
    /// Represents an HTTP `Set-Cookie` directive.
    ///
    pub enum Cookie {
        case Cookie({
            name     = String,
            value    = String,
            path     = Option[String],
            domain   = Option[String],
            maxAge   = Option[Int32],
            httpOnly = Bool,
            secure   = Bool,
            sameSite = Option[SameSite]
        })
    }

    instance Eq[Cookie] {
        pub def eq(a: Cookie, b: Cookie): Bool =
            let Cookie.Cookie(x) = a;
            let Cookie.Cookie(y) = b;
            x#name == y#name and
            x#value == y#value and
            x#path == y#path and
            x#domain == y#domain and
            x#maxAge == y#maxAge and
            x#httpOnly == y#httpOnly and
            x#secure == y#secure and
            x#sameSite == y#sameSite
    }

    ///
    /// Creates a new `Cookie` with sensible defaults (`Path=/`, `HttpOnly=true`, `SameSite=Lax`).
    ///
    pub def make(name: String, value: String): Cookie =
        Cookie.Cookie({
            name     = name,
            value    = value,
            path     = Some("/"),
            domain   = None,
            maxAge   = None,
            httpOnly = true,
            secure   = false,
            sameSite = Some(SameSite.Lax)
        })

    ///
    /// Creates an HMAC-SHA256 signed `Cookie` whose value is tamper-evident.
    /// Verify incoming values with `Cookie.verifySigned` or `Req.signedCookie`.
    ///
    pub def makeSigned(secret: String, name: String, value: String): Cookie =
        make(name, Crypto.signValue(secret, value))

    ///
    /// Verifies a signed cookie value created by `Cookie.makeSigned`, returning `Some(value)`
    /// if authentic or `None` if tampered.
    ///
    pub def verifySigned(secret: String, rawValue: String): Option[String] =
        Crypto.verifySignedValue(secret, rawValue)

    ///
    /// Creates an expired cookie to instruct the client to delete it.
    ///
    pub def expired(name: String): Cookie =
        make(name, "") |> withMaxAge(0)

    pub def withPath(p: String, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ path = Some(p) | r })

    pub def withDomain(d: String, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ domain = Some(d) | r })

    pub def withMaxAge(seconds: Int32, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ maxAge = Some(seconds) | r })

    pub def withHttpOnly(flag: Bool, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ httpOnly = flag | r })

    pub def withSecure(flag: Bool, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ secure = flag | r })

    pub def withSameSite(ss: SameSite, c: Cookie): Cookie =
        let Cookie.Cookie(r) = c;
        Cookie.Cookie({ sameSite = Some(ss) | r })

    ///
    /// Serializes a `Cookie` into an HTTP `Set-Cookie` header value.
    ///
    pub def toHeaderValue(c: Cookie): String =
        let Cookie.Cookie(r) = c;
        let parts0 = "${r#name}=${r#value}" :: Nil;
        let parts1 = match r#path {
            case Some(p) => List.append(parts0, "Path=${p}" :: Nil)
            case None    => parts0
        };
        let parts2 = match r#domain {
            case Some(d) => List.append(parts1, "Domain=${d}" :: Nil)
            case None    => parts1
        };
        let parts3 = match r#maxAge {
            case Some(s) => List.append(parts2, "Max-Age=${s}" :: Nil)
            case None    => parts2
        };
        let parts4 = if (r#httpOnly) List.append(parts3, "HttpOnly" :: Nil) else parts3;
        let parts5 = if (r#secure) List.append(parts4, "Secure" :: Nil) else parts4;
        let parts6 = match r#sameSite {
            case Some(ss) => List.append(parts5, "SameSite=${ss}" :: Nil)
            case None     => parts5
        };
        String.intercalate("; ", parts6)

    ///
    /// Parses an incoming `Cookie` header (`"a=1; b=2"`) into a `Map[String, String]`.
    ///
    pub def parseHeader(headerVal: String): Map[String, String] =
        if (String.isEmpty(String.trim(headerVal)))
            Map.empty()
        else
            String.splitOn({substr = ";"}, headerVal)
                |> List.foldLeft((acc, part) -> {
                    let trimmed = String.trim(part);
                    match String.indexOfLeft({substr = "="}, trimmed) {
                        case Some(idx) =>
                            let k = String.trim(String.sliceLeft({end = idx}, trimmed));
                            let v = String.trim(String.sliceRight({start = idx + 1}, trimmed));
                            if (String.isEmpty(k)) acc else Map.insert(k, v, acc)
                        case None => acc
                    }
                }, Map.empty())

}
