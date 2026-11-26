pub mod Weft.Page {
    use Weft.Json
    use Weft.Page

    ///
    /// Immutable paginated result container for list/catalog endpoints.
    ///
    pub enum Page[a] {
        case Page({
            items      = List[a],
            page       = Int32,
            perPage    = Int32,
            totalItems = Int64,
            totalPages = Int32
        })
    }

    ///
    /// Normalizes a 1-based page number to at least `1`.
    ///
    pub def normalizePage(p: Int32): Int32 = Int32.max(1, p)

    ///
    /// Clamps `perPage` into `[1, maxPerPage]`.
    ///
    pub def clampPerPage(maxPerPage: Int32, perPage: Int32): Int32 =
        Int32.max(1, Int32.min(maxPerPage, perPage))

    ///
    /// Computes the SQL `OFFSET` for a 1-based `page` and `perPage`.
    ///
    pub def offset(page: Int32, perPage: Int32): Int32 =
        (normalizePage(page) - 1) * Int32.max(1, perPage)

    ///
    /// Constructs a `Page[a]`, automatically computing `totalPages`.
    ///
    pub def make(items: List[a], page: Int32, perPage: Int32, totalItems: Int64): Page[a] = {
        let p = normalizePage(page);
        let pp = Int32.max(1, perPage);
        let tot = Int64.max(0i64, totalItems);
        let pp64 = Int32.toInt64(pp);
        let pages64 = if (tot == 0i64) 0i64 else (tot + pp64 - 1i64) / pp64;
        let pages = Int64.clampToInt32(min = 0, max = 2147483647, pages64);
        Page.Page({
            items      = items,
            page       = p,
            perPage    = pp,
            totalItems = tot,
            totalPages = pages
        })
    }

    pub def items(p: Page[a]): List[a]   = let Page.Page(r) = p; r#items
    pub def page(p: Page[a]): Int32      = let Page.Page(r) = p; r#page
    pub def perPage(p: Page[a]): Int32   = let Page.Page(r) = p; r#perPage
    pub def totalItems(p: Page[a]): Int64 = let Page.Page(r) = p; r#totalItems
    pub def totalPages(p: Page[a]): Int32 = let Page.Page(r) = p; r#totalPages
    pub def hasPrev(p: Page[a]): Bool    = page(p) > 1
    pub def hasNext(p: Page[a]): Bool    = page(p) < totalPages(p)

    pub def map(f: a -> b \ ef, p: Page[a]): Page[b] \ ef =
        let Page.Page(r) = p;
        Page.Page({ items = List.map(f, r#items) | r })

    ///
    /// Encodes a `Page[a]` into a standard JSON envelope:
    /// `{"items": [...], "page": 1, "perPage": 20, "totalItems": 42, "totalPages": 3, "hasPrev": false, "hasNext": true}`.
    ///
    pub def toJson(encodeItem: a -> Json \ ef, p: Page[a]): Json \ ef =
        Json.obj(
            ("items",      Json.arr(List.map(encodeItem, items(p)))) ::
            ("page",       Json.int(page(p))) ::
            ("perPage",    Json.int(perPage(p))) ::
            ("totalItems", Json.int64(totalItems(p))) ::
            ("totalPages", Json.int(totalPages(p))) ::
            ("hasPrev",    Json.bool(hasPrev(p))) ::
            ("hasNext",    Json.bool(hasNext(p))) ::
            Nil
        )

}
