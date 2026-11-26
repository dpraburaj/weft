pub mod Weft.SessionData {
    use Weft.Json
    use Weft.SessionData

    ///
    /// Immutable snapshot of a persisted HTTP session.
    ///
    pub enum SessionData {
        case SessionData({
            id          = String,
            values      = Map[String, String],
            flashes     = Map[String, String],
            expiresAtMs = Int64,
            createdAtMs = Int64,
            updatedAtMs = Int64
        })
    }

    instance Eq[SessionData] {
        pub def eq(a: SessionData, b: SessionData): Bool =
            let SessionData.SessionData(x) = a;
            let SessionData.SessionData(y) = b;
            x#id == y#id and
            x#values == y#values and
            x#flashes == y#flashes and
            x#expiresAtMs == y#expiresAtMs and
            x#createdAtMs == y#createdAtMs and
            x#updatedAtMs == y#updatedAtMs
    }

    instance ToString[SessionData] {
        pub def toString(s: SessionData): String =
            "SessionData(id=${id(s)}, expiresAtMs=${expiresAtMs(s)}, payload=${encodePayload(s)})"
    }

    pub def make(
        id: String,
        values: Map[String, String],
        flashes: Map[String, String],
        expiresAtMs: Int64,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ): SessionData =
        SessionData.SessionData({
            id          = id,
            values      = values,
            flashes     = flashes,
            expiresAtMs = expiresAtMs,
            createdAtMs = createdAtMs,
            updatedAtMs = updatedAtMs
        })

    pub def id(s: SessionData): String                  = let SessionData.SessionData(r) = s; r#id
    pub def values(s: SessionData): Map[String, String] = let SessionData.SessionData(r) = s; r#values
    pub def flashes(s: SessionData): Map[String, String]= let SessionData.SessionData(r) = s; r#flashes
    pub def expiresAtMs(s: SessionData): Int64          = let SessionData.SessionData(r) = s; r#expiresAtMs
    pub def createdAtMs(s: SessionData): Int64          = let SessionData.SessionData(r) = s; r#createdAtMs
    pub def updatedAtMs(s: SessionData): Int64          = let SessionData.SessionData(r) = s; r#updatedAtMs

    pub def isExpired(nowMs: Int64, s: SessionData): Bool =
        expiresAtMs(s) <= nowMs

    ///
    /// Serializes `values` and `flashes` as a JSON string for SQL/external storage.
    ///
    pub def encodePayload(s: SessionData): String = {
        let valsObj = Json.JObject(Map.map(Json.str, values(s)));
        let flashObj = Json.JObject(Map.map(Json.str, flashes(s)));
        Json.encode(
            Json.obj(
                ("values", valsObj) ::
                ("flashes", flashObj) ::
                Nil
            )
        )
    }

    ///
    /// Decodes a JSON payload produced by `encodePayload` into `(values, flashes)`.
    ///
    pub def decodePayload(raw: String): Result[String, (Map[String, String], Map[String, String])] =
        match Json.parse(raw) {
            case Err(msg) => Err(msg)
            case Ok(j) =>
                let vals = decodeStringMap(Json.getField("values", j));
                let fls = decodeStringMap(Json.getField("flashes", j));
                Ok((vals, fls))
        }

    def decodeStringMap(opt: Option[Json]): Map[String, String] =
        match Option.flatMap(Json.asObject, opt) {
            case None => Map.empty()
            case Some(m) =>
                Map.foldLeftWithKey((acc, k, v) -> match Json.asString(v) {
                    case Some(s) => Map.insert(k, s, acc)
                    case None    => acc
                }, Map.empty(), m)
        }

}
