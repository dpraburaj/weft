pub mod Weft.Body {
    use Weft.Body

    import java.lang.{String => JString}
    import java.nio.charset.StandardCharsets

    ///
    /// Immutable HTTP request/response body supporting both UTF-8 text and arbitrary binary payloads.
    ///
    pub enum Body {
        case Empty
        case Text(String)
        case Bytes(Vector[Int8])
    }

    instance Eq[Body] {
        pub def eq(a: Body, b: Body): Bool = match (a, b) {
            case (Body.Empty, Body.Empty)         => true
            case (Body.Text(x), Body.Text(y))     => x == y
            case (Body.Bytes(x), Body.Bytes(y))   => x == y
            case _                                => asBytes(a) == asBytes(b)
        }
    }

    instance ToString[Body] {
        pub def toString(b: Body): String = match b {
            case Body.Empty     => "Body.Empty"
            case Body.Text(s)   => "Body.Text(${s})"
            case Body.Bytes(bs) => "Body.Bytes(${Vector.length(bs)} bytes)"
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
    /// Convenience constructor from a `List[Int8]`.
    ///
    pub def fromByteList(bs: List[Int8]): Body =
        bytes(List.toVector(bs))

    ///
    /// Returns `true` if the body contains zero bytes.
    ///
    pub def isEmpty(b: Body): Bool = match b {
        case Body.Empty     => true
        case Body.Text(s)   => String.isEmpty(s)
        case Body.Bytes(bs) => Vector.isEmpty(bs)
    }

    ///
    /// Returns `true` if the body is stored as raw binary bytes.
    ///
    pub def isBinary(b: Body): Bool = match b {
        case Body.Bytes(_) => true
        case _             => false
    }

    ///
    /// Returns the exact payload length in bytes.
    ///
    pub def byteLength(b: Body): Int32 = match b {
        case Body.Empty     => 0
        case Body.Text(s)   => Vector.length(utf8Bytes(s))
        case Body.Bytes(bs) => Vector.length(bs)
    }

    ///
    /// Decodes the body as a UTF-8 `String`.
    ///
    pub def asText(b: Body): String = match b {
        case Body.Empty     => ""
        case Body.Text(s)   => s
        case Body.Bytes(bs) => utf8String(bs)
    }

    ///
    /// Returns the raw byte representation (`Vector[Int8]`) of the body.
    ///
    pub def asBytes(b: Body): Vector[Int8] = match b {
        case Body.Empty     => Vector.empty()
        case Body.Text(s)   => utf8Bytes(s)
        case Body.Bytes(bs) => bs
    }

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
