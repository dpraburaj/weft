pub mod Features.Auth {
    use Features.Auth.UserStore
    use weft::Weft.Principal

    ///
    /// Session principal loader used by Weft auth middlewares (`optionalSessionAuth`, `sessionAuthOrRedirect`).
    /// Depends only on the high-level `UserStore` effect (zero raw SQL or `Db` coupling).
    ///
    pub def loadPrincipalByIdStr(uidStr: String): Option[Principal] \ UserStore =
        match Int64.fromString(uidStr) {
            case None      => None
            case Some(uid) =>
                UserStore.findById(uid) |> Option.map(u -> {
                    let roles = if (u#role == "admin") "admin" :: "customer" :: Nil else "customer" :: Nil;
                    Principal.make("${u#id}", u#name, roles)
                })
        }

}
