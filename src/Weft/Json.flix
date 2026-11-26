pub mod Weft.Json {
    use Weft.HttpError
    use Weft.IntoResponse
    use Weft.Json
    use Weft.Response
    use Weft.Status

    ///
    /// Pure Flix JSON AST.
    ///
    pub enum Json with Eq {
        case JNull
        case JBool(Bool)
        case JInt(Int64)
        case JFloat(Float64)
        case JString(String)
        case JArray(List[Json])
        case JObject(Map[String, Json])
    }

    instance ToString[Json] {
        pub def toString(j: Json): String = Weft.Json.encode(j)
    }

    instance IntoResponse[Json] {
        pub def intoResponse(j: Json): Response = Weft.Json.toResponse(j)
    }

    // --- Constructors ---

    pub def nullValue(): Json                      = Json.JNull
    pub def bool(b: Bool): Json                    = Json.JBool(b)
    pub def int(i: Int32): Json                    = Json.JInt(Int32.toInt64(i))
    pub def int64(i: Int64): Json                  = Json.JInt(i)
    pub def float(f: Float64): Json                = Json.JFloat(f)
    pub def str(s: String): Json                   = Json.JString(s)
    pub def arr(xs: List[Json]): Json              = Json.JArray(xs)
    pub def obj(pairs: List[(String, Json)]): Json = Json.JObject(List.toMap(pairs))

    ///
    /// Wraps a `Json` value in a `200 OK` `application/json` `Response`.
    ///
    pub def toResponse(j: Json): Response =
        Response.jsonString(encode(j))

    ///
    /// Wraps a `Json` value in a `Response` with a custom `Status`.
    ///
    pub def toResponseWithStatus(st: Status, j: Json): Response =
        Response.jsonString(encode(j)) |> Response.withStatus(st)

    // --- Encoder ---

    ///
    /// Encodes a `Json` value into a compact RFC 8259 JSON string.
    ///
    pub def encode(j: Json): String = match j {
        case Json.JNull       => "null"
        case Json.JBool(true) => "true"
        case Json.JBool(false)=> "false"
        case Json.JInt(i)     => "${i}"
        case Json.JFloat(f)   => "${f}"
        case Json.JString(s)  => "\"" + escapeString(s) + "\""
        case Json.JArray(xs)  =>
            let items = List.map(encode, xs);
            "[" + String.intercalate(",", items) + "]"
        case Json.JObject(m)  =>
            let pairs = Map.toList(m) |> List.map(match (k, v) ->
                "\"" + escapeString(k) + "\":" + encode(v)
            );
            "{" + String.intercalate(",", pairs) + "}"
    }

    def escapeString(s: String): String = region rc {
        let sb = StringBuilder.empty(rc);
        let len = String.length(s);
        def loop(i) = {
            if (i >= len)
                ()
            else {
                let c = String.charAt(i, s);
                let cp = Char.toBmpCodePoint(c);
                match cp {
                    case 34 => StringBuilder.appendString("\\\"", sb)
                    case 92 => StringBuilder.appendString("\\\\", sb)
                    case 10 => StringBuilder.appendString("\\n", sb)
                    case 13 => StringBuilder.appendString("\\r", sb)
                    case 9  => StringBuilder.appendString("\\t", sb)
                    case 8  => StringBuilder.appendString("\\b", sb)
                    case 12 => StringBuilder.appendString("\\f", sb)
                    case _  => StringBuilder.append(c, sb)
                };
                loop(i + 1)
            }
        };
        loop(0);
        StringBuilder.toString(sb)
    }

    // --- Pure Accessors ---

    pub def getField(key: String, j: Json): Option[Json] = match j {
        case Json.JObject(m) => Map.get(key, m)
        case _               => None
    }

    pub def asString(j: Json): Option[String] = match j {
        case Json.JString(s) => Some(s)
        case _               => None
    }

    pub def asInt(j: Json): Option[Int32] = match j {
        case Json.JInt(i) => Int64.tryToInt32(i)
        case _            => None
    }

    pub def asInt64(j: Json): Option[Int64] = match j {
        case Json.JInt(i) => Some(i)
        case _            => None
    }

    pub def asFloat(j: Json): Option[Float64] = match j {
        case Json.JFloat(f) => Some(f)
        case Json.JInt(i)   => Some(Int64.toFloat64(i))
        case _              => None
    }

    pub def asBool(j: Json): Option[Bool] = match j {
        case Json.JBool(b) => Some(b)
        case _             => None
    }

    pub def asArray(j: Json): Option[List[Json]] = match j {
        case Json.JArray(xs) => Some(xs)
        case _               => None
    }

    pub def asObject(j: Json): Option[Map[String, Json]] = match j {
        case Json.JObject(m) => Some(m)
        case _               => None
    }

    // --- Effectful Extractors (compose with `HttpError`) ---

    ///
    /// Parses a JSON string or raises `400 Bad Request` via `HttpError`.
    ///
    pub def parseOrBadRequest(s: String): Json \ HttpError =
        match parse(s) {
            case Ok(j)    => j
            case Err(msg) => HttpError.badRequest("Invalid JSON: ${msg}")
        }

    ///
    /// Extracts a required string field from a JSON object, or raises `400 Bad Request`.
    ///
    pub def requireString(key: String, j: Json): String \ HttpError =
        match getField(key, j) {
            case Some(Json.JString(s)) => s
            case Some(_)               => HttpError.badRequest("Field '${key}' must be a string")
            case None                  => HttpError.badRequest("Missing required field '${key}'")
        }

    ///
    /// Extracts a required non-blank string field, or raises `400 Bad Request`.
    ///
    pub def requireNonEmptyString(key: String, j: Json): String \ HttpError =
        let s = String.trim(requireString(key, j));
        if (String.isEmpty(s))
            HttpError.badRequest("Field '${key}' must not be empty")
        else
            s

    ///
    /// Extracts a required 32-bit integer field, or raises `400 Bad Request`.
    ///
    pub def requireInt(key: String, j: Json): Int32 \ HttpError =
        match getField(key, j) {
            case Some(v) => match asInt(v) {
                case Some(n) => n
                case None    => HttpError.badRequest("Field '${key}' must be an integer")
            }
            case None => HttpError.badRequest("Missing required field '${key}'")
        }

    ///
    /// Extracts a required boolean field, or raises `400 Bad Request`.
    ///
    pub def requireBool(key: String, j: Json): Bool \ HttpError =
        match getField(key, j) {
            case Some(Json.JBool(b)) => b
            case Some(_)             => HttpError.badRequest("Field '${key}' must be a boolean")
            case None                => HttpError.badRequest("Missing required field '${key}'")
        }

    ///
    /// Extracts an optional string field (raises `400 Bad Request` if present with wrong type).
    ///
    pub def optionalString(key: String, j: Json): Option[String] \ HttpError =
        match getField(key, j) {
            case None                  => None
            case Some(Json.JNull)      => None
            case Some(Json.JString(s)) => Some(s)
            case Some(_)               => HttpError.badRequest("Field '${key}' must be a string")
        }

    ///
    /// Extracts an optional boolean field (raises `400 Bad Request` if present with wrong type).
    ///
    pub def optionalBool(key: String, j: Json): Option[Bool] \ HttpError =
        match getField(key, j) {
            case None                => None
            case Some(Json.JNull)    => None
            case Some(Json.JBool(b)) => Some(b)
            case Some(_)             => HttpError.badRequest("Field '${key}' must be a boolean")
        }

    // --- Recursive-Descent Parser (RFC 8259) ---

    ///
    /// Parses a JSON string into a `Json` AST.
    ///
    pub def parse(input: String): Result[String, Json] =
        let len = String.length(input);
        let start = skipWs(input, len, 0);
        if (start >= len)
            Err("Unexpected end of input")
        else
            match parseValue(input, len, start) {
                case Ok((v, nextIdx)) =>
                    let endIdx = skipWs(input, len, nextIdx);
                    if (endIdx == len)
                        Ok(v)
                    else
                        Err("Unexpected trailing character at position ${endIdx}")
                case Err(e) => Err(e)
            }

    def skipWs(s: String, len: Int32, i: Int32): Int32 =
        if (i >= len) i
        else match String.charAt(i, s) {
            case ' '  => skipWs(s, len, i + 1)
            case '\t' => skipWs(s, len, i + 1)
            case '\n' => skipWs(s, len, i + 1)
            case '\r' => skipWs(s, len, i + 1)
            case _    => i
        }

    def parseValue(s: String, len: Int32, i0: Int32): Result[String, (Json, Int32)] =
        let i = skipWs(s, len, i0);
        if (i >= len)
            Err("Unexpected end of input at position ${i}")
        else
            match String.charAt(i, s) {
                case 'n' => parseLiteral(s, len, i, "null", Json.JNull)
                case 't' => parseLiteral(s, len, i, "true", Json.JBool(true))
                case 'f' => parseLiteral(s, len, i, "false", Json.JBool(false))
                case '"' =>
                    Result.map(match (strVal, next) -> (Json.JString(strVal), next), parseString(s, len, i))
                case '[' => parseArray(s, len, i)
                case '{' => parseObject(s, len, i)
                case c if c == '-' or Char.isDigit(c) => parseNumber(s, len, i)
                case c   => Err("Unexpected character '${c}' at position ${i}")
            }

    def parseLiteral(s: String, len: Int32, i: Int32, lit: String, value: Json): Result[String, (Json, Int32)] =
        let litLen = String.length(lit);
        if (i + litLen <= len and String.slice({start = i}, {end = i + litLen}, s) == lit)
            Ok((value, i + litLen))
        else
            Err("Expected '${lit}' at position ${i}")

    def parseString(s: String, len: Int32, i0: Int32): Result[String, (String, Int32)] = region rc {
        let sb = StringBuilder.empty(rc);
        def loop(i) = {
            if (i >= len)
                Err("Unterminated string starting at position ${i0}")
            else
                match String.charAt(i, s) {
                    case '"' => Ok((StringBuilder.toString(sb), i + 1))
                    case '\\' =>
                        if (i + 1 >= len)
                            Err("Unterminated escape sequence at position ${i}")
                        else
                            match String.charAt(i + 1, s) {
                                case '"'  => StringBuilder.append('"', sb);  loop(i + 2)
                                case '\\' => StringBuilder.append('\\', sb); loop(i + 2)
                                case '/'  => StringBuilder.append('/', sb);  loop(i + 2)
                                case 'n'  => StringBuilder.append('\n', sb); loop(i + 2)
                                case 'r'  => StringBuilder.append('\r', sb); loop(i + 2)
                                case 't'  => StringBuilder.append('\t', sb); loop(i + 2)
                                case 'b'  => StringBuilder.appendCodePoint(8, sb);  loop(i + 2)
                                case 'f'  => StringBuilder.appendCodePoint(12, sb); loop(i + 2)
                                case 'u'  =>
                                    if (i + 6 > len)
                                        Err("Invalid \\u escape at position ${i}")
                                    else {
                                        let hex = String.slice({start = i + 2}, {end = i + 6}, s);
                                        match parseHex4(hex) {
                                            case Some(cp) =>
                                                StringBuilder.appendCodePoint(cp, sb);
                                                loop(i + 6)
                                            case None =>
                                                Err("Invalid hex unicode escape '\\u${hex}' at position ${i}")
                                        }
                                    }
                                case other =>
                                    Err("Invalid escape character '\\${other}' at position ${i}")
                            }
                    case c =>
                        StringBuilder.append(c, sb);
                        loop(i + 1)
                }
        };
        loop(i0 + 1)
    }

    def hexVal(c: Char): Option[Int32] =
        let cp = Char.toBmpCodePoint(c);
        if (cp >= 48 and cp <= 57) Some(cp - 48)
        else if (cp >= 97 and cp <= 102) Some(10 + cp - 97)
        else if (cp >= 65 and cp <= 70) Some(10 + cp - 65)
        else None

    def parseHex4(h: String): Option[Int32] =
        forM (
            a <- hexVal(String.charAt(0, h));
            b <- hexVal(String.charAt(1, h));
            c <- hexVal(String.charAt(2, h));
            d <- hexVal(String.charAt(3, h))
        ) yield ((a * 4096) + (b * 256) + (c * 16) + d)

    def parseNumber(s: String, len: Int32, i0: Int32): Result[String, (Json, Int32)] =
        def scan(i, isFloat) = {
            if (i >= len) (i, isFloat)
            else match String.charAt(i, s) {
                case c if Char.isDigit(c) => scan(i + 1, isFloat)
                case '.'                  => scan(i + 1, true)
                case 'e'                  => scan(i + 1, true)
                case 'E'                  => scan(i + 1, true)
                case '+' if i > i0        => scan(i + 1, isFloat)
                case '-' if i > i0        => scan(i + 1, isFloat)
                case _                    => (i, isFloat)
            }
        };
        let startScan = if (String.charAt(i0, s) == '-') i0 + 1 else i0;
        let (endIdx, isFloat) = scan(startScan, false);
        let token = String.slice({start = i0}, {end = endIdx}, s);
        if (isFloat)
            match Float64.fromString(token) {
                case Some(f) => Ok((Json.JFloat(f), endIdx))
                case None    => Err("Invalid number '${token}' at position ${i0}")
            }
        else
            match Int64.fromString(token) {
                case Some(n) => Ok((Json.JInt(n), endIdx))
                case None    => match Float64.fromString(token) {
                    case Some(f) => Ok((Json.JFloat(f), endIdx))
                    case None    => Err("Invalid number '${token}' at position ${i0}")
                }
            }

    def parseArray(s: String, len: Int32, i0: Int32): Result[String, (Json, Int32)] =
        let i1 = skipWs(s, len, i0 + 1);
        if (i1 < len and String.charAt(i1, s) == ']')
            Ok((Json.JArray(Nil), i1 + 1))
        else {
            def loop(i, acc) = {
                match parseValue(s, len, i) {
                    case Err(e) => Err(e)
                    case Ok((v, next)) =>
                        let after = skipWs(s, len, next);
                        if (after >= len)
                            Err("Unterminated array starting at position ${i0}")
                        else match String.charAt(after, s) {
                            case ',' => loop(after + 1, v :: acc)
                            case ']' => Ok((Json.JArray(List.reverse(v :: acc)), after + 1))
                            case c   => Err("Expected ',' or ']' in array at position ${after}, found '${c}'")
                        }
                }
            };
            loop(i1, Nil)
        }

    def parseObject(s: String, len: Int32, i0: Int32): Result[String, (Json, Int32)] =
        let i1 = skipWs(s, len, i0 + 1);
        if (i1 < len and String.charAt(i1, s) == '}')
            Ok((Json.JObject(Map.empty()), i1 + 1))
        else {
            def loop(i, acc) = {
                let kStart = skipWs(s, len, i);
                if (kStart >= len or String.charAt(kStart, s) != '"')
                    Err("Expected string key in object at position ${kStart}")
                else
                    match parseString(s, len, kStart) {
                        case Err(e) => Err(e)
                        case Ok((k, afterKey)) =>
                            let colonIdx = skipWs(s, len, afterKey);
                            if (colonIdx >= len or String.charAt(colonIdx, s) != ':')
                                Err("Expected ':' after key '${k}' at position ${colonIdx}")
                            else
                                match parseValue(s, len, colonIdx + 1) {
                                    case Err(e) => Err(e)
                                    case Ok((v, afterVal)) =>
                                        let next = skipWs(s, len, afterVal);
                                        let acc2 = Map.insert(k, v, acc);
                                        if (next >= len)
                                            Err("Unterminated object starting at position ${i0}")
                                        else match String.charAt(next, s) {
                                            case ',' => loop(next + 1, acc2)
                                            case '}' => Ok((Json.JObject(acc2), next + 1))
                                            case c   => Err("Expected ',' or '}' in object at position ${next}, found '${c}'")
                                        }
                                }
                    }
            };
            loop(i1, Map.empty())
        }

}
