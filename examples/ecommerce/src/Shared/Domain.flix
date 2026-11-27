pub mod Shared.Domain {
    use weft::Weft.Json

    // =========================================================================
    // Catalog Domain Types
    // =========================================================================

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

    // =========================================================================
    // Cart & Pricing Domain Types
    // =========================================================================

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
    pub def summarizeCart(lines: List[CartLine], promoOpt: Option[PromoCode]): CartSummary = {
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

    // =========================================================================
    // Auth / Identity Domain Types
    // =========================================================================

    pub type alias User = {
        id           = Int64,
        email        = String,
        name         = String,
        passwordHash = String,
        role         = String
    }

    // =========================================================================
    // Checkout & Order Domain Types
    // =========================================================================

    pub type alias Order = {
        id            = Int64,
        orderNumber   = String,
        userId        = Int64,
        customerEmail = String,
        shippingName  = String,
        address       = String,
        city          = String,
        postalCode    = String,
        country       = String,
        promoCode     = Option[String],
        subtotalCents = Int64,
        discountCents = Int64,
        shippingCents = Int64,
        totalCents    = Int64,
        status        = String,
        createdAt     = String
    }

    pub type alias OrderItem = {
        id             = Int64,
        orderId        = Int64,
        productId      = Int64,
        sku            = String,
        productName    = String,
        unitCents      = Int64,
        quantity       = Int32,
        lineTotalCents = Int64
    }

    pub type alias CheckoutInput = {
        shippingName = String,
        address      = String,
        city         = String,
        postalCode   = String,
        country      = String
    }

    ///
    /// Typed domain failure returned by `OrderStore.placeOrderAtomic` (zero HTTP coupling).
    ///
    pub enum PlaceOrderError with Eq {
        case EmptyCart
        case InsufficientStock(String, Int32)
        case OrderReloadFailed(Int64)
    }

}
