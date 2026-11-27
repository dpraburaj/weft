pub mod Features.Cart.CartFeature {
    use Features.Cart
    use Features.Cart.CartStore
    use Features.Cart.CartViews
    use Features.Catalog.CatalogStore
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.IntoResponse
    use weft::Weft.OptionalAuth
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Session

    // --- Slice Route Builders ---

    pub def readRoutes(): Router[{Req, HttpError, OptionalAuth, Session, Random, CartStore}] =
        Router.empty()
            |> Router.get("/cart", viewCart)

    pub def mutationRoutes(): Router[{Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore}] =
        Router.empty()
            |> Router.post("/cart/items", addItem)
            |> Router.post("/cart/items/:id/qty", updateItemQty)
            |> Router.delete("/cart/items/:id", removeItem)
            |> Router.post("/cart/items/:id/remove", removeItem)
            |> Router.post("/cart/promo", applyPromo)

    // --- Handlers (Zero SQL / Zero `Db` coupling) ---

    pub def viewCart(): HtmlDoc \ {OptionalAuth, Session, Random, CartStore} = {
        let summary = Cart.currentSummary();
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        CartViews.cartPage(OptionalAuth.current(), summary, flashOk, flashErr)
    }

    pub def addItem(): Response \ {Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore} = {
        let pid = Req.requireInt64FormField("product_id");
        let qty = Req.optionalIntFormField("quantity") |> Option.getWithDefault(1) |> Int32.max(1);
        let prod = CatalogStore.findById(pid)
            |> HttpError.orNotFound("Product #${pid} not found");
        if (prod#stock < qty)
            HttpError.conflict("Only ${prod#stock} units of '${prod#name}' are in stock")
        else {
            let owner = Shared.CartContext.ensureOwner();
            CartStore.addItem(owner, pid, qty);
            let totalCount = Shared.CartContext.countForOwner(owner);
            if (Shared.CartContext.isHtmx())
                IntoResponse.intoResponse(Shared.Layout.cartBadgePartial(totalCount))
            else {
                Session.putFlash("ok", "Added ${prod#name} to your cart.");
                Response.seeOther("/cart")
            }
        }
    }

    pub def updateItemQty(): Response \ {Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore} = {
        let pid = Req.requireInt64Param("id");
        let qty = Req.requireIntFormField("quantity");
        let owner = Shared.CartContext.ensureOwner();
        let (okOpt, errOpt) =
            if (qty <= 0) {
                CartStore.removeItem(owner, pid);
                (Some("Item removed from cart."), None)
            } else {
                match CatalogStore.findById(pid) {
                    case None => (None, Some("Product not found."))
                    case Some(prod) =>
                        if (qty > prod#stock)
                            (None, Some("Only ${prod#stock} units of '${prod#name}' available."))
                        else {
                            CartStore.setQuantity(owner, pid, qty);
                            (Some("Updated quantity."), None)
                        }
                }
            };
        if (Shared.CartContext.isHtmx())
            IntoResponse.intoResponse(CartViews.cartPanelPartial(Cart.summaryForOwner(owner), okOpt, errOpt))
        else {
            Option.forEach(m -> Session.putFlash("ok", m), okOpt);
            Option.forEach(m -> Session.putFlash("err", m), errOpt);
            Response.seeOther("/cart")
        }
    }

    pub def removeItem(): Response \ {Req, HttpError, OptionalAuth, Session, Random, CartStore} = {
        let pid = Req.requireInt64Param("id");
        let owner = Shared.CartContext.ensureOwner();
        CartStore.removeItem(owner, pid);
        if (Shared.CartContext.isHtmx())
            IntoResponse.intoResponse(CartViews.cartPanelPartial(Cart.summaryForOwner(owner), Some("Item removed."), None))
        else {
            Session.putFlash("ok", "Item removed.");
            Response.seeOther("/cart")
        }
    }

    pub def applyPromo(): Response \ {Req, HttpError, OptionalAuth, Session, Random, CartStore} = {
        let rawCode = Req.optionalFormField("code") |> Option.getWithDefault("") |> String.trim;
        let owner = Shared.CartContext.ensureOwner();
        let (okOpt, errOpt) =
            if (String.isEmpty(rawCode)) {
                Session.remove("promo_code");
                (Some("Promo code cleared."), None)
            } else {
                match CartStore.findPromo(rawCode) {
                    case Some(p) =>
                        Session.put("promo_code", p#code);
                        (Some("Promo '${p#code}' applied: ${p#description}"), None)
                    case None =>
                        (None, Some("Unknown promo code '${rawCode}'. Try WELCOME10 or FREESHIP."))
                }
            };
        if (Shared.CartContext.isHtmx())
            IntoResponse.intoResponse(CartViews.cartPanelPartial(Cart.summaryForOwner(owner), okOpt, errOpt))
        else {
            Option.forEach(m -> Session.putFlash("ok", m), okOpt);
            Option.forEach(m -> Session.putFlash("err", m), errOpt);
            Response.seeOther("/cart")
        }
    }

}
