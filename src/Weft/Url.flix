pub mod Weft.Url {

    import java.lang.IllegalArgumentException
    import java.net.URLDecoder
    import java.net.URLEncoder
    import java.nio.charset.StandardCharsets

    ///
    /// Percent-decodes a URL query component (`+` becomes space) using UTF-8.
    /// Falls back to the original string if malformed.
    ///
    pub def decodeQueryComponent(s: String): String =
        try {
            unsafe IO { URLDecoder.decode(s, StandardCharsets.UTF_8) }
        } catch {
            case _: IllegalArgumentException => s
        }

    ///
    /// Percent-decodes a URL path segment (preserves literal `+`) using UTF-8.
    /// Falls back to the original string if malformed.
    ///
    pub def decodePathSegment(s: String): String =
        let escaped = String.replace({src = "+"}, {dst = "%2B"}, s);
        decodeQueryComponent(escaped)

    ///
    /// Percent-encodes a string for use in URL query parameters using UTF-8.
    ///
    pub def encode(s: String): String =
        URLEncoder.encode(s, StandardCharsets.UTF_8)

    ///
    /// Parses a raw query string (with or without leading `?`) into a `Map[String, String]`.
    /// When a key appears multiple times, the last value wins.
    ///
    pub def parseQuery(rawQuery: String): Map[String, String] =
        let cleaned = match String.stripPrefix({substr = "?"}, rawQuery) {
            case Some(rest) => rest
            case None       => rawQuery
        };
        if (String.isEmpty(cleaned))
            Map.empty()
        else
            String.splitOn({substr = "&"}, cleaned)
                |> List.foldLeft((acc, pair) -> {
                    if (String.isEmpty(pair))
                        acc
                    else
                        match String.indexOfLeft({substr = "="}, pair) {
                            case Some(idx) =>
                                let k = decodeQueryComponent(String.sliceLeft({end = idx}, pair));
                                let v = decodeQueryComponent(String.sliceRight({start = idx + 1}, pair));
                                Map.insert(k, v, acc)
                            case None =>
                                let k = decodeQueryComponent(pair);
                                Map.insert(k, "", acc)
                        }
                }, Map.empty())

    ///
    /// Splits a URL path into non-empty decoded segments.
    /// E.g. `"/api/v1/users/42/"` -> `"api" :: "v1" :: "users" :: "42" :: Nil`.
    ///
    pub def splitPath(path: String): List[String] =
        let pathOnly = match String.indexOfLeft({substr = "?"}, path) {
            case Some(idx) => String.sliceLeft({end = idx}, path)
            case None      => path
        };
        String.splitOn({substr = "/"}, pathOnly)
            |> List.filter(s -> not String.isEmpty(s))
            |> List.map(decodePathSegment)

    ///
    /// Splits a route pattern into non-empty raw segments (without URL decoding).
    ///
    pub def splitPattern(pattern: String): List[String] =
        String.splitOn({substr = "/"}, pattern)
            |> List.filter(s -> not String.isEmpty(s))

    ///
    /// Normalizes a path to always begin with `/` and have no trailing `/` (except `"/"`).
    ///
    pub def normalizePath(path: String): String =
        let segs = splitPattern(path);
        match segs {
            case Nil => "/"
            case _   => "/" + String.intercalate("/", segs)
        }

    ///
    /// Joins two URL path prefixes cleanly.
    ///
    pub def joinPaths(prefix: String, suffix: String): String =
        let p = splitPattern(prefix);
        let s = splitPattern(suffix);
        match List.append(p, s) {
            case Nil => "/"
            case xs  => "/" + String.intercalate("/", xs)
        }

}
