pub mod Weft.ByteRange {
    use Weft.ByteRange

    ///
    /// Result of parsing an HTTP `Range: bytes=...` header (RFC 9110 §14.1.2)
    /// against a resource of known byte length.
    ///
    pub enum ByteRange with Eq, ToString {
        /// Valid inclusive `[start, endInclusive]` byte range to serve with `206 Partial Content`.
        case Satisfiable(Int32, Int32)
        /// Syntactically valid `bytes=` range that falls outside the resource length (`416 Range Not Satisfiable`).
        case Unsatisfiable
        /// Non-byte, multi-range, or malformed header that should be ignored per RFC 9110 (serve `200 OK`).
        case Ignored
    }

    ///
    /// Parses a single HTTP byte-range specification (`bytes=start-end`, `bytes=start-`,
    /// or `bytes=-suffixLength`) against `totalLength`.
    ///
    pub def parse(rawHeader: String, totalLength: Int32): ByteRange = {
        let trimmed = String.trim(rawHeader);
        match stripBytesPrefix(trimmed) {
            case None => ByteRange.Ignored
            case Some(specRaw) =>
                let spec = String.trim(specRaw);
                // Multi-range requests (comma-separated) fall back to 200 OK
                if (String.isEmpty(spec) or String.contains({substr = ","}, spec))
                    ByteRange.Ignored
                else {
                    match String.splitOn({substr = "-"}, spec) {
                        case startStr :: endStr :: Nil =>
                            let sTrim = String.trim(startStr);
                            let eTrim = String.trim(endStr);
                            if (String.isEmpty(sTrim) and String.isEmpty(eTrim)) {
                                ByteRange.Ignored
                            } else if (totalLength <= 0) {
                                ByteRange.Unsatisfiable
                            } else if (String.isEmpty(sTrim)) {
                                // Suffix range: bytes=-N (last N bytes)
                                match Int32.fromString(eTrim) {
                                    case Some(suffixLen) if suffixLen > 0 =>
                                        let clamped = Int32.min(suffixLen, totalLength);
                                        ByteRange.Satisfiable(totalLength - clamped, totalLength - 1)
                                    case Some(0) =>
                                        ByteRange.Unsatisfiable
                                    case _ =>
                                        ByteRange.Ignored
                                }
                            } else if (String.isEmpty(eTrim)) {
                                // Open-ended range: bytes=start-
                                match Int32.fromString(sTrim) {
                                    case Some(start) if start >= 0 and start < totalLength =>
                                        ByteRange.Satisfiable(start, totalLength - 1)
                                    case Some(start) if start >= totalLength =>
                                        ByteRange.Unsatisfiable
                                    case _ =>
                                        ByteRange.Ignored
                                }
                            } else {
                                // Closed range: bytes=start-end
                                match (Int32.fromString(sTrim), Int32.fromString(eTrim)) {
                                    case (Some(start), Some(endReq)) if start >= 0 and endReq >= start =>
                                        if (start >= totalLength)
                                            ByteRange.Unsatisfiable
                                        else
                                            ByteRange.Satisfiable(start, Int32.min(endReq, totalLength - 1))
                                    case _ =>
                                        ByteRange.Ignored
                                }
                            }
                        case _ =>
                            ByteRange.Ignored
                    }
                }
        }
    }

    ///
    /// Formats a `Content-Range` header for a `206 Partial Content` response:
    /// `"bytes <start>-<endInclusive>/<totalLength>"`.
    ///
    pub def contentRange(start: Int32, endInclusive: Int32, totalLength: Int32): String =
        "bytes ${start}-${endInclusive}/${totalLength}"

    ///
    /// Formats a `Content-Range` header for a `416 Range Not Satisfiable` response:
    /// `"bytes */<totalLength>"`.
    ///
    pub def unsatisfiableRange(totalLength: Int32): String =
        "bytes */${Int32.max(0, totalLength)}"

    ///
    /// Slices `data` to the inclusive range `[start, endInclusive]`.
    ///
    pub def slice(start: Int32, endInclusive: Int32, data: Vector[Int8]): Vector[Int8] =
        Vector.slice({start = start}, {end = endInclusive + 1}, data)

    def stripBytesPrefix(s: String): Option[String] =
        if (String.length(s) >= 6 and String.toLowerCase(String.sliceLeft({end = 6}, s)) == "bytes=")
            Some(String.sliceRight({start = 6}, s))
        else
            None

}
