pub mod Weft.SseEvent {
    use Weft.Json
    use Weft.SseEvent

    ///
    /// Represents a single Server-Sent Event (SSE) frame per the WHATWG EventSource spec.
    ///
    pub enum SseEvent {
        case SseEvent({
            id      = Option[String],
            event   = Option[String],
            data    = String,
            retryMs = Option[Int64]
        })
    }

    instance Eq[SseEvent] {
        pub def eq(a: SseEvent, b: SseEvent): Bool =
            let SseEvent.SseEvent(x) = a;
            let SseEvent.SseEvent(y) = b;
            x#id == y#id and
            x#event == y#event and
            x#data == y#data and
            x#retryMs == y#retryMs
    }

    instance ToString[SseEvent] {
        pub def toString(e: SseEvent): String = encode(e)
    }

    ///
    /// Creates an unnamed SSE event with `payload` as its `data:` field.
    ///
    pub def data(payload: String): SseEvent =
        SseEvent.SseEvent({
            id      = None,
            event   = None,
            data    = payload,
            retryMs = None
        })

    ///
    /// Creates a named SSE event (`event: <name>` + `data: <payload>`).
    ///
    pub def named(eventName: String, payload: String): SseEvent =
        data(payload) |> withEvent(eventName)

    ///
    /// Creates an unnamed SSE event whose `data:` is a compact JSON string.
    ///
    pub def json(payload: Json): SseEvent =
        data(Json.encode(payload))

    ///
    /// Creates a named SSE event whose `data:` is a compact JSON string.
    ///
    pub def namedJson(eventName: String, payload: Json): SseEvent =
        named(eventName, Json.encode(payload))

    pub def id(e: SseEvent): Option[String]     = let SseEvent.SseEvent(r) = e; r#id
    pub def event(e: SseEvent): Option[String]  = let SseEvent.SseEvent(r) = e; r#event
    pub def payload(e: SseEvent): String        = let SseEvent.SseEvent(r) = e; r#data
    pub def retryMs(e: SseEvent): Option[Int64] = let SseEvent.SseEvent(r) = e; r#retryMs

    pub def withId(eventId: String, e: SseEvent): SseEvent =
        let SseEvent.SseEvent(r) = e;
        SseEvent.SseEvent({ id = Some(sanitizeField(eventId)) | r })

    pub def withEvent(eventName: String, e: SseEvent): SseEvent =
        let SseEvent.SseEvent(r) = e;
        SseEvent.SseEvent({ event = Some(sanitizeField(eventName)) | r })

    pub def withRetryMs(ms: Int64, e: SseEvent): SseEvent =
        let SseEvent.SseEvent(r) = e;
        SseEvent.SseEvent({ retryMs = Some(Int64.max(0i64, ms)) | r })

    ///
    /// Encodes a keep-alive SSE comment frame (`": <text>\n\n"`).
    ///
    pub def comment(text: String): String =
        ": ${sanitizeField(text)}\n\n"

    ///
    /// Encodes `e` into a spec-compliant SSE text frame terminated by `\n\n`.
    /// Multi-line payloads are automatically split into consecutive `data: ` lines.
    ///
    pub def encode(e: SseEvent): String = region rc {
        let sb = StringBuilder.empty(rc);
        match id(e) {
            case Some(v) => StringBuilder.appendString("id: ${sanitizeField(v)}\n", sb)
            case None    => ()
        };
        match event(e) {
            case Some(v) => StringBuilder.appendString("event: ${sanitizeField(v)}\n", sb)
            case None    => ()
        };
        match retryMs(e) {
            case Some(ms) => StringBuilder.appendString("retry: ${ms}\n", sb)
            case None     => ()
        };
        let normalized = String.replace({src = "\r\n"}, {dst = "\n"}, payload(e))
            |> String.replace({src = "\r"}, {dst = "\n"});
        let lines = String.splitOn({substr = "\n"}, normalized);
        List.forEach(line -> {
            StringBuilder.appendString("data: ${line}\n", sb)
        }, lines);
        StringBuilder.appendString("\n", sb);
        StringBuilder.toString(sb)
    }

    def sanitizeField(s: String): String =
        String.replace({src = "\r"}, {dst = ""}, s)
            |> String.replace({src = "\n"}, {dst = ""})

}
