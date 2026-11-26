pub mod Weft.Method {
    use Weft.Method

    ///
    /// Represents an HTTP request method.
    ///
    pub enum Method with Eq, Order {
        case Get
        case Post
        case Put
        case Patch
        case Delete
        case Head
        case Options
        case Custom(String)
    }

    instance ToString[Method] {
        pub def toString(m: Method): String = match m {
            case Method.Get       => "GET"
            case Method.Post      => "POST"
            case Method.Put       => "PUT"
            case Method.Patch     => "PATCH"
            case Method.Delete    => "DELETE"
            case Method.Head      => "HEAD"
            case Method.Options   => "OPTIONS"
            case Method.Custom(s) => String.toUpperCase(s)
        }
    }

    ///
    /// Parses an HTTP method string (case-insensitive).
    ///
    pub def parse(s: String): Method = match String.toUpperCase(String.trim(s)) {
        case "GET"     => Method.Get
        case "POST"    => Method.Post
        case "PUT"     => Method.Put
        case "PATCH"   => Method.Patch
        case "DELETE"  => Method.Delete
        case "HEAD"    => Method.Head
        case "OPTIONS" => Method.Options
        case other     => Method.Custom(other)
    }

}
