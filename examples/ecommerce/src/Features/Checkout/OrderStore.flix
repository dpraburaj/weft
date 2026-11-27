pub mod Features.Checkout.OrderStore {
    use Features.Checkout.OrderStore
    use Shared.Domain
    use Shared.Domain.{CartLine, CheckoutInput, Order, OrderItem, PlaceOrderError, PromoCode, User}
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.JobQueue
    use weft::Weft.Json
    use weft::Weft.Random
    use weft::Weft.Row
    use weft::Weft.SqlValue

    ///
    /// High-level persistence & transactional outbox store for orders.
    /// Encapsulates ACID inventory reservation, order creation, cart clearing,
    /// and outbox job dispatch so handlers never touch SQL or `Db` directly.
    ///
    pub eff OrderStore {
        def placeOrderAtomic(
            user: User,
            ownerKey: String,
            input: CheckoutInput,
            promoOpt: Option[PromoCode]
        ): Result[PlaceOrderError, Order]
        def findOrderById(orderId: Int64): Option[Order]
        def listOrderItems(orderId: Int64): List[OrderItem]
        def listOrdersForUser(userId: Int64): List[Order]
        def listAllOrders(): List[Order]
        def updateOrderStatus(orderId: Int64, newStatus: String): Option[Order]
    }

    ///
    /// SQLite/SQL implementation of `OrderStore` backed by `Db` + transactional `JobQueue`.
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - OrderStore) + {Db, DbError, JobQueue, Random} =
        run {
            f()
        } with handler OrderStore {
            def placeOrderAtomic(user, owner, input, promo, k) =
                k(dbPlaceOrderAtomic(user, owner, input, promo))
            def findOrderById(orderId, k) =
                k(dbFindOrderById(orderId))
            def listOrderItems(orderId, k) =
                k(dbListOrderItems(orderId))
            def listOrdersForUser(userId, k) =
                k(dbListOrdersForUser(userId))
            def listAllOrders(k) =
                k(dbListAllOrders())
            def updateOrderStatus(orderId, newStatus, k) =
                k(dbUpdateOrderStatus(orderId, newStatus))
        }

    // --- SQLite Repository Queries & Transactions (Private to OrderStore) ---

    def orderSelectSql(): String =
        "SELECT o.id, o.order_number, o.user_id, u.email AS customer_email, " +
        "o.shipping_name, o.address, o.city, o.postal_code, o.country, o.promo_code, " +
        "o.subtotal_cents, o.discount_cents, o.shipping_cents, o.total_cents, o.status, o.created_at " +
        "FROM orders o JOIN users u ON u.id = o.user_id"

    def decodeOrder(r: Row): Order \ DbError = {
        id            = Row.requireInt64("id", r),
        orderNumber   = Row.requireString("order_number", r),
        userId        = Row.requireInt64("user_id", r),
        customerEmail = Row.requireString("customer_email", r),
        shippingName  = Row.requireString("shipping_name", r),
        address       = Row.requireString("address", r),
        city          = Row.requireString("city", r),
        postalCode    = Row.requireString("postal_code", r),
        country       = Row.requireString("country", r),
        promoCode     = Row.optionalString("promo_code", r),
        subtotalCents = Row.requireInt64("subtotal_cents", r),
        discountCents = Row.requireInt64("discount_cents", r),
        shippingCents = Row.requireInt64("shipping_cents", r),
        totalCents    = Row.requireInt64("total_cents", r),
        status        = Row.requireString("status", r),
        createdAt     = Row.requireString("created_at", r)
    }

    def dbLoadCartLines(ownerKey: String): List[CartLine] \ {Db, DbError} =
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

    def dbReserveAllStock(lines: List[CartLine]): Option[PlaceOrderError] \ {Db, DbError} =
        match lines {
            case Nil => None
            case line :: rest =>
                let affected = Db.execute(
                    "UPDATE products SET stock = stock - ? WHERE id = ? AND stock >= ?",
                    SqlValue.int(line#quantity) :: SqlValue.int64(line#productId) :: SqlValue.int(line#quantity) :: Nil
                );
                if (affected == 0)
                    Some(PlaceOrderError.InsufficientStock(line#name, line#quantity))
                else
                    dbReserveAllStock(rest)
        }

    def dbPlaceOrderAtomic(
        user: User,
        ownerKey: String,
        input: CheckoutInput,
        promoOpt: Option[PromoCode]
    ): Result[PlaceOrderError, Order] \ {Db, DbError, JobQueue, Random} = {
        Db.beginTx();
        run {
            let outcome = dbPlaceOrderBody(user, ownerKey, input, promoOpt);
            match outcome {
                case Ok(order) =>
                    Db.commitTx();
                    Ok(order)
                case Err(err) =>
                    Db.rollbackTx();
                    Err(err)
            }
        } with handler DbError {
            def raise(kind, msg, _k) = {
                Db.rollbackTx();
                DbError.raise(kind, msg)
            }
        }
    }

    def dbPlaceOrderBody(
        user: User,
        ownerKey: String,
        input: CheckoutInput,
        promoOpt: Option[PromoCode]
    ): Result[PlaceOrderError, Order] \ {Db, DbError, JobQueue, Random} = {
        let lines = dbLoadCartLines(ownerKey);
        if (List.isEmpty(lines))
            Err(PlaceOrderError.EmptyCart)
        else {
            match dbReserveAllStock(lines) {
                case Some(stockErr) => Err(stockErr)
                case None =>
                    let summary = Domain.summarizeCart(lines, promoOpt);
                    let orderNum = "WR-" + String.toUpperCase(Random.tokenHex(4));
                    let promoVal = match promoOpt {
                        case Some(p) => SqlValue.text(p#code)
                        case None    => SqlValue.nullVal()
                    };

                    let orderId = Db.insertAndGetId(
                        "INSERT INTO orders (order_number, user_id, shipping_name, address, city, postal_code, country, " +
                        "promo_code, subtotal_cents, discount_cents, shipping_cents, total_cents, status) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'paid')",
                        SqlValue.text(orderNum) ::
                        SqlValue.int64(user#id) ::
                        SqlValue.text(input#shippingName) ::
                        SqlValue.text(input#address) ::
                        SqlValue.text(input#city) ::
                        SqlValue.text(input#postalCode) ::
                        SqlValue.text(input#country) ::
                        promoVal ::
                        SqlValue.int64(summary#subtotalCents) ::
                        SqlValue.int64(summary#discountCents) ::
                        SqlValue.int64(summary#shippingCents) ::
                        SqlValue.int64(summary#totalCents) ::
                        Nil
                    );

                    List.forEach(line -> {
                        let _ = Db.execute(
                            "INSERT INTO order_items (order_id, product_id, sku, product_name, unit_cents, quantity, line_total_cents) " +
                            "VALUES (?, ?, ?, ?, ?, ?, ?)",
                            SqlValue.int64(orderId) ::
                            SqlValue.int64(line#productId) ::
                            SqlValue.text(line#sku) ::
                            SqlValue.text(line#name) ::
                            SqlValue.int64(line#unitCents) ::
                            SqlValue.int(line#quantity) ::
                            SqlValue.int64(line#lineTotalCents) ::
                            Nil
                        );
                        ()
                    }, lines);

                    let _ = Db.execute(
                        "DELETE FROM cart_items WHERE owner_key = ?",
                        SqlValue.text(ownerKey) :: Nil
                    );

                    let payload = Json.obj(
                        ("orderId",      Json.int64(orderId)) ::
                        ("orderNumber",  Json.str(orderNum)) ::
                        ("email",        Json.str(user#email)) ::
                        ("customerName", Json.str(input#shippingName)) ::
                        ("totalDisplay", Json.str(Shared.Money.formatCents(summary#totalCents))) ::
                        Nil
                    );
                    let _ = JobQueue.dispatchUnique("order:${orderId}:confirm", "order.confirmation_email", payload);

                    match dbFindOrderById(orderId) {
                        case Some(order) => Ok(order)
                        case None        => Err(PlaceOrderError.OrderReloadFailed(orderId))
                    }
            }
        }
    }

    def dbFindOrderById(orderId: Int64): Option[Order] \ {Db, DbError} =
        Db.queryOneMap(
            orderSelectSql() + " WHERE o.id = ?",
            SqlValue.int64(orderId) :: Nil,
            decodeOrder
        )

    def dbListOrderItems(orderId: Int64): List[OrderItem] \ {Db, DbError} =
        Db.queryMap(
            "SELECT id, order_id, product_id, sku, product_name, unit_cents, quantity, line_total_cents " +
            "FROM order_items WHERE order_id = ? ORDER BY id ASC",
            SqlValue.int64(orderId) :: Nil,
            r -> {
                id             = Row.requireInt64("id", r),
                orderId        = Row.requireInt64("order_id", r),
                productId      = Row.requireInt64("product_id", r),
                sku            = Row.requireString("sku", r),
                productName    = Row.requireString("product_name", r),
                unitCents      = Row.requireInt64("unit_cents", r),
                quantity       = Row.requireInt("quantity", r),
                lineTotalCents = Row.requireInt64("line_total_cents", r)
            }
        )

    def dbListOrdersForUser(userId: Int64): List[Order] \ {Db, DbError} =
        Db.queryMap(
            orderSelectSql() + " WHERE o.user_id = ? ORDER BY o.id DESC",
            SqlValue.int64(userId) :: Nil,
            decodeOrder
        )

    def dbListAllOrders(): List[Order] \ {Db, DbError} =
        Db.queryMap(
            orderSelectSql() + " ORDER BY o.id DESC",
            Nil,
            decodeOrder
        )

    def dbUpdateOrderStatus(orderId: Int64, newStatus: String): Option[Order] \ {Db, DbError, JobQueue} =
        Db.transaction(() -> {
            match dbFindOrderById(orderId) {
                case None => None
                case Some(order) =>
                    let _ = Db.execute(
                        "UPDATE orders SET status = ? WHERE id = ?",
                        SqlValue.text(newStatus) :: SqlValue.int64(orderId) :: Nil
                    );
                    let payload = Json.obj(
                        ("orderId",      Json.int64(orderId)) ::
                        ("orderNumber",  Json.str(order#orderNumber)) ::
                        ("email",        Json.str(order#customerEmail)) ::
                        ("customerName", Json.str(order#shippingName)) ::
                        ("status",       Json.str(newStatus)) ::
                        Nil
                    );
                    let _ = JobQueue.dispatch("order.status_email", payload);
                    Some({ status = newStatus | order })
            }
        })

}
