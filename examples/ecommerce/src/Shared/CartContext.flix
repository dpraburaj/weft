pub mod Shared.CartContext {
    use Features.Cart.CartStore
    use weft::Weft.Auth
    use weft::Weft.OptionalAuth
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Session

    pub def isHtmx(): Bool \ Req =
        Req.header("HX-Request") == Some("true")

    pub def authOwner(): String \ Auth =
        "user:${Auth.userId()}"

    pub def existingOwner(): Option[String] \ {OptionalAuth, Session} =
        match OptionalAuth.userId() {
            case Some(uid) => Some("user:${uid}")
            case None      => Session.get("guest_cart_key")
        }

    pub def ensureOwner(): String \ {OptionalAuth, Session, Random} =
        match OptionalAuth.userId() {
            case Some(uid) => "user:${uid}"
            case None =>
                match Session.get("guest_cart_key") {
                    case Some(k) => k
                    case None =>
                        let fresh = "guest:" + Random.tokenHex(8);
                        Session.put("guest_cart_key", fresh);
                        fresh
                }
        }

    pub def countForOwner(ownerKey: String): Int32 \ CartStore =
        CartStore.countItems(ownerKey)

    pub def currentCount(): Int32 \ {OptionalAuth, Session, CartStore} =
        match existingOwner() {
            case Some(owner) => countForOwner(owner)
            case None        => 0
        }

    pub def authCount(): Int32 \ {Auth, CartStore} =
        countForOwner(authOwner())

}
