pub mod Features.Admin.AdminFeature {
    use Features.Admin.AdminViews
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use Features.Catalog.{NewProduct, ProductImage}
    use Features.Catalog.CatalogStore
    use Features.Checkout.OrderStore
    use weft::Weft.Auth
    use weft::Weft.CsrfConfig
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.IntoResponse
    use weft::Weft.Middleware
    use weft::Weft.MultipartForm
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Session
    use weft::Weft.UploadedFile
    use weft::Weft.Validate
    use weft::Weft.ValidationErrors

    // --- Slice Route Builder (mounted under `/admin`) ---

    pub def routes(csrfCfg: CsrfConfig): Router[{Req, HttpError, Session, Random, CatalogStore, OrderStore, CartStore, UserStore}] = {
        let base: Router[{Req, HttpError, Auth, Session, Random, CatalogStore, OrderStore, CartStore}] =
            Router.empty()
                |> Router.get("/", dashboard)
                |> Router.post("/products", createProduct)
                |> Router.post("/products/:id/stock", updateStock)
                |> Router.post("/orders/:id/status", updateOrderStatus);
        let withRole: Router[{Req, HttpError, Auth, Session, Random, CatalogStore, OrderStore, CartStore}] =
            base |> Router.withMiddleware(Middleware.requireRole("admin"));
        let withCsrf: Router[{Req, HttpError, Auth, Session, Random, CatalogStore, OrderStore, CartStore}] =
            withRole |> Router.withMiddleware(Middleware.csrf(csrfCfg));
        withCsrf |> Router.withMiddleware(Middleware.sessionAuthOrRedirect("/login", Features.Auth.loadPrincipalByIdStr))
    }

    // --- Handlers (Zero SQL / Zero `Db` / Zero `JobQueue` coupling) ---

    pub def dashboard(): HtmlDoc \ {Auth, Session, Random, CatalogStore, OrderStore, CartStore} = {
        let prods = CatalogStore.listAllProducts();
        let orders = OrderStore.listAllOrders();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AdminViews.adminPage(Some(Auth.current()), Shared.CartContext.authCount(), prods, orders, flashOk, flashErr)
    }

    pub def createProduct(): Response \ {Req, HttpError, Session, CatalogStore} = {
        let mp = Req.multipartForm();
        let res = Validate.toResult(() -> {
            let sku = Validate.requireNonEmpty("sku", MultipartForm.field("sku", mp))
                |> String.toUpperCase;
            let name = Validate.requireNonEmpty("name", MultipartForm.field("name", mp))
                |> Validate.minLength("name", 2);
            let cat = Validate.requireNonEmpty("category", MultipartForm.field("category", mp))
                |> Validate.oneOf("category", List.map(fst, Shared.Money.categories()));
            let desc = Validate.requireNonEmpty("description", MultipartForm.field("description", mp));
            let price = Validate.requireInt64("price_cents", MultipartForm.field("price_cents", mp))
                |> Validate.positiveInt64("price_cents");
            let stock = Validate.requireInt("stock", MultipartForm.field("stock", mp))
                |> Validate.minInt("stock", 0);
            (sku, name, cat, desc, price, stock)
        });
        match res {
            case Err(errs) =>
                Session.putFlash("err", "Product validation failed: ${ValidationErrors.summary(errs)}");
                Response.seeOther("/admin")
            case Ok((sku, name, cat, desc, price, stock)) =>
                let imgOpt: Option[ProductImage] = MultipartForm.file("image", mp)
                    |> Option.filter(f -> UploadedFile.size(f) > 0)
                    |> Option.map(f -> {
                        mime = UploadedFile.contentType(f),
                        data = UploadedFile.data(f)
                    });
                let spec: NewProduct = {
                    sku         = sku,
                    slug        = Shared.Money.slugify(name),
                    name        = name,
                    category    = cat,
                    description = desc,
                    priceCents  = price,
                    stock       = stock,
                    image       = imgOpt
                };
                let newId = CatalogStore.createProduct(spec);
                Session.putFlash("ok", "Created product #${newId} (${name}).");
                Response.seeOther("/admin")
        }
    }

    pub def updateStock(): Response \ {Req, HttpError, Session, Random, CatalogStore} = {
        let pid = Req.requireInt64Param("id");
        let newStock = Req.requireIntFormField("stock");
        let _ = CatalogStore.updateStock(pid, newStock);
        let prod = CatalogStore.findById(pid)
            |> HttpError.orNotFound("Product #${pid} not found");
        if (Shared.CartContext.isHtmx())
            IntoResponse.intoResponse(AdminViews.stockFormPartial(prod))
        else {
            Session.putFlash("ok", "Updated stock for ${prod#name} to ${prod#stock}.");
            Response.seeOther("/admin")
        }
    }

    pub def updateOrderStatus(): Response \ {Req, HttpError, Session, Random, OrderStore} = {
        let orderId = Req.requireInt64Param("id");
        let newStatus = Req.requireNonEmptyFormField("status");
        if (not List.memberOf(newStatus, Shared.Money.orderStatuses()))
            HttpError.badRequest("Invalid order status '${newStatus}'")
        else {
            let updated = OrderStore.updateOrderStatus(orderId, newStatus)
                |> HttpError.orNotFound("Order #${orderId} not found");
            if (Shared.CartContext.isHtmx())
                IntoResponse.intoResponse(AdminViews.orderRowPartial(updated))
            else {
                Session.putFlash("ok", "Updated order ${updated#orderNumber} to '${updated#status}'.");
                Response.seeOther("/admin")
            }
        }
    }

}
