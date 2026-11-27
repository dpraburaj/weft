pub mod Weft.Body {
    use Weft.Body
    use Weft.StreamWriter

    import java.io.ByteArrayOutputStream
    import java.lang.{String => JString}
    import java.nio.charset.StandardCharsets

    ///
    /// Immutable HTTP request/response body supporting UTF-8 text, raw binary payloads,
    /// and chunked `IO` streams (for SSE, large exports, or live feeds).
    ///
    pub enum Body {
        case Empty
        case Text(String)
        case Bytes(Vector[Int8])
        case Stream(StreamWriter -> Unit \ IO)
    }

    instance Eq[Body] {
        pub def eq(a: Body, b: Body): Bool = match (a, b) {
            case (Body.Empty, Body.Empty)         => true
            case (Body.Text(x), Body.Text(y))     => x == y
            case (Body.Bytes(x), Body.Bytes(y))   => x == y
            case (Body.Stream(_), _)              => false
            case (_, Body.Stream(_))              => false
            case _                                => asBytes(a) == asBytes(b)
        }
    }

    instance ToString[Body] {
        pub def toString(b: Body): String = match b {
            case Body.Empty     => "Body.Empty"
            case Body.Text(s)   => "Body.Text(${s})"
            case Body.Bytes(bs) => "Body.Bytes(${Vector.length(bs)} bytes)"
            case Body.Stream(_) => "Body.Stream(<streaming>)"
        }
    }

    ///
    /// Returns an empty HTTP body.
    ///
    pub def empty(): Body = Body.Empty

    ///
    /// Wraps a UTF-8 `String` as a `Body`. Empty strings canonicalize to `Body.Empty`.
    ///
    pub def text(s: String): Body =
        if (String.isEmpty(s)) Body.Empty else Body.Text(s)

    ///
    /// Wraps an immutable byte vector (`Vector[Int8]`) as a `Body`. Empty vectors canonicalize to `Body.Empty`.
    ///
    pub def bytes(bs: Vector[Int8]): Body =
        if (Vector.isEmpty(bs)) Body.Empty else Body.Bytes(bs)

    ///
    /// Wraps a chunked streaming writer callback as a `Body`.
    ///
    pub def stream(writer: StreamWriter -> Unit \ IO): Body =
        Body.Stream(writer)

    ///
    /// Convenience constructor from a `List[Int8]`.
    ///
    pub def fromByteList(bs: List[Int8]): Body =
        bytes(List.toVector(bs))

    ///
    /// Returns `true` if the body contains zero bytes (`false` for streams).
    ///
    pub def isEmpty(b: Body): Bool = match b {
        case Body.Empty     => true
        case Body.Text(s)   => String.isEmpty(s)
        case Body.Bytes(bs) => Vector.isEmpty(bs)
        case Body.Stream(_) => false
    }

    ///
    /// Returns `true` if the body is stored as raw binary bytes.
    ///
    pub def isBinary(b: Body): Bool = match b {
        case Body.Bytes(_) => true
        case _             => false
    }

    ///
    /// Returns `true` if the body is a chunked stream (`Body.Stream`).
    ///
    pub def isStream(b: Body): Bool = match b {
        case Body.Stream(_) => true
        case _              => false
    }

    ///
    /// Returns the exact payload length in bytes (`-1` for streaming bodies whose length
    /// is not known ahead of time).
    ///
    pub def byteLength(b: Body): Int32 = match b {
        case Body.Empty     => 0
        case Body.Text(s)   =>
            if (String.isEmpty(s)) 0
            else unsafe IO { Array.length(s.getBytes(StandardCharsets.UTF_8)) }
        case Body.Bytes(bs) => Vector.length(bs)
        case Body.Stream(_) => -1
    }

    ///
    /// Fast-path check for whether a non-streaming body is at least `minBytes` UTF-8 bytes
    /// long without encoding `Body.Text` when character count alone decides the result.
    ///
    pub def meetsMinBytes(minBytes: Int32, b: Body): Bool =
        if (minBytes <= 0)
            not isStream(b)
        else match b {
            case Body.Empty     => false
            case Body.Stream(_) => false
            case Body.Bytes(bs) => Vector.length(bs) >= minBytes
            case Body.Text(s)   =>
                let chars = String.length(s);
                if (chars >= minBytes) true
                else if (chars * 4 < minBytes) false
                else byteLength(b) >= minBytes
        }

    ///
    /// Decodes a non-streaming body as a UTF-8 `String` (returns `""` for `Body.Stream`;
    /// use `collectText` to materialize a streaming body in `IO`).
    ///
    pub def asText(b: Body): String = match b {
        case Body.Empty     => ""
        case Body.Text(s)   => s
        case Body.Bytes(bs) => utf8String(bs)
        case Body.Stream(_) => ""
    }

    ///
    /// Returns the raw byte representation (`Vector[Int8]`) of a non-streaming body
    /// (returns empty for `Body.Stream`; use `collectBytes` to materialize a stream in `IO`).
    ///
    pub def asBytes(b: Body): Vector[Int8] = match b {
        case Body.Empty     => Vector.empty()
        case Body.Text(s)   => utf8Bytes(s)
        case Body.Bytes(bs) => bs
        case Body.Stream(_) => Vector.empty()
    }

    ///
    /// Materializes any `Body` (including `Body.Stream`) into raw bytes.
    /// Useful for testing streaming/SSE handlers directly without opening a socket.
    ///
    pub def collectBytes(b: Body): Vector[Int8] \ IO = match b {
        case Body.Stream(fn) =>
            let out = new ByteArrayOutputStream();
            let writer = StreamWriter.make(
                bs -> out.write(Vector.toArray(Static, bs)),
                () -> ()
            );
            fn(writer);
            Array.toVector(out.toByteArray())
        case other =>
            asBytes(other)
    }

    ///
    /// Materializes any `Body` (including `Body.Stream`) into a UTF-8 `String`.
    ///
    pub def collectText(b: Body): String \ IO =
        utf8String(collectBytes(b))

    ///
    /// Encodes a `String` into UTF-8 bytes (`Vector[Int8]`).
    ///
    pub def utf8Bytes(s: String): Vector[Int8] =
        if (String.isEmpty(s))
            Vector.empty()
        else
            unsafe IO {
                let arr = s.getBytes(StandardCharsets.UTF_8);
                Array.toVector(arr)
            }

    ///
    /// Decodes UTF-8 bytes (`Vector[Int8]`) into a `String`.
    ///
    pub def utf8String(bs: Vector[Int8]): String =
        if (Vector.isEmpty(bs))
            ""
        else
            unsafe IO {
                let arr = Vector.toArray(Static, bs);
                new JString(arr, StandardCharsets.UTF_8)
            }

}
