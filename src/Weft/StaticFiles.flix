pub mod Weft.StaticFiles {
    use Weft.Handler
    use Weft.HttpError
    use Weft.Req
    use Weft.Response
    use Weft.Router
    use Weft.StaticConfig
    use Weft.StaticFile
    use Weft.StaticStore
    use Weft.Url

    import java.time.Instant
    import java.time.ZoneOffset
    import java.time.format.DateTimeFormatter

    ///
    /// Mounts static asset serving under `urlPrefix` (e.g. `"/static"` or `"/"`).
    ///
    /// Registers `GET <urlPrefix>` and `GET <urlPrefix>/*path` (with automatic `HEAD`
    /// fallback from `Weft.Router`).
    ///
    pub def routes(urlPrefix: String, cfg: StaticConfig): Router[{Req, HttpError, StaticStore}] = {
        let base = Url.normalizePath(urlPrefix);
        let wild = Url.joinPaths(base, "*path");
        Router.empty()
            |> Router.get(base, () -> servePath(cfg, ""))
            |> Router.get(wild, serve(cfg))
    }

    ///
    /// Route handler reading the matched `*path` wildcard parameter (or `""`) and serving
    /// the corresponding static file from `StaticStore`.
    ///
    pub def serve(cfg: StaticConfig): Handler[{Req, HttpError, StaticStore}] = () -> {
        let rawRel = Option.getWithDefault("", Req.param("path"));
        servePath(cfg, rawRel)
    }

    ///
    /// Serves a relative static asset path with traversal protection, MIME detection,
    /// `Cache-Control`, `Last-Modified`, and `ETag` / `If-None-Match` (`304 Not Modified`) support.
    ///
    pub def servePath(cfg: StaticConfig, rawRelPath: String): Response \ {Req, HttpError, StaticStore} = {
        let cleanRel = sanitizePath(StaticConfig.enableDotfiles(cfg), rawRelPath)
            |> HttpError.orNotFound("Static file not found");
        let fileOpt = resolveFile(cfg, cleanRel);
        let file = fileOpt |> HttpError.orNotFound("Static file not found");

        let etagEnabled = StaticConfig.enableEtag(cfg);
        let etagVal = StaticFile.etag(file);

        let isNotModified = if (etagEnabled) {
            match Req.header("If-None-Match") {
                case Some(inm) => etagMatches(inm, etagVal)
                case None      => false
            }
        } else {
            false
        };

        let baseRes = if (isNotModified) {
            Response.notModified()
        } else {
            let r0 = Response.bytes(StaticFile.contentType(file), StaticFile.data(file));
            let mtime = StaticFile.lastModifiedMs(file);
            if (mtime > 0i64)
                Response.withHeader("Last-Modified", formatHttpDate(mtime), r0)
            else
                r0
        };

        let r1 = if (etagEnabled) Response.withHeader("ETag", etagVal, baseRes) else baseRes;
        match StaticConfig.cacheControl(cfg) {
            case Some(cc) => Response.withHeader("Cache-Control", cc, r1)
            case None     => r1
        }
    }

    ///
    /// Sanitizes a relative request path. Rejects null bytes, backslashes, `.` / `..` segments,
    /// and dotfiles (segments beginning with `.`) unless `enableDotfiles` is `true`.
    ///
    pub def sanitizePath(enableDotfiles: Bool, rawPath: String): Option[String] = {
        if (String.contains({substr = "\\"}, rawPath) or String.contains({substr = "\u0000"}, rawPath))
            None
        else {
            let segs = String.splitOn({substr = "/"}, rawPath)
                |> List.filter(s -> not String.isEmpty(s));
            let valid = List.forAll(seg ->
                seg != "." and
                seg != ".." and
                (enableDotfiles or not String.startsWith({prefix = "."}, seg)),
                segs
            );
            if (valid)
                Some(String.intercalate("/", segs))
            else
                None
        }
    }

    ///
    /// Checks whether an `If-None-Match` header matches `etag` (supports `*`, comma-separated
    /// lists, and weak `W/` validators).
    ///
    pub def etagMatches(ifNoneMatchHeader: String, etag: String): Bool = {
        let target = stripWeakPrefix(String.trim(etag));
        String.splitOn({substr = ","}, ifNoneMatchHeader)
            |> List.exists(raw -> {
                let candidate = String.trim(raw);
                candidate == "*" or stripWeakPrefix(candidate) == target
            })
    }

    // --- Internal Helpers ---

    def resolveFile(cfg: StaticConfig, cleanRel: String): Option[StaticFile] \ StaticStore =
        if (String.isEmpty(cleanRel)) {
            match StaticConfig.indexFile(cfg) {
                case Some(idx) => StaticStore.readFile(idx)
                case None      => None
            }
        } else {
            match StaticStore.readFile(cleanRel) {
                case Some(f) => Some(f)
                case None =>
                    match StaticConfig.indexFile(cfg) {
                        case Some(idx) => StaticStore.readFile("${cleanRel}/${idx}")
                        case None      => None
                    }
            }
        }

    def stripWeakPrefix(s: String): String =
        match String.stripPrefix({substr = "W/"}, s) {
            case Some(rest) => rest
            case None       => s
        }

    def formatHttpDate(epochMillis: Int64): String =
        unsafe IO {
            let instant = Instant.ofEpochMilli(epochMillis);
            let fmt = DateTimeFormatter.RFC_1123_DATE_TIME;
            fmt.format(instant.atOffset(ZoneOffset.UTC))
        }

}
