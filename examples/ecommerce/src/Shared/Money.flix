pub mod Shared.Money {

    pub def categories(): List[(String, String)] =
        ("coffee",      "Single-Origin Coffee") ::
        ("grinders",    "Grinders") ::
        ("brewers",     "Brewers") ::
        ("accessories", "Accessories") ::
        Nil

    pub def orderStatuses(): List[String] =
        "paid" :: "roasted" :: "shipped" :: "delivered" :: Nil

    ///
    /// Formats integer cents into USD display string (e.g. `19900i64` -> `"$199.00"`).
    ///
    pub def formatCents(cents: Int64): String = {
        let neg = cents < 0i64;
        let abs = if (neg) 0i64 - cents else cents;
        let dollars = abs / 100i64;
        let rem = Int64.modulo(abs, 100i64);
        let padRem = if (rem < 10i64) "0${rem}" else "${rem}";
        let sign = if (neg) "-" else "";
        "${sign}$${dollars}.${padRem}"
    }

    ///
    /// Converts a display name into a URL-safe lowercase slug.
    ///
    pub def slugify(raw: String): String = region rc {
        let sb = StringBuilder.empty(rc);
        let lower = String.toLowerCase(String.trim(raw));
        let len = String.length(lower);
        def loop(i: Int32, lastDash: Bool): Unit \ rc = {
            if (i >= len) ()
            else {
                let c = String.charAt(i, lower);
                if (Char.isLetterOrDigit(c)) {
                    StringBuilder.append(c, sb);
                    loop(i + 1, false)
                } else if (not lastDash and StringBuilder.length(sb) > 0) {
                    StringBuilder.append('-', sb);
                    loop(i + 1, true)
                } else {
                    loop(i + 1, lastDash)
                }
            }
        };
        loop(0, false);
        let res = StringBuilder.toString(sb);
        match String.stripSuffix({substr = "-"}, res) {
            case Some(trimmed) => trimmed
            case None          => res
        }
    }

}
