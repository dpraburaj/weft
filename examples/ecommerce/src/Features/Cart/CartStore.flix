pub mod Features.Cart.CartStore {
    use Features.Cart.CartStore
    use Shared.Domain.{CartLine, PromoCode}
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.Row
    use weft::Weft.SqlValue

    ///
    /// High-level persistence store for shopping carts and promo codes.
    ///
    pub eff CartStore {
        def countItems(ownerKey: String): Int32
        def getLines(ownerKey: String): List[CartLine]
        def addItem(ownerKey: String, productId: Int64, addQty: Int32): Unit
        def setQuantity(ownerKey: String, productId: Int64, qty: Int32): Unit
        def removeItem(ownerKey: String, productId: Int64): Unit
        def clear(ownerKey: String): Unit
        def mergeGuestIntoUser(guestOwner: String, userOwner: String): Unit
        def findPromo(code: String): Option[PromoCode]
    }

    ///
    /// SQLite/SQL implementation of `CartStore` backed by Weft's `Db` effect.
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - CartStore) + {Db, DbError} =
        run {
            f()
        } with handler CartStore {
            def countItems(owner, k)             = k(dbCountItems(owner))
            def getLines(owner, k)               = k(dbGetLines(owner))
            def addItem(owner, pid, qty, k)      = { dbAddItem(owner, pid, qty); k() }
            def setQuantity(owner, pid, qty, k)  = { dbSetQuantity(owner, pid, qty); k() }
            def removeItem(owner, pid, k)        = { dbRemoveItem(owner, pid); k() }
            def clear(owner, k)                  = { dbClear(owner); k() }
            def mergeGuestIntoUser(g, u, k)      = { dbMergeGuestIntoUser(g, u); k() }
            def findPromo(code, k)               = k(dbFindPromo(code))
        }

    ///
    /// Pure empty handler for unit-testing read-only storefront handlers with zero `Db` or `IO`.
    ///
    pub def runPureEmpty(f: Unit -> a \ ef): a \ (ef - CartStore) =
        run {
            f()
        } with handler CartStore {
            def countItems(_, k)          = k(0)
            def getLines(_, k)            = k(Nil)
            def addItem(_, _, _, k)       = k()
            def setQuantity(_, _, _, k)   = k()
            def removeItem(_, _, k)       = k()
            def clear(_, k)               = k()
            def mergeGuestIntoUser(_, _, k) = k()
            def findPromo(_, k)           = k(None)
        }

    // --- SQLite Repository Queries (Private to CartStore) ---

    def dbCountItems(ownerKey: String): Int32 \ {Db, DbError} =
        Db.queryOneMap(
            "SELECT COALESCE(SUM(quantity), 0) AS total FROM cart_items WHERE owner_key = ?",
            SqlValue.text(ownerKey) :: Nil,
            Row.requireInt("total")
        ) |> Option.getWithDefault(0)

    def dbGetLines(ownerKey: String): List[CartLine] \ {Db, DbError} =
        Db.queryMap(
            "SELECT c.product_id, p.sku, p.slug, p.name, p.price_cents, c.quantity, p.stock " +
            "FROM cart_items c " +
            "JOIN products p ON p.id = c.product_id " +
            "WHERE c.owner_key = ? " +
            "ORDER BY c.updated_at ASC, c.product_id ASC",
            SqlValue.text(ownerKey) :: Nil,
            r -> {
                let unit = Row.requireInt64("price_cents", r);
                let qty = Row.requireInt("quantity", r);
                {
                    productId      = Row.requireInt64("product_id", r),
                    sku            = Row.requireString("sku", r),
                    slug           = Row.requireString("slug", r),
                    name           = Row.requireString("name", r),
                    unitCents      = unit,
                    quantity       = qty,
                    stock          = Row.requireInt("stock", r),
                    lineTotalCents = unit * Int32.toInt64(qty)
                }
            }
        )

    def dbAddItem(ownerKey: String, productId: Int64, addQty: Int32): Unit \ {Db, DbError} = {
        let _ = Db.execute(
            "INSERT INTO cart_items (owner_key, product_id, quantity) VALUES (?, ?, ?) " +
            "ON CONFLICT(owner_key, product_id) DO UPDATE SET " +
            "  quantity = quantity + excluded.quantity, updated_at = CURRENT_TIMESTAMP",
            SqlValue.text(ownerKey) :: SqlValue.int64(productId) :: SqlValue.int(addQty) :: Nil
        );
        ()
    }

    def dbSetQuantity(ownerKey: String, productId: Int64, qty: Int32): Unit \ {Db, DbError} =
        if (qty <= 0)
            dbRemoveItem(ownerKey, productId)
        else {
            let _ = Db.execute(
                "UPDATE cart_items SET quantity = ?, updated_at = CURRENT_TIMESTAMP " +
                "WHERE owner_key = ? AND product_id = ?",
                SqlValue.int(qty) :: SqlValue.text(ownerKey) :: SqlValue.int64(productId) :: Nil
            );
            ()
        }

    def dbRemoveItem(ownerKey: String, productId: Int64): Unit \ {Db, DbError} = {
        let _ = Db.execute(
            "DELETE FROM cart_items WHERE owner_key = ? AND product_id = ?",
            SqlValue.text(ownerKey) :: SqlValue.int64(productId) :: Nil
        );
        ()
    }

    def dbClear(ownerKey: String): Unit \ {Db, DbError} = {
        let _ = Db.execute(
            "DELETE FROM cart_items WHERE owner_key = ?",
            SqlValue.text(ownerKey) :: Nil
        );
        ()
    }

    def dbMergeGuestIntoUser(guestOwner: String, userOwner: String): Unit \ {Db, DbError} =
        if (guestOwner == userOwner) ()
        else
            Db.transaction(() -> {
                let guestLines = dbGetLines(guestOwner);
                List.forEach(line ->
                    dbAddItem(userOwner, line#productId, line#quantity)
                , guestLines);
                dbClear(guestOwner)
            })

    def dbFindPromo(code: String): Option[PromoCode] \ {Db, DbError} =
        Db.queryOneMap(
            "SELECT code, percent_off, free_ship, description FROM promo_codes WHERE UPPER(code) = UPPER(?)",
            SqlValue.text(String.trim(code)) :: Nil,
            r -> {
                code        = Row.requireString("code", r),
                percentOff  = Row.requireInt("percent_off", r),
                freeShip    = Row.requireBool("free_ship", r),
                description = Row.requireString("description", r)
            }
        )

}
