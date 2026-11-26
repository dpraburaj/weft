pub mod Weft.Headers {
    use Weft.Headers

    ///
    /// Case-insensitive HTTP headers supporting multiple values per header name.
    /// Stores `(canonicalName, values)` keyed by lower-cased header name.
    ///
    pub enum Headers with Eq {
        case Headers(Map[String, (String, List[String])])
    }

    ///
    /// Returns an empty `Headers` map.
    ///
    pub def empty(): Headers = Headers.Headers(Map.empty())

    ///
    /// Returns a `Headers` map with a single header entry.
    ///
    pub def singleton(name: String, value: String): Headers =
        set(name, value, empty())

    ///
    /// Replaces all values for `name` (case-insensitive) with a single `value`.
    ///
    pub def set(name: String, value: String, h: Headers): Headers =
        let Headers.Headers(m) = h;
        let key = String.toLowerCase(name);
        Headers.Headers(Map.insert(key, (name, value :: Nil), m))

    ///
    /// Appends `value` to any existing values for `name` (case-insensitive).
    /// Useful for multi-value headers like `Set-Cookie`.
    ///
    pub def add(name: String, value: String, h: Headers): Headers =
        let Headers.Headers(m) = h;
        let key = String.toLowerCase(name);
        match Map.get(key, m) {
            case Some((origName, vals)) =>
                Headers.Headers(Map.insert(key, (origName, List.append(vals, value :: Nil)), m))
            case None =>
                Headers.Headers(Map.insert(key, (name, value :: Nil), m))
        }

    ///
    /// Returns the first value for `name` (case-insensitive), if present.
    ///
    pub def get(name: String, h: Headers): Option[String] =
        match getAll(name, h) {
            case x :: _ => Some(x)
            case Nil    => None
        }

    ///
    /// Returns all values for `name` (case-insensitive).
    ///
    pub def getAll(name: String, h: Headers): List[String] =
        let Headers.Headers(m) = h;
        match Map.get(String.toLowerCase(name), m) {
            case Some((_, vals)) => vals
            case None            => Nil
        }

    ///
    /// Returns `true` if `name` (case-insensitive) is present.
    ///
    pub def contains(name: String, h: Headers): Bool =
        let Headers.Headers(m) = h;
        Map.memberOf(String.toLowerCase(name), m)

    ///
    /// Removes all values for `name` (case-insensitive).
    ///
    pub def remove(name: String, h: Headers): Headers =
        let Headers.Headers(m) = h;
        Headers.Headers(Map.remove(String.toLowerCase(name), m))

    ///
    /// Merges `overlay` onto `base`. For colliding keys, `overlay` replaces `base`.
    ///
    pub def merge(base: Headers, overlay: Headers): Headers =
        let Headers.Headers(m1) = base;
        let Headers.Headers(m2) = overlay;
        Headers.Headers(Map.unionWith((_, v2) -> v2, m1, m2))

    ///
    /// Returns a flat list of `(name, value)` pairs.
    ///
    pub def toList(h: Headers): List[(String, String)] =
        let Headers.Headers(m) = h;
        Map.valuesOf(m)
            |> List.flatMap(match (origName, vals) -> List.map(v -> (origName, v), vals))

    ///
    /// Builds `Headers` from a list of `(name, value)` pairs, preserving multi-values.
    ///
    pub def fromList(pairs: List[(String, String)]): Headers =
        List.foldLeft((acc, pair) -> {
            let (k, v) = pair;
            add(k, v, acc)
        }, empty(), pairs)

}
