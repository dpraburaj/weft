pub mod Features.Admin.AdminFeature {
    use Features.Admin.AdminViews
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use Features.Catalog.CatalogStore
    use Features.Checkout.OrderStore
    use Shared.Domain.{NewProduct, ProductImage}
    use weft::Weft.Auth
    use weft::Weft.Cache
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
    //
    // Dedicated merchant workspace pages:
    // - `GET  /admin`                    Overview dashboard (KPIs, pending fulfillment, low stock alerts)
    // - `GET  /admin/orders`             Orders & fulfillment queue (`?status=paid|roasted|shipped|delivered`)
    // - `GET  /admin/products`           Products & inventory manager (`?category=...&stock=low|out`)
    // - `GET  /admin/products/new`       Add Product 2-column composer
    // - `POST /admin/products`           Create product (multipart image upload)
    // - `POST /admin/products/:id/stock` Inline HTMX stock adjustment
    // - `POST /admin/orders/:id/status`  Inline HTMX fulfillment stage update

    pub def routes(csrfCfg: CsrfConfig): Router[{Req, HttpError, Session, Random, Cache, CatalogStore, OrderStore, CartStore, UserStore}] = {
        let base: Router[{Req, HttpError, Auth, Session, Random, Cache, CatalogStore, OrderStore, CartStore}] =
            Router.empty()
                |> Router.get("/", overviewPage)
                |> Router.get("/orders", ordersPage)
                |> Router.get("/products", productsPage)
                |> Router.get("/products/new", newProductPage)
                |> Router.post("/products", createProduct)
                |> Router.post("/products/:id/stock", updateStock)
                |> Router.post("/orders/:id/status", updateOrderStatus);
        let withRole: Router[{Req, HttpError, Auth, Session, Random, Cache, CatalogStore, OrderStore, CartStore}] =
            base |> Router.withMiddleware(Middleware.requireRole("admin"));
        let withCsrf: Router[{Req, HttpError, Auth, Session, Random, Cache, CatalogStore, OrderStore, CartStore}] =
            withRole |> Router.withMiddleware(Middleware.csrf(csrfCfg));
        withCsrf |> Router.withMiddleware(Middleware.sessionAuthOrRedirect("/login", Features.Auth.loadPrincipalByIdStr))
    }

    // --- Page Handlers (Zero SQL / Zero `Db` / Zero `JobQueue` coupling) ---

    pub def overviewPage(): HtmlDoc \ {Auth, Session, Random, CatalogStore, OrderStore} = {
        let prods = CatalogStore.listAllProducts();
        let orders = OrderStore.listAllOrders();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AdminViews.overviewPage(Some(Auth.current()), prods, orders, flashOk, flashErr)
    }

    pub def ordersPage(): HtmlDoc \ {Req, Auth, Session, Random, CatalogStore, OrderStore} = {
        let prods = CatalogStore.listAllProducts();
        let orders = OrderStore.listAllOrders();
        let statusFilter = Req.queryParam("status") |> Option.filter(s -> not String.isEmpty(String.trim(s)));
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AdminViews.ordersPage(Some(Auth.current()), prods, orders, statusFilter, flashOk, flashErr)
    }

    pub def productsPage(): HtmlDoc \ {Req, Auth, Session, Random, CatalogStore, OrderStore} = {
        let prods = CatalogStore.listAllProducts();
        let orders = OrderStore.listAllOrders();
        let catFilter = Req.queryParam("category") |> Option.filter(s -> not String.isEmpty(String.trim(s)));
        let stockFilter = Req.queryParam("stock") |> Option.filter(s -> not String.isEmpty(String.trim(s)));
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AdminViews.productsPage(Some(Auth.current()), prods, orders, catFilter, stockFilter, flashOk, flashErr)
    }

    pub def newProductPage(): HtmlDoc \ {Auth, Session, Random, CatalogStore, OrderStore} = {
        let prods = CatalogStore.listAllProducts();
        let orders = OrderStore.listAllOrders();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AdminViews.newProductPage(Some(Auth.current()), prods, orders, flashOk, flashErr)
    }

    // --- Mutation Handlers ---

    pub def createProduct(): Response \ {Req, HttpError, Session, Cache, CatalogStore} = {
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
                Response.seeOther("/admin/products/new")
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
                Cache.clear();
                Session.putFlash("ok", "Created product #${newId} (${name}).");
                Response.seeOther("/admin/products")
        }
    }

    pub def updateStock(): Response \ {Req, HttpError, Session, Random, Cache, CatalogStore} = {
        let pid = Req.requireInt64Param("id");
        let newStock = Req.requireIntFormField("stock");
        let _ = CatalogStore.updateStock(pid, newStock);
        Cache.clear();
        let prod = CatalogStore.findById(pid)
            |> HttpError.orNotFound("Product #${pid} not found");
        if (Shared.CartContext.isHtmx())
            IntoResponse.intoResponse(AdminViews.stockFormPartial(prod))
        else {
            Session.putFlash("ok", "Updated stock for ${prod#name} to ${prod#stock}.");
            Response.seeOther("/admin/products")
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
                Response.seeOther("/admin/orders")
            }
        }
    }

}
