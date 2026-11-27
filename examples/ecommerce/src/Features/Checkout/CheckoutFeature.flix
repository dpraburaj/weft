pub mod Features.Checkout.CheckoutFeature {
    use Features.Auth.UserStore
    use Features.Cart
    use Features.Cart.CartStore
    use Features.Checkout.{CheckoutInput, PlaceOrderError}
    use Features.Checkout.CheckoutViews
    use Features.Checkout.OrderStore
    use weft::Weft.Auth
    use weft::Weft.CsrfConfig
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.IntoResponse
    use weft::Weft.Middleware
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Session
    use weft::Weft.Status
    use weft::Weft.Validate
    use weft::Weft.ValidationErrors

    // --- Slice Route Builder ---

    pub def routes(csrfCfg: CsrfConfig): Router[{Req, HttpError, Session, Random, OrderStore, CartStore, UserStore}] = {
        let base: Router[{Req, HttpError, Auth, Session, Random, OrderStore, CartStore, UserStore}] =
            Router.empty()
                |> Router.get("/checkout", checkoutPage)
                |> Router.post("/checkout", checkoutPost)
                |> Router.get("/orders", ordersList)
                |> Router.get("/orders/:id", orderDetail);
        let withCsrf: Router[{Req, HttpError, Auth, Session, Random, OrderStore, CartStore, UserStore}] =
            base |> Router.withMiddleware(Middleware.csrf(csrfCfg));
        withCsrf |> Router.withMiddleware(Middleware.sessionAuthOrRedirect("/login", Features.Auth.loadPrincipalByIdStr))
    }

    // --- Handlers (Zero SQL / Zero `Db` / Zero `JobQueue` coupling) ---

    pub def checkoutPage(): Response \ {Auth, Session, Random, CartStore} = {
        let owner = Shared.CartContext.authOwner();
        let summary = Cart.summaryForOwner(owner);
        if (List.isEmpty(summary#lines)) {
            Session.putFlash("err", "Add at least one item to your cart before checking out.");
            Response.seeOther("/cart")
        } else {
            let defaults: CheckoutInput = {
                shippingName = Auth.userName(),
                address      = "",
                city         = "",
                postalCode   = "",
                country      = "United States"
            };
            IntoResponse.intoResponse(
                CheckoutViews.checkoutPage(Some(Auth.current()), summary, defaults, ValidationErrors.empty(), None)
            )
        }
    }

    pub def checkoutPost(): Response \ {Req, HttpError, Auth, Session, Random, OrderStore, CartStore, UserStore} = {
        let form = Req.formParams();
        let owner = Shared.CartContext.authOwner();
        let summary = Cart.summaryForOwner(owner);
        if (List.isEmpty(summary#lines)) {
            Session.putFlash("err", "Your cart is empty.");
            Response.seeOther("/cart")
        } else {
            let (input, errs) = Validate.collect(() -> {
                let sName = Validate.requireNonEmpty("shipping_name", Map.get("shipping_name", form))
                    |> Validate.minLength("shipping_name", 2);
                let addr = Validate.requireNonEmpty("address", Map.get("address", form))
                    |> Validate.minLength("address", 4);
                let city = Validate.requireNonEmpty("city", Map.get("city", form));
                let zip = Validate.requireNonEmpty("postal_code", Map.get("postal_code", form))
                    |> Validate.minLength("postal_code", 3);
                let country = Validate.requireNonEmpty("country", Map.get("country", form));
                { shippingName = sName, address = addr, city = city, postalCode = zip, country = country }
            });

            if (not ValidationErrors.isEmpty(errs)) {
                let rawInput: CheckoutInput = {
                    shippingName = Map.getWithDefault("shipping_name", "", form),
                    address      = Map.getWithDefault("address", "", form),
                    city         = Map.getWithDefault("city", "", form),
                    postalCode   = Map.getWithDefault("postal_code", "", form),
                    country      = Map.getWithDefault("country", "", form)
                };
                let doc = CheckoutViews.checkoutPage(Some(Auth.current()), summary, rawInput, errs, None);
                IntoResponse.intoResponse(doc) |> Response.withStatus(Status.unprocessableEntity())
            } else {
                let uid = Int64.fromString(Auth.userId())
                    |> HttpError.orUnauthorized("Invalid user session");
                let user = UserStore.findById(uid)
                    |> HttpError.orUnauthorized("User account no longer exists");
                let promoOpt = Cart.activePromo();
                match OrderStore.placeOrderAtomic(user, owner, input, promoOpt) {
                    case Err(PlaceOrderError.EmptyCart) =>
                        HttpError.badRequest("Your cart is empty")
                    case Err(PlaceOrderError.InsufficientStock(itemName, requested)) =>
                        HttpError.conflict("Insufficient stock for '${itemName}' (requested ${requested})")
                    case Err(PlaceOrderError.OrderReloadFailed(oid)) =>
                        HttpError.raise(Status.internalServerError(), "Failed to reload created order #${oid}")
                    case Ok(order) =>
                        Session.remove("promo_code");
                        Session.putFlash("ok", "Order ${order#orderNumber} confirmed! A confirmation email is on its way.");
                        Response.seeOther("/orders/${order#id}")
                }
            }
        }
    }

    pub def ordersList(): HtmlDoc \ {HttpError, Auth, Session, Random, OrderStore, CartStore} = {
        let uid = Int64.fromString(Auth.userId())
            |> HttpError.orUnauthorized("Invalid user session");
        let orders = OrderStore.listOrdersForUser(uid);
        CheckoutViews.ordersHistoryPage(Some(Auth.current()), Shared.CartContext.authCount(), orders)
    }

    pub def orderDetail(): HtmlDoc \ {Req, HttpError, Auth, Session, Random, OrderStore, CartStore} = {
        let orderId = Req.requireInt64Param("id");
        let order = OrderStore.findOrderById(orderId)
            |> HttpError.orNotFound("Order #${orderId} not found");
        let isOwner = "${order#userId}" == Auth.userId();
        if (not isOwner and not Auth.hasRole("admin"))
            HttpError.forbidden("You do not have permission to view order #${orderId}")
        else {
            let items = OrderStore.listOrderItems(orderId);
            let flashOk = Session.takeFlash("ok");
            CheckoutViews.orderReceiptPage(Some(Auth.current()), Shared.CartContext.authCount(), order, items, flashOk)
        }
    }

}
