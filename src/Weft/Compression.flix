pub mod Weft.Compression {
    use Weft.CompressionConfig

    import java.io.ByteArrayInputStream
    import java.io.ByteArrayOutputStream
    import java.lang.Exception
    import java.util.zip.DeflaterOutputStream
    import java.util.zip.GZIPInputStream
    import java.util.zip.GZIPOutputStream
    import java.util.zip.InflaterInputStream

    ///
    /// Compresses `data` using GZIP (`Content-Encoding: gzip`).
    ///
    pub def gzip(data: Vector[Int8]): Vector[Int8] =
        unsafe IO {
            let baos = new ByteArrayOutputStream();
            let gos = new GZIPOutputStream(baos);
            gos.write(Vector.toArray(Static, data));
            gos.finish();
            gos.close();
            Array.toVector(baos.toByteArray())
        }

    ///
    /// Decompresses GZIP-encoded `data`.
    ///
    pub def gunzip(data: Vector[Int8]): Result[String, Vector[Int8]] =
        try {
            unsafe IO {
                let bais = new ByteArrayInputStream(Vector.toArray(Static, data));
                let gis = new GZIPInputStream(bais);
                let out = gis.readAllBytes();
                gis.close();
                Ok(Array.toVector(out))
            }
        } catch {
            case ex: Exception =>
                let msg = ex.getMessage();
                Err(if (Object.isNull(msg)) "Invalid GZIP payload" else msg)
        }

    ///
    /// Compresses `data` using zlib/deflate (`Content-Encoding: deflate`).
    ///
    pub def deflate(data: Vector[Int8]): Vector[Int8] =
        unsafe IO {
            let baos = new ByteArrayOutputStream();
            let dos = new DeflaterOutputStream(baos);
            dos.write(Vector.toArray(Static, data));
            dos.finish();
            dos.close();
            Array.toVector(baos.toByteArray())
        }

    ///
    /// Decompresses zlib/deflate-encoded `data`.
    ///
    pub def inflate(data: Vector[Int8]): Result[String, Vector[Int8]] =
        try {
            unsafe IO {
                let bais = new ByteArrayInputStream(Vector.toArray(Static, data));
                let iis = new InflaterInputStream(bais);
                let out = iis.readAllBytes();
                iis.close();
                Ok(Array.toVector(out))
            }
        } catch {
            case ex: Exception =>
                let msg = ex.getMessage();
                Err(if (Object.isNull(msg)) "Invalid deflate payload" else msg)
        }

    ///
    /// Negotiates the best supported encoding (`"gzip"` or `"deflate"`) from an HTTP
    /// `Accept-Encoding` header according to RFC 9110 q-values.
    ///
    pub def negotiateEncoding(cfg: CompressionConfig, acceptEncoding: Option[String]): Option[String] =
        match acceptEncoding {
            case None => None
            case Some(raw) =>
                let parsed = parseAcceptEncoding(raw);
                let gzipQ = if (CompressionConfig.enableGzip(cfg)) encodingQuality("gzip", parsed) else 0.0f64;
                let deflateQ = if (CompressionConfig.enableDeflate(cfg)) encodingQuality("deflate", parsed) else 0.0f64;
                if (gzipQ <= 0.0f64 and deflateQ <= 0.0f64)
                    None
                else if (gzipQ >= deflateQ)
                    Some("gzip")
                else
                    Some("deflate")
        }

    ///
    /// Returns `true` if the given `Content-Type` header is a compressible media type
    /// (HTML, CSS, JS, JSON, XML, SVG, plain text, WASM, etc.) and NOT already-compressed
    /// binary media (images, video, zip/gzip) or SSE (`text/event-stream`).
    ///
    pub def isCompressibleContentType(contentType: Option[String]): Bool =
        match contentType {
            case None => false
            case Some(raw) =>
                let media = match String.indexOfLeft({substr = ";"}, raw) {
                    case Some(idx) => String.sliceLeft({end = idx}, raw)
                    case None      => raw
                } |> String.trim |> String.toLowerCase;
                if (media == "text/event-stream")
                    false
                else if (String.startsWith({prefix = "text/"}, media))
                    true
                else
                    media == "application/json" or
                    media == "application/javascript" or
                    media == "application/xml" or
                    media == "application/xhtml+xml" or
                    media == "application/wasm" or
                    media == "image/svg+xml" or
                    String.endsWith({suffix = "+json"}, media) or
                    String.endsWith({suffix = "+xml"}, media)
        }

    ///
    /// Weakens a strong `ETag` (`"abc"` -> `W/"abc"`) per RFC 9110 §8.8.3 when applying
    /// content-coding transformation. Already-weak ETags are returned unchanged.
    ///
    pub def weakenEtag(etag: String): String = {
        let t = String.trim(etag);
        if (String.startsWith({prefix = "W/"}, t) or String.startsWith({prefix = "w/"}, t))
            t
        else
            "W/${t}"
    }

    // --- Internal Accept-Encoding Parser ---

    def parseAcceptEncoding(raw: String): Map[String, Float64] =
        String.splitOn({substr = ","}, raw)
            |> List.foldLeft((acc, token) -> {
                let parts = String.splitOn({substr = ";"}, token);
                match parts {
                    case Nil => acc
                    case namePart :: params =>
                        let name = String.toLowerCase(String.trim(namePart));
                        if (String.isEmpty(name))
                            acc
                        else {
                            let q = extractQ(params);
                            Map.insert(name, q, acc)
                        }
                }
            }, Map.empty())

    def extractQ(params: List[String]): Float64 =
        List.foldLeft((cur, param) -> {
            let trimmed = String.trim(param);
            match String.splitOn({substr = "="}, trimmed) {
                case k :: v :: Nil if String.toLowerCase(String.trim(k)) == "q" =>
                    match Float64.fromString(String.trim(v)) {
                        case Some(q) => Float64.max(0.0f64, Float64.min(1.0f64, q))
                        case None    => cur
                    }
                case _ => cur
            }
        }, 1.0f64, params)

    def encodingQuality(name: String, parsed: Map[String, Float64]): Float64 =
        match Map.get(name, parsed) {
            case Some(q) => q
            case None =>
                match Map.get("*", parsed) {
                    case Some(qStar) => qStar
                    case None        => 0.0f64
                }
        }

}
