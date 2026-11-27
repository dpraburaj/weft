pub mod Weft.StreamWriter {
    use Weft.SseEvent
    use Weft.StreamWriter

    import java.nio.charset.StandardCharsets

    ///
    /// Streaming response sink passed to `Response.stream` and `Response.sse` callbacks.
    /// Each write goes directly to the underlying chunked HTTP output stream (or an
    /// in-memory buffer during `Response.collectBodyBytes` tests).
    ///
    pub enum StreamWriter {
        case StreamWriter({
            writeBytes = Vector[Int8] -> Unit \ IO,
            flush      = Unit -> Unit \ IO
        })
    }

    pub def make(
        writeBytesFn: Vector[Int8] -> Unit \ IO,
        flushFn: Unit -> Unit \ IO
    ): StreamWriter =
        StreamWriter.StreamWriter({
            writeBytes = writeBytesFn,
            flush      = flushFn
        })

    ///
    /// Writes raw bytes to the stream without forcing a flush.
    ///
    pub def writeBytes(bs: Vector[Int8], w: StreamWriter): Unit \ IO =
        if (Vector.isEmpty(bs))
            ()
        else {
            let StreamWriter.StreamWriter(r) = w;
            (r#writeBytes)(bs)
        }

    ///
    /// Writes a UTF-8 string to the stream without forcing a flush.
    ///
    pub def writeText(s: String, w: StreamWriter): Unit \ IO =
        if (String.isEmpty(s))
            ()
        else {
            let arr = s.getBytes(StandardCharsets.UTF_8);
            writeBytes(Array.toVector(arr), w)
        }

    ///
    /// Flushes any buffered bytes to the client immediately.
    ///
    pub def flush(w: StreamWriter): Unit \ IO = {
        let StreamWriter.StreamWriter(r) = w;
        (r#flush)()
    }

    ///
    /// Writes raw bytes and flushes immediately.
    ///
    pub def writeChunk(bs: Vector[Int8], w: StreamWriter): Unit \ IO = {
        writeBytes(bs, w);
        flush(w)
    }

    ///
    /// Writes a UTF-8 text chunk and flushes immediately.
    ///
    pub def writeTextChunk(s: String, w: StreamWriter): Unit \ IO = {
        writeText(s, w);
        flush(w)
    }

    ///
    /// Encodes and streams a single `SseEvent`, flushing immediately so the client
    /// receives it in real time.
    ///
    pub def sendSse(ev: SseEvent, w: StreamWriter): Unit \ IO =
        writeTextChunk(SseEvent.encode(ev), w)

    ///
    /// Convenience helper sending an unnamed SSE `data:` frame and flushing immediately.
    ///
    pub def sendSseData(payload: String, w: StreamWriter): Unit \ IO =
        sendSse(SseEvent.data(payload), w)

    ///
    /// Sends an SSE keep-alive comment (`": <text>\n\n"`) and flushes immediately.
    ///
    pub def sendSseComment(text: String, w: StreamWriter): Unit \ IO =
        writeTextChunk(SseEvent.comment(text), w)

}
