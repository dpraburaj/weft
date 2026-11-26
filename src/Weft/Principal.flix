pub mod Weft.Principal {
    use Weft.Principal

    ///
    /// Authenticated identity provided by the `Auth` effect.
    ///
    pub enum Principal {
        case Principal({
            id    = String,
            name  = String,
            roles = List[String]
        })
    }

    instance Eq[Principal] {
        pub def eq(a: Principal, b: Principal): Bool =
            let Principal.Principal(x) = a;
            let Principal.Principal(y) = b;
            x#id == y#id and x#name == y#name and x#roles == y#roles
    }

    pub def make(id: String, name: String, roles: List[String]): Principal =
        Principal.Principal({ id = id, name = name, roles = roles })

    pub def id(p: Principal): String          = let Principal.Principal(r) = p; r#id
    pub def name(p: Principal): String        = let Principal.Principal(r) = p; r#name
    pub def roles(p: Principal): List[String] = let Principal.Principal(r) = p; r#roles
    pub def hasRole(role: String, p: Principal): Bool = List.memberOf(role, roles(p))

}
