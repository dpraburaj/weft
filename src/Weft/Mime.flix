pub mod Weft.Mime {

    ///
    /// Looks up the MIME type for a file extension (case-insensitive, with or without leading `.`).
    ///
    pub def fromExtension(rawExt: String): Option[String] = {
        let trimmed = String.toLowerCase(String.trim(rawExt));
        let ext = match String.stripPrefix({substr = "."}, trimmed) {
            case Some(rest) => rest
            case None       => trimmed
        };
        match ext {
            // Web & Text
            case "html" => Some("text/html; charset=utf-8")
            case "htm"  => Some("text/html; charset=utf-8")
            case "css"  => Some("text/css; charset=utf-8")
            case "js"   => Some("text/javascript; charset=utf-8")
            case "mjs"  => Some("text/javascript; charset=utf-8")
            case "json" => Some("application/json; charset=utf-8")
            case "xml"  => Some("application/xml; charset=utf-8")
            case "txt"  => Some("text/plain; charset=utf-8")
            case "csv"  => Some("text/csv; charset=utf-8")
            case "md"   => Some("text/markdown; charset=utf-8")
            case "wasm" => Some("application/wasm")
            case "map"  => Some("application/json; charset=utf-8")

            // Images
            case "png"  => Some("image/png")
            case "jpg"  => Some("image/jpeg")
            case "jpeg" => Some("image/jpeg")
            case "gif"  => Some("image/gif")
            case "webp" => Some("image/webp")
            case "avif" => Some("image/avif")
            case "svg"  => Some("image/svg+xml")
            case "ico"  => Some("image/x-icon")
            case "bmp"  => Some("image/bmp")
            case "tiff" => Some("image/tiff")
            case "tif"  => Some("image/tiff")

            // Fonts
            case "woff"  => Some("font/woff")
            case "woff2" => Some("font/woff2")
            case "ttf"   => Some("font/ttf")
            case "otf"   => Some("font/otf")
            case "eot"   => Some("application/vnd.ms-fontobject")

            // Documents, Archives & Media
            case "pdf"  => Some("application/pdf")
            case "zip"  => Some("application/zip")
            case "gz"   => Some("application/gzip")
            case "tar"  => Some("application/x-tar")
            case "mp4"  => Some("video/mp4")
            case "webm" => Some("video/webm")
            case "mp3"  => Some("audio/mpeg")
            case "ogg"  => Some("audio/ogg")
            case "wav"  => Some("audio/wav")

            case _      => None
        }
    }

    ///
    /// Infers a MIME type from a file path or filename, falling back to `"application/octet-stream"`.
    ///
    pub def fromPath(path: String): String = {
        let baseName = match String.indexOfRight({substr = "/"}, path) {
            case Some(idx) => String.sliceRight({start = idx + 1}, path)
            case None      => path
        };
        match String.indexOfRight({substr = "."}, baseName) {
            case Some(dotIdx) if dotIdx > 0 and dotIdx + 1 < String.length(baseName) =>
                let ext = String.sliceRight({start = dotIdx + 1}, baseName);
                Option.getWithDefault("application/octet-stream", fromExtension(ext))
            case _ =>
                "application/octet-stream"
        }
    }

}
