pub mod Features.Catalog {
    use weft::Weft.Json

    pub type alias Product = {
        id          = Int64,
        sku         = String,
        slug        = String,
        name        = String,
        category    = String,
        description = String,
        priceCents  = Int64,
        stock       = Int32,
        hasImage    = Bool
    }

    pub type alias ProductImage = {
        mime = String,
        data = Vector[Int8]
    }

    pub type alias CatalogFilter = {
        search   = Option[String],
        category = Option[String],
        sort     = String,
        page     = Int32,
        perPage  = Int32
    }

    pub type alias NewProduct = {
        sku         = String,
        slug        = String,
        name        = String,
        category    = String,
        description = String,
        priceCents  = Int64,
        stock       = Int32,
        image       = Option[ProductImage]
    }

    pub def productToJson(p: Product): Json =
        Json.obj(
            ("id",          Json.int64(p#id)) ::
            ("sku",         Json.str(p#sku)) ::
            ("slug",        Json.str(p#slug)) ::
            ("name",        Json.str(p#name)) ::
            ("category",    Json.str(p#category)) ::
            ("description", Json.str(p#description)) ::
            ("priceCents",  Json.int64(p#priceCents)) ::
            ("price",       Json.str(Shared.Money.formatCents(p#priceCents))) ::
            ("stock",       Json.int(p#stock)) ::
            ("imageUrl",    if (p#hasImage) Json.str("/media/products/${p#id}") else Json.nullValue()) ::
            Nil
        )

}
