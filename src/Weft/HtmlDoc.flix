pub mod Weft.HtmlDoc {
    use Weft.HtmlDoc
    use Weft.IntoResponse
    use Weft.Response
    use Weft.Status

    ///
    /// A rendered HTML document or fragment produced by `Weft.Html`.
    ///
    /// Implements `IntoResponse`, so route handlers can return `HtmlDoc` directly
    /// (with `Content-Type: text/html; charset=utf-8`), or wrap it in `WithStatus`
    /// for non-200 status codes.
    ///
    pub enum HtmlDoc with Eq {
        case HtmlDoc(String)
    }

    instance ToString[HtmlDoc] {
        pub def toString(doc: HtmlDoc): String =
            let HtmlDoc.HtmlDoc(s) = doc;
            s
    }

    instance IntoResponse[HtmlDoc] {
        pub def intoResponse(doc: HtmlDoc): Response =
            Response.html(Weft.HtmlDoc.toHtmlString(doc))
    }

    ///
    /// Extracts the rendered HTML string.
    ///
    pub def toHtmlString(doc: HtmlDoc): String =
        let HtmlDoc.HtmlDoc(s) = doc;
        s

    ///
    /// Wraps the `HtmlDoc` in a `200 OK` `text/html; charset=utf-8` `Response`.
    ///
    pub def toResponse(doc: HtmlDoc): Response =
        Response.html(toHtmlString(doc))

    ///
    /// Wraps the `HtmlDoc` in a `text/html; charset=utf-8` `Response` with a custom `Status`.
    ///
    pub def toResponseWithStatus(st: Status, doc: HtmlDoc): Response =
        Response.html(toHtmlString(doc)) |> Response.withStatus(st)

}
