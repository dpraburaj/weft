pub mod Weft.Multipart {
    use Weft.Body
    use Weft.Headers
    use Weft.HttpError
    use Weft.MultipartForm
    use Weft.Req
    use Weft.Request
    use Weft.UploadedFile

    ///
    /// Extracts the `boundary` parameter from a `Content-Type: multipart/form-data; boundary=...` header.
    ///
    pub def extractBoundary(contentTypeHeader: String): Option[String] = {
        let parts = String.splitOn({substr = ";"}, contentTypeHeader) |> List.map(String.trim);
        match parts {
            case media :: params =>
                if (String.toLowerCase(media) != "multipart/form-data")
                    None
                else
                    findParam("boundary", params)
                        |> Option.filter(b -> not String.isEmpty(b))
            case Nil => None
        }
    }

    ///
    /// Pure binary RFC 7578 `multipart/form-data` parser operating directly on `Vector[Int8]`.
    /// Preserves exact raw bytes of uploaded files without UTF-8 lossy conversion.
    ///
    pub def parse(boundary: String, rawBody: Vector[Int8]): Result[String, MultipartForm] = {
        if (String.isEmpty(boundary))
            Err("Multipart boundary must not be empty")
        else {
            let delim = Body.utf8Bytes("--${boundary}");
            let delimLen = Vector.length(delim);
            let totalLen = Vector.length(rawBody);
            let crlf2 = Body.utf8Bytes("\r\n\r\n");
            let lf2 = Body.utf8Bytes("\n\n");

            match indexOfBytes(delim, rawBody, 0) {
                case None =>
                    Err("Missing opening multipart boundary '--${boundary}'")
                case Some(firstIdx) =>
                    def loop(
                        pos: Int32,
                        fieldsAcc: Map[String, List[String]],
                        filesAcc: Map[String, List[UploadedFile]]
                    ): Result[String, MultipartForm] = {
                        // Closing delimiter `--`
                        if (pos + 2 <= totalLen and
                            Vector.get(pos, rawBody) == 45i8 and
                            Vector.get(pos + 1, rawBody) == 45i8) {
                            let finalFields = Map.map(List.reverse, fieldsAcc);
                            let finalFiles = Map.map(List.reverse, filesAcc);
                            Ok(MultipartForm.make(finalFields, finalFiles))
                        } else {
                            let afterBreak = skipLineBreak(rawBody, pos, totalLen);
                            match afterBreak {
                                case None =>
                                    Err("Malformed multipart boundary delimiter at byte ${pos}")
                                case Some(headerStart) =>
                                    match findHeaderEnd(crlf2, lf2, rawBody, headerStart) {
                                        case None =>
                                            Err("Malformed multipart part: missing header separator")
                                        case Some((headerEnd, bodyStart)) =>
                                            match indexOfBytes(delim, rawBody, bodyStart) {
                                                case None =>
                                                    Err("Unterminated multipart part: missing closing boundary")
                                                case Some(nextDelimIdx) =>
                                                    let bodyEnd = trimPrecedingLineBreak(rawBody, bodyStart, nextDelimIdx);
                                                    let headerBytes = Vector.slice({start = headerStart}, {end = headerEnd}, rawBody);
                                                    let headers = parsePartHeaders(Body.utf8String(headerBytes));
                                                    let payloadBytes = Vector.slice({start = bodyStart}, {end = bodyEnd}, rawBody);
                                                    match parseContentDisposition(headers) {
                                                        case Err(msg) => Err(msg)
                                                        case Ok((fieldName, fileNameOpt)) =>
                                                            match fileNameOpt {
                                                                case Some(fname) =>
                                                                    let ct = Option.getWithDefault(
                                                                        "application/octet-stream",
                                                                        Headers.get("Content-Type", headers)
                                                                    );
                                                                    let uf = UploadedFile.make(fieldName, fname, ct, payloadBytes);
                                                                    let prev = Map.getWithDefault(fieldName, Nil, filesAcc);
                                                                    let nextFiles = Map.insert(fieldName, uf :: prev, filesAcc);
                                                                    loop(nextDelimIdx + delimLen, fieldsAcc, nextFiles)
                                                                case None =>
                                                                    let txt = Body.utf8String(payloadBytes);
                                                                    let prev = Map.getWithDefault(fieldName, Nil, fieldsAcc);
                                                                    let nextFields = Map.insert(fieldName, txt :: prev, fieldsAcc);
                                                                    loop(nextDelimIdx + delimLen, nextFields, filesAcc)
                                                            }
                                                    }
                                            }
                                    }
                            }
                        }
                    };
                    loop(firstIdx + delimLen, Map.empty(), Map.empty())
            }
        }
    }

    ///
    /// Parses a `multipart/form-data` `Request` into a `MultipartForm`.
    ///
    pub def parseRequest(req: Request): Result[String, MultipartForm] =
        match Request.header("Content-Type", req) {
            case None => Err("Missing Content-Type header for multipart/form-data")
            case Some(ct) =>
                match extractBoundary(ct) {
                    case None           => Err("Expected 'multipart/form-data' with a boundary parameter, got '${ct}'")
                    case Some(boundary) => parse(boundary, Request.bodyBytes(req))
                }
        }

    ///
    /// Parses the ambient `Req` as `multipart/form-data`, raising `415 Unsupported Media Type`
    /// if the `Content-Type` is not `multipart/form-data` or `400 Bad Request` if malformed.
    ///
    pub def fromReq(): MultipartForm \ {Req, HttpError} = {
        let req = Req.current();
        let ctHeader = Request.header("Content-Type", req)
            |> HttpError.unwrapOr(Weft.Status.unsupportedMediaType(), "Expected Content-Type: multipart/form-data");
        let boundary = extractBoundary(ctHeader)
            |> HttpError.unwrapOr(Weft.Status.unsupportedMediaType(), "Expected Content-Type: multipart/form-data with boundary");
        match parse(boundary, Request.bodyBytes(req)) {
            case Ok(form) => form
            case Err(msg) => HttpError.badRequest("Invalid multipart/form-data payload: ${msg}")
        }
    }

    ///
    /// Pure binary encoder for `multipart/form-data` payloads (ideal for tests and outbound requests).
    ///
    pub def encode(
        boundary: String,
        fields: List[(String, String)],
        files: List[UploadedFile]
    ): Vector[Int8] = {
        let fieldChunks = List.map(match (k, v) ->
            Body.utf8Bytes(
                "--${boundary}\r\n" +
                "Content-Disposition: form-data; name=\"${escapeQuoted(k)}\"\r\n\r\n" +
                "${v}\r\n"
            ),
            fields
        );
        let fileChunks = List.flatMap(f -> {
            let hdr = Body.utf8Bytes(
                "--${boundary}\r\n" +
                "Content-Disposition: form-data; name=\"${escapeQuoted(UploadedFile.fieldName(f))}\"; " +
                "filename=\"${escapeQuoted(UploadedFile.fileName(f))}\"\r\n" +
                "Content-Type: ${UploadedFile.contentType(f)}\r\n\r\n"
            );
            let crlf = Body.utf8Bytes("\r\n");
            hdr :: UploadedFile.data(f) :: crlf :: Nil
        }, files);
        let closing = Body.utf8Bytes("--${boundary}--\r\n");
        let allChunks = List.append(List.append(fieldChunks, fileChunks), closing :: Nil);
        Vector.flatten(List.toVector(allChunks))
    }

    // --- Internal Binary & Header Parsing Helpers ---

    def indexOfBytes(needle: Vector[Int8], haystack: Vector[Int8], startIdx: Int32): Option[Int32] = {
        let nLen = Vector.length(needle);
        let hLen = Vector.length(haystack);
        if (nLen == 0)
            if (startIdx <= hLen) Some(startIdx) else None
        else if (startIdx < 0 or startIdx + nLen > hLen)
            None
        else {
            let limit = hLen - nLen;
            def matchesAt(pos: Int32, j: Int32): Bool =
                if (j >= nLen) true
                else if (Vector.get(pos + j, haystack) == Vector.get(j, needle)) matchesAt(pos, j + 1)
                else false;
            def scan(i: Int32): Option[Int32] =
                if (i > limit) None
                else if (matchesAt(i, 0)) Some(i)
                else scan(i + 1);
            scan(startIdx)
        }
    }

    def skipLineBreak(bs: Vector[Int8], pos: Int32, totalLen: Int32): Option[Int32] =
        if (pos + 2 <= totalLen and Vector.get(pos, bs) == 13i8 and Vector.get(pos + 1, bs) == 10i8)
            Some(pos + 2)
        else if (pos + 1 <= totalLen and Vector.get(pos, bs) == 10i8)
            Some(pos + 1)
        else
            None

    def findHeaderEnd(
        crlf2: Vector[Int8],
        lf2: Vector[Int8],
        bs: Vector[Int8],
        startIdx: Int32
    ): Option[(Int32, Int32)] =
        match (indexOfBytes(crlf2, bs, startIdx), indexOfBytes(lf2, bs, startIdx)) {
            case (Some(a), Some(b)) => if (a <= b) Some((a, a + 4)) else Some((b, b + 2))
            case (Some(a), None)    => Some((a, a + 4))
            case (None, Some(b))    => Some((b, b + 2))
            case (None, None)       => None
        }

    def trimPrecedingLineBreak(bs: Vector[Int8], bodyStart: Int32, delimIdx: Int32): Int32 =
        if (delimIdx >= bodyStart + 2 and
            Vector.get(delimIdx - 2, bs) == 13i8 and
            Vector.get(delimIdx - 1, bs) == 10i8)
            delimIdx - 2
        else if (delimIdx >= bodyStart + 1 and Vector.get(delimIdx - 1, bs) == 10i8)
            delimIdx - 1
        else
            delimIdx

    def parsePartHeaders(rawHeaders: String): Headers =
        String.splitOn({substr = "\n"}, rawHeaders)
            |> List.foldLeft((acc, line) -> {
                let cleaned = String.trim(line);
                if (String.isEmpty(cleaned))
                    acc
                else
                    match String.indexOfLeft({substr = ":"}, cleaned) {
                        case Some(idx) =>
                            let k = String.trim(String.sliceLeft({end = idx}, cleaned));
                            let v = String.trim(String.sliceRight({start = idx + 1}, cleaned));
                            if (String.isEmpty(k)) acc else Headers.add(k, v, acc)
                        case None => acc
                    }
            }, Headers.empty())

    def parseContentDisposition(headers: Headers): Result[String, (String, Option[String])] =
        match Headers.get("Content-Disposition", headers) {
            case None => Err("Missing Content-Disposition header in multipart part")
            case Some(cd) =>
                let parts = splitBySemicolonOutsideQuotes(cd);
                match findParam("name", parts) {
                    case None => Err("Missing 'name' parameter in Content-Disposition: ${cd}")
                    case Some(fieldName) =>
                        let fnameOpt = findParam("filename", parts);
                        Ok((fieldName, fnameOpt))
                }
        }

    def splitBySemicolonOutsideQuotes(s: String): List[String] = {
        let len = String.length(s);
        def loop(i: Int32, segStart: Int32, inQuotes: Bool, escaped: Bool, acc: List[String]): List[String] = {
            if (i >= len) {
                let last = String.trim(String.slice({start = segStart}, {end = len}, s));
                List.reverse(last :: acc)
            } else {
                let c = String.charAt(i, s);
                if (escaped)
                    loop(i + 1, segStart, inQuotes, false, acc)
                else if (inQuotes and c == '\\')
                    loop(i + 1, segStart, inQuotes, true, acc)
                else if (c == '"')
                    loop(i + 1, segStart, not inQuotes, false, acc)
                else if (not inQuotes and c == ';') {
                    let part = String.trim(String.slice({start = segStart}, {end = i}, s));
                    loop(i + 1, i + 1, false, false, part :: acc)
                } else
                    loop(i + 1, segStart, inQuotes, false, acc)
            }
        };
        loop(0, 0, false, false, Nil)
    }

    def findParam(targetKey: String, params: List[String]): Option[String] = {
        let wanted = String.toLowerCase(targetKey);
        def loop(ps: List[String]): Option[String] = match ps {
            case Nil => None
            case p :: rest =>
                match String.indexOfLeft({substr = "="}, p) {
                    case Some(idx) =>
                        let k = String.toLowerCase(String.trim(String.sliceLeft({end = idx}, p)));
                        if (k == wanted) {
                            let rawV = String.trim(String.sliceRight({start = idx + 1}, p));
                            Some(unquoteParam(rawV))
                        } else {
                            loop(rest)
                        }
                    case None => loop(rest)
                }
        };
        loop(params)
    }

    def unquoteParam(v: String): String =
        let len = String.length(v);
        if (len >= 2 and String.charAt(0, v) == '"' and String.charAt(len - 1, v) == '"') {
            let inner = String.slice({start = 1}, {end = len - 1}, v);
            unescapeQuoted(inner)
        } else {
            v
        }

    def unescapeQuoted(s: String): String = region rc {
        let sb = StringBuilder.empty(rc);
        let len = String.length(s);
        def loop(i: Int32): Unit \ rc = {
            if (i >= len) ()
            else if (String.charAt(i, s) == '\\' and i + 1 < len) {
                StringBuilder.append(String.charAt(i + 1, s), sb);
                loop(i + 2)
            } else {
                StringBuilder.append(String.charAt(i, s), sb);
                loop(i + 1)
            }
        };
        loop(0);
        StringBuilder.toString(sb)
    }

    def escapeQuoted(s: String): String =
        s
            |> String.replace({src = "\\"}, {dst = "\\\\"})
            |> String.replace({src = "\""}, {dst = "\\\""})

}
