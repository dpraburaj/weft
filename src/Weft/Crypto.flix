pub mod Weft.Crypto {
    use Weft.Body
    use Weft.Random

    import java.lang.IllegalArgumentException
    import java.security.MessageDigest
    import java.util.Base64
    import javax.crypto.Mac
    import javax.crypto.SecretKeyFactory
    import javax.crypto.spec.PBEKeySpec
    import javax.crypto.spec.SecretKeySpec

    ///
    /// Default PBKDF2-HMAC-SHA256 iteration count (OWASP recommendation).
    ///
    pub def defaultPasswordIterations(): Int32 = 210000

    // --- Hashing & MACs ---

    ///
    /// Computes the SHA-256 digest of `data`.
    ///
    pub def sha256(data: Vector[Int8]): Vector[Int8] =
        unsafe IO {
            let md = MessageDigest.getInstance("SHA-256");
            let out = md.digest(Vector.toArray(Static, data));
            Array.toVector(out)
        }

    ///
    /// Computes the lowercase hex-encoded SHA-256 digest of UTF-8 string `s`.
    ///
    pub def sha256Hex(s: String): String =
        hexEncode(sha256(Body.utf8Bytes(s)))

    ///
    /// Computes the HMAC-SHA256 authentication tag over raw bytes `message` using `secret`.
    ///
    pub def hmacSha256(secret: String, message: Vector[Int8]): Vector[Int8] =
        unsafe IO {
            let mac = Mac.getInstance("HmacSHA256");
            let keySpec = new SecretKeySpec(Vector.toArray(Static, Body.utf8Bytes(secret)), "HmacSHA256");
            mac.init(keySpec);
            let out = mac.doFinal(Vector.toArray(Static, message));
            Array.toVector(out)
        }

    ///
    /// Computes the lowercase hex-encoded HMAC-SHA256 of UTF-8 string `message`.
    ///
    pub def hmacSha256Hex(secret: String, message: String): String =
        hexEncode(hmacSha256(secret, Body.utf8Bytes(message)))

    ///
    /// Computes the URL-safe unpadded Base64 HMAC-SHA256 of UTF-8 string `message`.
    ///
    pub def hmacSha256Base64Url(secret: String, message: String): String =
        base64UrlEncode(hmacSha256(secret, Body.utf8Bytes(message)))

    // --- Constant-Time Comparisons & Webhook Verification ---

    ///
    /// Compares two byte vectors in constant time to prevent timing attacks.
    ///
    pub def constantTimeEqBytes(a: Vector[Int8], b: Vector[Int8]): Bool =
        unsafe IO {
            MessageDigest.isEqual(Vector.toArray(Static, a), Vector.toArray(Static, b))
        }

    ///
    /// Compares two UTF-8 strings in constant time to prevent timing attacks.
    ///
    pub def constantTimeEq(a: String, b: String): Bool =
        constantTimeEqBytes(Body.utf8Bytes(a), Body.utf8Bytes(b))

    ///
    /// Verifies a hex-encoded HMAC-SHA256 signature over raw payload bytes in constant time
    /// (ideal for Stripe, GitHub, Razorpay, and other webhook signature checks).
    ///
    pub def verifyHmacHex(secret: String, rawPayload: Vector[Int8], expectedHex: String): Bool = {
        let computed = hexEncode(hmacSha256(secret, rawPayload));
        constantTimeEq(computed, String.toLowerCase(String.trim(expectedHex)))
    }

    // --- Signed Values (HMAC-SHA256) ---

    ///
    /// Signs `value` with `secret`, producing `"<value>.<hmacBase64Url>"`.
    /// Suitable for tamper-evident cookie values and session IDs.
    ///
    pub def signValue(secret: String, value: String): String = {
        let sig = hmacSha256Base64Url(secret, value);
        "${value}.${sig}"
    }

    ///
    /// Verifies a signed string produced by `signValue`, returning `Some(value)` if the
    /// HMAC signature is valid or `None` if tampered or malformed.
    ///
    pub def verifySignedValue(secret: String, signed: String): Option[String] =
        match String.indexOfRight({substr = "."}, signed) {
            case None => None
            case Some(dotIdx) =>
                let value = String.sliceLeft({end = dotIdx}, signed);
                let providedSig = String.sliceRight({start = dotIdx + 1}, signed);
                if (String.isEmpty(providedSig))
                    None
                else {
                    let expectedSig = hmacSha256Base64Url(secret, value);
                    if (constantTimeEq(expectedSig, providedSig)) Some(value) else None
                }
        }

    // --- Password Hashing (PBKDF2-HMAC-SHA256) ---

    ///
    /// Hashes `password` using PBKDF2-HMAC-SHA256 with a 16-byte random salt and
    /// `defaultPasswordIterations()` (210,000 iterations).
    ///
    /// Returns a self-describing encoded string:
    /// `"pbkdf2_sha256$<iterations>$<saltBase64Url>$<hashBase64Url>"`.
    ///
    pub def hashPassword(password: String): String \ Random =
        hashPasswordWithIterations(defaultPasswordIterations(), password)

    ///
    /// Hashes `password` using PBKDF2-HMAC-SHA256 with an explicit iteration count
    /// (useful for fast deterministic unit tests while production uses `hashPassword`).
    ///
    pub def hashPasswordWithIterations(iterations: Int32, password: String): String \ Random = {
        let safeIters = Int32.max(1, iterations);
        let salt = Random.nextBytes(16);
        let derived = pbkdf2Sha256(password, salt, safeIters, 32);
        "pbkdf2_sha256\$${safeIters}\$${base64UrlEncode(salt)}\$${base64UrlEncode(derived)}"
    }

    ///
    /// Verifies a plaintext `password` against an encoded hash from `hashPassword` in constant time.
    ///
    pub def verifyPassword(password: String, encodedHash: String): Bool = {
        let parts = String.splitOn({substr = "$"}, encodedHash);
        match parts {
            case "pbkdf2_sha256" :: iterStr :: saltB64 :: hashB64 :: Nil =>
                match (Int32.fromString(iterStr), base64UrlDecode(saltB64), base64UrlDecode(hashB64)) {
                    case (Some(iters), Ok(salt), Ok(expectedHash)) if iters > 0 and Vector.length(expectedHash) > 0 =>
                        let derived = pbkdf2Sha256(password, salt, iters, Vector.length(expectedHash));
                        constantTimeEqBytes(derived, expectedHash)
                    case _ => false
                }
            case _ => false
        }
    }

    // --- Encoding Helpers ---

    ///
    /// Encodes bytes into URL-safe Base64 without padding.
    ///
    pub def base64UrlEncode(bs: Vector[Int8]): String =
        if (Vector.isEmpty(bs))
            ""
        else
            unsafe IO {
                let enc = Base64.getUrlEncoder();
                let unpadded = enc.withoutPadding();
                unpadded.encodeToString(Vector.toArray(Static, bs))
            }

    ///
    /// Decodes a URL-safe Base64 string (padded or unpadded) into bytes.
    ///
    pub def base64UrlDecode(s: String): Result[String, Vector[Int8]] =
        if (String.isEmpty(s))
            Ok(Vector.empty())
        else
            try {
                unsafe IO {
                    let dec = Base64.getUrlDecoder();
                    Ok(Array.toVector(dec.decode(s)))
                }
            } catch {
                case _: IllegalArgumentException => Err("Invalid Base64URL input")
            }

    ///
    /// Encodes bytes into a lowercase hexadecimal string.
    ///
    pub def hexEncode(bs: Vector[Int8]): String = region rc {
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

    ///
    /// Decodes a hexadecimal string into raw bytes.
    ///
    pub def hexDecode(s: String): Result[String, Vector[Int8]] = {
        let len = String.length(s);
        if (Int32.modulo(len, 2) != 0)
            Err("Hex string must have even length")
        else
            region rc {
                let byteLen = len / 2;
                let arr = Array.repeat(rc, byteLen, 0i8);
                def loop(i: Int32): Result[String, Vector[Int8]] \ rc = {
                    if (i >= byteLen)
                        Ok(Array.toVector(arr))
                    else {
                        match (hexNibble(String.charAt(i * 2, s)), hexNibble(String.charAt(i * 2 + 1, s))) {
                            case (Some(hi), Some(lo)) =>
                                let raw = (hi * 16) + lo;
                                let signed = if (raw >= 128)
                                    Int32.clampToInt8(min = -128i8, max = 127i8, raw - 256)
                                else
                                    Int32.clampToInt8(min = -128i8, max = 127i8, raw);
                                Array.put(signed, i, arr);
                                loop(i + 1)
                            case _ =>
                                Err("Invalid hex character at byte index ${i}")
                        }
                    }
                };
                loop(0)
            }
    }

    // --- Internal Helpers ---

    def pbkdf2Sha256(password: String, salt: Vector[Int8], iterations: Int32, keyBytes: Int32): Vector[Int8] =
        unsafe IO {
            let chars = password.toCharArray();
            let saltArr = Vector.toArray(Static, salt);
            let spec = new PBEKeySpec(chars, saltArr, iterations, keyBytes * 8);
            let skf = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
            let secretKey = skf.generateSecret(spec);
            let encoded = secretKey.getEncoded();
            spec.clearPassword();
            Array.toVector(encoded)
        }

    def hexNibble(c: Char): Option[Int32] = {
        let cp = Char.toBmpCodePoint(c);
        if (cp >= 48 and cp <= 57) Some(cp - 48)
        else if (cp >= 97 and cp <= 102) Some(10 + cp - 97)
        else if (cp >= 65 and cp <= 70) Some(10 + cp - 65)
        else None
    }

}
