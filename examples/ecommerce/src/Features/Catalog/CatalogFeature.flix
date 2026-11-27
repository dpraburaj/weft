pub mod Features.Catalog.CatalogFeature {
    use Features.Cart.CartStore
    use Features.Catalog
    use Features.Catalog.CatalogFilter
    use Features.Catalog.CatalogStore
    use Features.Catalog.CatalogViews
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.OptionalAuth
    use weft::Weft.Page
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Session

    // --- Slice Route Builders ---

    pub def publicReadRoutes(): Router[{Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore}] =
        Router.empty()
            |> Router.get("/", homePage)
            |> Router.get("/products/grid", productGridPartial)
            |> Router.get("/products/:slug", productDetail)

    pub def mediaRoutes(): Router[{Req, HttpError, CatalogStore}] =
        Router.empty()
            |> Router.get("/media/products/:id", productImage)

    pub def apiRoutes(): Router[{Req, CatalogStore}] =
        Router.empty()
            |> Router.get("/products", apiListProducts)
            |> Router.get("/products/:slug", apiGetProduct)
            |> Router.withMiddleware(Middleware.routeErrorJson)

    // --- Handlers (Zero SQL / Zero `Db` coupling) ---

    pub def homePage(): HtmlDoc \ {Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore} = {
        let filter = parseCatalogFilter(6);
        let pg = CatalogStore.listProducts(filter);
        let cartCount = Shared.CartContext.currentCount();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        CatalogViews.catalogPage(OptionalAuth.current(), cartCount, filter, pg, flashOk, flashErr)
    }

    pub def productGridPartial(): HtmlDoc \ {Req, HttpError, Session, Random, CatalogStore} = {
        let filter = parseCatalogFilter(6);
        let pg = CatalogStore.listProducts(filter);
        CatalogViews.productGridPartial(filter, pg)
    }

    pub def productDetail(): HtmlDoc \ {Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore} = {
        let slug = Req.requireParam("slug");
        let prod = CatalogStore.findBySlug(slug)
            |> HttpError.orNotFound("Product '${slug}' not found");
        let cartCount = Shared.CartContext.currentCount();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        CatalogViews.productDetailPage(OptionalAuth.current(), cartCount, prod, flashOk, flashErr)
    }

    pub def productImage(): Response \ {Req, HttpError, CatalogStore} = {
        let pid = Req.requireInt64Param("id");
        let img = CatalogStore.findImage(pid)
            |> HttpError.orNotFound("Image for product #${pid} not found");
        Response.bytes(img#mime, img#data)
            |> Response.withHeader("Cache-Control", "public, max-age=3600")
    }

    pub def apiListProducts(): Json \ {Req, HttpError, CatalogStore} = {
        let perPage = Req.optionalIntQuery("per_page") |> Option.getWithDefault(12);
        let filter = parseCatalogFilter(perPage);
        let pg = CatalogStore.listProducts(filter);
        Page.toJson(Catalog.productToJson, pg)
    }

    pub def apiGetProduct(): Json \ {Req, HttpError, CatalogStore} = {
        let slug = Req.requireParam("slug");
        let prod = CatalogStore.findBySlug(slug)
            |> HttpError.orNotFound("Product '${slug}' not found");
        Catalog.productToJson(prod)
    }

    def parseCatalogFilter(defaultPerPage: Int32): CatalogFilter \ {Req, HttpError} = {
        let q = Req.queryParam("q") |> Option.filter(s -> not String.isEmpty(String.trim(s)));
        let cat = Req.queryParam("category") |> Option.filter(s -> not String.isEmpty(String.trim(s)));
        let sort = Req.queryParam("sort") |> Option.getWithDefault("featured");
        let pg = Req.optionalIntQuery("page") |> Option.getWithDefault(1);
        {
            search   = q,
            category = cat,
            sort     = sort,
            page     = Page.normalizePage(pg),
            perPage  = Page.clampPerPage(24, defaultPerPage)
        }
    }

}
