pub mod Features.Cart {
    use Features.Cart.CartStore
    use weft::Weft.OptionalAuth
    use weft::Weft.Session

    pub type alias CartLine = {
        productId      = Int64,
        sku            = String,
        slug           = String,
        name           = String,
        unitCents      = Int64,
        quantity       = Int32,
        stock          = Int32,
        lineTotalCents = Int64
    }

    pub type alias PromoCode = {
        code        = String,
        percentOff  = Int32,
        freeShip    = Bool,
        description = String
    }

    pub type alias CartSummary = {
        lines         = List[CartLine],
        itemCount     = Int32,
        subtotalCents = Int64,
        discountCents = Int64,
        shippingCents = Int64,
        totalCents    = Int64,
        promo         = Option[PromoCode]
    }

    ///
    /// Pure pricing logic: applies promo percentage discount & free shipping over $75 (or `FREESHIP`).
    ///
    pub def summarize(lines: List[CartLine], promoOpt: Option[PromoCode]): CartSummary = {
        let itemCount = List.foldLeft((acc, l) -> acc + l#quantity, 0, lines);
        let subtotal = List.foldLeft((acc, l) -> acc + l#lineTotalCents, 0i64, lines);
        let discount = match promoOpt {
            case Some(p) if p#percentOff > 0 =>
                (subtotal * Int32.toInt64(p#percentOff)) / 100i64
            case _ => 0i64
        };
        let discounted = Int64.max(0i64, subtotal - discount);
        let hasFreeShipPromo = match promoOpt {
            case Some(p) => p#freeShip
            case None    => false
        };
        let shipping =
            if (List.isEmpty(lines) or hasFreeShipPromo or discounted >= 7500i64) 0i64
            else 800i64;
        {
            lines         = lines,
            itemCount     = itemCount,
            subtotalCents = subtotal,
            discountCents = discount,
            shippingCents = shipping,
            totalCents    = discounted + shipping,
            promo         = promoOpt
        }
    }

    pub def activePromo(): Option[PromoCode] \ {Session, CartStore} =
        match Session.get("promo_code") {
            case None    => None
            case Some(c) => CartStore.findPromo(c)
        }

    pub def summaryForOwner(ownerKey: String): CartSummary \ {Session, CartStore} =
        summarize(CartStore.getLines(ownerKey), activePromo())

    pub def currentSummary(): CartSummary \ {OptionalAuth, Session, CartStore} =
        match Shared.CartContext.existingOwner() {
            case None        => summarize(Nil, activePromo())
            case Some(owner) => summaryForOwner(owner)
        }

}
