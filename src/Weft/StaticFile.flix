pub mod Weft.StaticFile {
    use Weft.Mime
    use Weft.StaticFile

    ///
    /// A resolved static asset returned by `StaticStore`.
    ///
    pub enum StaticFile {
        case StaticFile({
            data           = Vector[Int8],
            contentType    = String,
            lastModifiedMs = Int64,
            etag           = String
        })
    }

    instance Eq[StaticFile] {
        pub def eq(a: StaticFile, b: StaticFile): Bool =
            let StaticFile.StaticFile(x) = a;
            let StaticFile.StaticFile(y) = b;
            x#data == y#data and
            x#contentType == y#contentType and
            x#lastModifiedMs == y#lastModifiedMs and
            x#etag == y#etag
    }

    ///
    /// Constructs a `StaticFile` with explicit metadata.
    ///
    pub def make(
        data: Vector[Int8],
        contentType: String,
        lastModifiedMs: Int64,
        etag: String
    ): StaticFile =
        StaticFile.StaticFile({
            data           = data,
            contentType    = contentType,
            lastModifiedMs = lastModifiedMs,
            etag           = etag
        })

    ///
    /// Constructs a `StaticFile` from its path, bytes, and modification time, automatically
    /// inferring MIME type via `Weft.Mime.fromPath` and computing a deterministic strong ETag.
    ///
    pub def fromBytes(path: String, data: Vector[Int8], lastModifiedMs: Int64): StaticFile =
        StaticFile.StaticFile({
            data           = data,
            contentType    = Mime.fromPath(path),
            lastModifiedMs = lastModifiedMs,
            etag           = computeEtag(data)
        })

    pub def data(f: StaticFile): Vector[Int8]  = let StaticFile.StaticFile(r) = f; r#data
    pub def contentType(f: StaticFile): String = let StaticFile.StaticFile(r) = f; r#contentType
    pub def lastModifiedMs(f: StaticFile): Int64 = let StaticFile.StaticFile(r) = f; r#lastModifiedMs
    pub def etag(f: StaticFile): String        = let StaticFile.StaticFile(r) = f; r#etag
    pub def size(f: StaticFile): Int32         = Vector.length(data(f))

    ///
    /// Computes a deterministic quoted ETag (`"<byteLen>-<fnv1a64Hex>"`) purely over the file bytes.
    ///
    pub def computeEtag(bs: Vector[Int8]): String = {
        let len = Vector.length(bs);
        let hash = fnv1a64(bs);
        let hex = toHex64(hash);
        "\"${len}-${hex}\""
    }

    def fnv1a64(bs: Vector[Int8]): Int64 = {
        let offsetBasis = -3750763034362895579i64; // 0xcbf29ce484222325
        let prime = 1099511628211i64;             // 0x100000001b3
        let len = Vector.length(bs);
        def loop(i: Int32, h: Int64): Int64 =
            if (i >= len) h
            else {
                let b = Int64.bitwiseAnd(Int8.toInt64(Vector.get(i, bs)), 255i64);
                let next = Int64.bitwiseXor(h, b) * prime;
                loop(i + 1, next)
            };
        loop(0, offsetBasis)
    }

    def toHex64(v: Int64): String = region rc {
        let sb = StringBuilder.empty(rc);
        def hexDigit(n: Int32): Char = match n {
            case 0  => '0'
            case 1  => '1'
            case 2  => '2'
            case 3  => '3'
            case 4  => '4'
            case 5  => '5'
            case 6  => '6'
            case 7  => '7'
            case 8  => '8'
            case 9  => '9'
            case 10 => 'a'
            case 11 => 'b'
            case 12 => 'c'
            case 13 => 'd'
            case 14 => 'e'
            case _  => 'f'
        };
        def loop(shift: Int32): Unit \ rc =
            if (shift < 0) ()
            else {
                let shifted = Int64.logicalRightShift({ dist = shift }, v);
                let nibble = Int64.clampToInt32(min = 0, max = 15, Int64.bitwiseAnd(shifted, 15i64));
                StringBuilder.append(hexDigit(nibble), sb);
                loop(shift - 4)
            };
        loop(60);
        StringBuilder.toString(sb)
    }

}
