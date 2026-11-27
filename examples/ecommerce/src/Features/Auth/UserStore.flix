pub mod Features.Auth.UserStore {
    use Features.Auth.UserStore
    use Shared.Domain.User
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.Row
    use weft::Weft.SqlValue

    ///
    /// High-level persistence store for customer and admin accounts.
    ///
    pub eff UserStore {
        def findByEmail(email: String): Option[User]
        def findById(uid: Int64): Option[User]
        def createUser(email: String, name: String, passwordHash: String): Int64
    }

    ///
    /// SQLite/SQL implementation of `UserStore` backed by Weft's `Db` effect.
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - UserStore) + {Db, DbError} =
        run {
            f()
        } with handler UserStore {
            def findByEmail(email, k)       = k(dbFindByEmail(email))
            def findById(uid, k)            = k(dbFindById(uid))
            def createUser(e, n, hash, k)   = k(dbCreateUser(e, n, hash))
        }

    // --- SQLite Repository Queries (Private to UserStore) ---

    def decodeUser(r: Row): User \ DbError = {
        id           = Row.requireInt64("id", r),
        email        = Row.requireString("email", r),
        name         = Row.requireString("name", r),
        passwordHash = Row.requireString("password_hash", r),
        role         = Row.requireString("role", r)
    }

    def dbFindByEmail(email: String): Option[User] \ {Db, DbError} =
        Db.queryOneMap(
            "SELECT id, email, name, password_hash, role FROM users WHERE LOWER(email) = LOWER(?)",
            SqlValue.text(String.trim(email)) :: Nil,
            decodeUser
        )

    def dbFindById(uid: Int64): Option[User] \ {Db, DbError} =
        Db.queryOneMap(
            "SELECT id, email, name, password_hash, role FROM users WHERE id = ?",
            SqlValue.int64(uid) :: Nil,
            decodeUser
        )

    def dbCreateUser(email: String, name: String, passwordHash: String): Int64 \ {Db, DbError} =
        Db.insertAndGetId(
            "INSERT INTO users (email, name, password_hash, role) VALUES (?, ?, ?, 'customer')",
            SqlValue.text(String.toLowerCase(String.trim(email))) ::
            SqlValue.text(String.trim(name)) ::
            SqlValue.text(passwordHash) ::
            Nil
        )

}
