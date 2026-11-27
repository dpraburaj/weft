pub mod Features.Checkout {

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
