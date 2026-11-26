pub mod Weft.Random {
    use Weft.Random

    import java.security.SecureRandom
    import java.util.Base64

    ///
    /// Algebraic effect for cryptographically secure random byte generation.
    ///
    /// Production code handles this with `Random.runWithSecureRandom` (`IO`);
    /// tests handle it purely and deterministically with `Random.runDeterministic`
    /// or `Random.runFixedSequence` (zero `IO`).
    ///
    pub eff Random {
        def nextBytes(count: Int32): Vector[Int8]
    }

    ///
    /// Generates a lowercase hexadecimal token from `numBytes` random bytes
    /// (length `2 * numBytes`).
    ///
    pub def tokenHex(numBytes: Int32): String \ Random =
        bytesToHex(Random.nextBytes(numBytes))

    ///
    /// Generates a URL-safe unpadded Base64 token from `numBytes` random bytes.
    /// Ideal for session IDs, CSRF tokens, and password-reset tokens.
    ///
    pub def tokenBase64Url(numBytes: Int32): String \ Random = {
        let bs = Random.nextBytes(numBytes);
        if (Vector.isEmpty(bs))
            ""
        else
            unsafe IO {
                let enc = Base64.getUrlEncoder();
                let unpadded = enc.withoutPadding();
                unpadded.encodeToString(Vector.toArray(Static, bs))
            }
    }

    ///
    /// Generates an RFC 4122 Version 4 UUID string from 16 random bytes.
    ///
    pub def uuidV4(): String \ Random = {
        let raw = Random.nextBytes(16);
        let b6 = Int8.bitwiseOr(Int8.bitwiseAnd(Vector.get(6, raw), 15i8), 64i8);   // version 4
        let b8 = Int8.bitwiseOr(Int8.bitwiseAnd(Vector.get(8, raw), 63i8), -128i8); // variant 10xx
        let hex = bytesToHex(
            Vector.mapWithIndex((i, b) -> if (i == 6) b6 else if (i == 8) b8 else b, raw)
        );
        let p1 = String.slice({start = 0}, {end = 8}, hex);
        let p2 = String.slice({start = 8}, {end = 12}, hex);
        let p3 = String.slice({start = 12}, {end = 16}, hex);
        let p4 = String.slice({start = 16}, {end = 20}, hex);
        let p5 = String.slice({start = 20}, {end = 32}, hex);
        "${p1}-${p2}-${p3}-${p4}-${p5}"
    }

    // --- Handlers ---

    ///
    /// Production handler backed by `java.security.SecureRandom`.
    ///
    pub def runWithSecureRandom(f: Unit -> a \ ef): a \ (ef - Random) + IO = {
        let sr = new SecureRandom();
        run {
            f()
        } with handler Random {
            def nextBytes(count, k) =
                if (count <= 0)
                    k(Vector.empty())
                else {
                    let arr: Array[Int8, IO] = Array.repeat(Static, count, 0i8);
                    sr.nextBytes(arr);
                    k(Array.toVector(arr))
                }
        }
    }

    ///
    /// 100% pure deterministic handler backed by a local region SplitMix64 PRNG.
    /// Ideal for reproducible unit tests (NOT for cryptographic production use).
    ///
    pub def runDeterministic(seed: Int64, f: Unit -> a \ ef): a \ (ef - Random) =
        region rc {
            let state = Ref.fresh(rc, seed);
            run {
                f()
            } with handler Random {
                def nextBytes(count, k) =
                    if (count <= 0)
                        k(Vector.empty())
                    else {
                        let bs = generateSplitMixBytes(count, state);
                        k(bs)
                    }
            }
        }

    ///
    /// 100% pure handler returning predetermined byte vectors in order, falling back to
    /// deterministic bytes once the sequence is exhausted.
    ///
    pub def runFixedSequence(chunks: List[Vector[Int8]], f: Unit -> a \ ef): a \ (ef - Random) =
        region rc {
            let queue = Ref.fresh(rc, chunks);
            let fallbackState = Ref.fresh(rc, 42i64);
            run {
                f()
            } with handler Random {
                def nextBytes(count, k) =
                    match Ref.get(queue) {
                        case next :: rest =>
                            Ref.put(rest, queue);
                            k(next)
                        case Nil =>
                            k(generateSplitMixBytes(Int32.max(0, count), fallbackState))
                    }
            }
        }

    // --- Internal Helpers ---

    def nextSplitMix64(state: Ref[Int64, r]): Int64 \ r = {
        let s = Ref.get(state) + -7046029254386353131i64; // 0x9e3779b97f4a7c15
        Ref.put(s, state);
        let z1 = Int64.bitwiseXor(s, Int64.logicalRightShift({ dist = 30 }, s)) * -4658895280553007687i64;
        let z2 = Int64.bitwiseXor(z1, Int64.logicalRightShift({ dist = 27 }, z1)) * -7723592293110705685i64;
        Int64.bitwiseXor(z2, Int64.logicalRightShift({ dist = 31 }, z2))
    }

    def generateSplitMixBytes(count: Int32, state: Ref[Int64, r]): Vector[Int8] \ r =
        region local {
            let arr = Array.repeat(local, count, 0i8);
            def fill(i: Int32, word: Int64, rem: Int32): Unit \ {r, local} = {
                if (i >= count)
                    ()
                else if (rem <= 0)
                    fill(i, nextSplitMix64(state), 8)
                else {
                    let b = Int64.clampToInt8(min = -128i8, max = 127i8, Int64.bitwiseAnd(word, 255i64) - 128i64);
                    // Preserve full byte range 0..255 mapped cleanly to Int8
                    let rawByte = Int64.bitwiseAnd(word, 255i64);
                    let signedByte = if (rawByte >= 128i64)
                        Int64.clampToInt8(min = -128i8, max = 127i8, rawByte - 256i64)
                    else
                        Int64.clampToInt8(min = -128i8, max = 127i8, rawByte);
                    let _ = b;
                    Array.put(signedByte, i, arr);
                    fill(i + 1, Int64.logicalRightShift({ dist = 8 }, word), rem - 1)
                }
            };
            fill(0, 0i64, 0);
            Array.toVector(arr)
        }

    def bytesToHex(bs: Vector[Int8]): String = region rc {
        let sb = StringBuilder.empty(rc);
        let len = Vector.length(bs);
        def hexChar(n: Int32): Char = match n {
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
        def loop(i: Int32): Unit \ rc = {
            if (i >= len) ()
            else {
                let v = Int32.bitwiseAnd(Int8.toInt32(Vector.get(i, bs)), 255);
                StringBuilder.append(hexChar(Int32.logicalRightShift({ dist = 4 }, v)), sb);
                StringBuilder.append(hexChar(Int32.bitwiseAnd(v, 15)), sb);
                loop(i + 1)
            }
        };
        loop(0);
        StringBuilder.toString(sb)
    }

}
