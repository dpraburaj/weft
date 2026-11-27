pub mod Features.Cart {
    use Features.Cart.CartStore
    use Shared.Domain
    use Shared.Domain.{CartSummary, PromoCode}
    use weft::Weft.OptionalAuth
    use weft::Weft.Session

    pub def activePromo(): Option[PromoCode] \ {Session, CartStore} =
        match Session.get("promo_code") {
            case None    => None
            case Some(c) => CartStore.findPromo(c)
        }

    pub def summaryForOwner(ownerKey: String): CartSummary \ {Session, CartStore} =
        Domain.summarizeCart(CartStore.getLines(ownerKey), activePromo())

    pub def currentSummary(): CartSummary \ {OptionalAuth, Session, CartStore} =
        match Shared.CartContext.existingOwner() {
            case None        => Domain.summarizeCart(Nil, activePromo())
            case Some(owner) => summaryForOwner(owner)
        }

}
