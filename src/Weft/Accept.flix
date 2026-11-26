pub mod Weft.Accept {
    use Weft.Request

    ///
    /// Parses an HTTP `Accept` header into `(mediaRange, quality)` entries sorted by
    /// descending quality (`q`), then specificity (`type/subtype` > `type/*` > `*/*`).
    /// Entries with `q <= 0.0` are excluded per RFC 9110.
    ///
    pub def parse(headerVal: String): List[(String, Float64)] = {
        let entries = String.splitOn({substr = ","}, headerVal)
            |> List.filterMap(parseEntry)
            |> List.filter(match (_, q) -> q > 0.0f64);
        entries |> List.sortBy(match (media, q) -> (0.0f64 - q, 0 - specificity(media)))
    }

    ///
    /// Selects the best matching media type from `offered` given an optional `Accept` header.
    /// If `Accept` is absent or empty, returns the first offered type.
    ///
    pub def negotiate(offered: List[String], acceptHeader: Option[String]): Option[String] =
        match offered {
            case Nil => None
            case first :: _ =>
                match acceptHeader {
                    case None => Some(first)
                    case Some(raw) if String.isEmpty(String.trim(raw)) => Some(first)
                    case Some(raw) =>
                        let accepted = parse(raw);
                        if (List.isEmpty(accepted))
                            None
                        else {
                            let scored = List.filterMap(off -> {
                                let normOff = String.toLowerCase(String.trim(off));
                                match bestMatchScore(normOff, accepted) {
                                    case Some((q, spec)) => Some((off, q, spec))
                                    case None            => None
                                }
                            }, offered);
                            scored
                                |> List.sortBy(match (_, q, spec) -> (0.0f64 - q, 0 - spec))
                                |> List.head
                                |> Option.map(match (off, _, _) -> off)
                        }
                }
        }

    ///
    /// Returns `true` if `req` prefers an HTML response based on its `Accept` header.
    ///
    pub def prefersHtml(req: Request): Bool =
        match Request.header("Accept", req) {
            case None => false
            case Some(raw) =>
                match negotiate("text/html" :: "application/json" :: Nil, Some(raw)) {
                    case Some("text/html") =>
                        // Only treat as HTML-preferring if `text/html` or `text/*` was explicitly accepted
                        // (not merely `*/*` from curl/API clients)
                        let parsed = parse(raw);
                        let htmlQ = bestExactOrTypeQuality("text/html", parsed);
                        let jsonQ = bestExactOrTypeQuality("application/json", parsed);
                        htmlQ > 0.0f64 and htmlQ >= jsonQ
                    case _ => false
                }
        }

    ///
    /// Returns `true` if `req` prefers a JSON response (either via `Accept` header or
    /// JSON `Content-Type` when HTML is not explicitly preferred).
    ///
    pub def prefersJson(req: Request): Bool =
        if (prefersHtml(req))
            false
        else
            match Request.header("Accept", req) {
                case Some(raw) =>
                    match negotiate("application/json" :: "text/html" :: Nil, Some(raw)) {
                        case Some("application/json") => true
                        case _                        => Request.contentType(req) == Some("application/json")
                    }
                case None =>
                    Request.contentType(req) == Some("application/json")
            }

    // --- Internal Helpers ---

    def parseEntry(raw: String): Option[(String, Float64)] = {
        let trimmed = String.trim(raw);
        if (String.isEmpty(trimmed))
            None
        else {
            let parts = String.splitOn({substr = ";"}, trimmed) |> List.map(String.trim);
            match parts {
                case media :: params if not String.isEmpty(media) =>
                    let q = extractQuality(params);
                    Some((String.toLowerCase(media), q))
                case _ => None
            }
        }
    }

    def extractQuality(params: List[String]): Float64 =
        match params {
            case Nil => 1.0f64
            case p :: rest =>
                match String.indexOfLeft({substr = "="}, p) {
                    case Some(idx) =>
                        let k = String.toLowerCase(String.trim(String.sliceLeft({end = idx}, p)));
                        if (k == "q") {
                            let v = String.trim(String.sliceRight({start = idx + 1}, p));
                            match Float64.fromString(v) {
                                case Some(q) => Float64.min(1.0f64, Float64.max(0.0f64, q))
                                case None    => 1.0f64
                            }
                        } else extractQuality(rest)
                    case None => extractQuality(rest)
                }
        }

    def specificity(media: String): Int32 =
        if (media == "*/*") 0
        else if (String.endsWith({suffix = "/*"}, media)) 1
        else 2

    def matchesRange(offered: String, range: String): Bool =
        if (range == "*/*" or offered == range)
            true
        else if (String.endsWith({suffix = "/*"}, range)) {
            let prefix = String.sliceLeft({end = String.length(range) - 1}, range); // e.g. "text/"
            String.startsWith({prefix = prefix}, offered)
        } else {
            false
        }

    def bestMatchScore(offered: String, accepted: List[(String, Float64)]): Option[(Float64, Int32)] =
        accepted
            |> List.filter(match (range, _) -> matchesRange(offered, range))
            |> List.map(match (range, q) -> (q, specificity(range)))
            |> List.sortBy(match (q, spec) -> (0 - spec, 0.0f64 - q))
            |> List.head

    def bestExactOrTypeQuality(offered: String, accepted: List[(String, Float64)]): Float64 =
        accepted
            |> List.filter(match (range, _) -> range != "*/*" and matchesRange(offered, range))
            |> List.map(match (range, q) -> (q, specificity(range)))
            |> List.sortBy(match (q, spec) -> (0 - spec, 0.0f64 - q))
            |> List.head
            |> Option.map(fst)
            |> Option.getWithDefault(0.0f64)

}
