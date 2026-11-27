pub mod Features.Catalog.CatalogStore {
    use Features.Catalog.{CatalogFilter, NewProduct, Product, ProductImage}
    use Features.Catalog.CatalogStore
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.Page
    use weft::Weft.Row
    use weft::Weft.SqlBuilder
    use weft::Weft.SqlValue

    ///
    /// High-level persistence store for the Catalog vertical slice.
    /// Keeps all product SQL isolated from HTTP handlers, views, and domain logic.
    ///
    pub eff CatalogStore {
        def listProducts(filter: CatalogFilter): Page[Product]
        def listAllProducts(): List[Product]
        def findBySlug(slug: String): Option[Product]
        def findById(pid: Int64): Option[Product]
        def findImage(pid: Int64): Option[ProductImage]
        def createProduct(spec: NewProduct): Int64
        def updateStock(pid: Int64, newStock: Int32): Bool
    }

    ///
    /// SQLite/SQL implementation of `CatalogStore` backed by Weft's `Db` effect.
    ///
    pub def runWithDb(f: Unit -> a \ ef): a \ (ef - CatalogStore) + {Db, DbError} =
        run {
            f()
        } with handler CatalogStore {
            def listProducts(filter, k)  = k(dbListProducts(filter))
            def listAllProducts(k)       = k(dbListAllProducts())
            def findBySlug(slug, k)      = k(dbFindBySlug(slug))
            def findById(pid, k)         = k(dbFindById(pid))
            def findImage(pid, k)        = k(dbFindImage(pid))
            def createProduct(spec, k)   = k(dbCreateProduct(spec))
            def updateStock(pid, st, k)  = k(dbUpdateStock(pid, st))
        }

    ///
    /// Pure read-only in-memory handler for unit-testing Catalog handlers with zero `Db` or `IO`.
    ///
    pub def runPureReadOnly(products: List[Product], f: Unit -> a \ ef): a \ (ef - CatalogStore) =
        run {
            f()
        } with handler CatalogStore {
            def listProducts(filter, k) =
                let filtered = products
                    |> List.filter(p -> match filter#category {
                        case Some(c) if not String.isEmpty(String.trim(c)) => p#category == String.trim(c)
                        case _ => true
                    })
                    |> List.filter(p -> match filter#search {
                        case Some(q) if not String.isEmpty(String.trim(q)) =>
                            let needle = String.toLowerCase(String.trim(q));
                            String.contains({substr = needle}, String.toLowerCase(p#name)) or
                            String.contains({substr = needle}, String.toLowerCase(p#description)) or
                            String.contains({substr = needle}, String.toLowerCase(p#sku))
                        case _ => true
                    });
                let total = Int32.toInt64(List.length(filtered));
                let pg = Page.normalizePage(filter#page);
                let pp = Page.clampPerPage(24, filter#perPage);
                let sliced = filtered |> List.drop(Page.offset(pg, pp)) |> List.take(pp);
                k(Page.make(sliced, pg, pp, total))
            def listAllProducts(k) = k(products)
            def findBySlug(slug, k) = k(List.find(p -> p#slug == slug, products))
            def findById(pid, k) = k(List.find(p -> p#id == pid, products))
            def findImage(_, k) = k(None)
            def createProduct(_, k) = k(0i64)
            def updateStock(_, _, k) = k(false)
        }

    // --- SQLite Repository Queries (Private to CatalogStore) ---

    def selectSql(): String =
        "SELECT id, sku, slug, name, category, description, price_cents, stock, " +
        "CASE WHEN image_blob IS NOT NULL THEN 1 ELSE 0 END AS has_image " +
        "FROM products"

    def decodeProduct(r: Row): Product \ DbError = {
        id          = Row.requireInt64("id", r),
        sku         = Row.requireString("sku", r),
        slug        = Row.requireString("slug", r),
        name        = Row.requireString("name", r),
        category    = Row.requireString("category", r),
        description = Row.requireString("description", r),
        priceCents  = Row.requireInt64("price_cents", r),
        stock       = Row.requireInt("stock", r),
        hasImage    = Row.requireInt("has_image", r) != 0
    }

    def dbListProducts(filter: CatalogFilter): Page[Product] \ {Db, DbError} = {
        let p1: List[(String, List[SqlValue])] = match filter#category {
            case Some(c) if not String.isEmpty(String.trim(c)) =>
                ("category = ?", SqlValue.text(String.trim(c)) :: Nil) :: Nil
            case _ => Nil
        };
        let p2: List[(String, List[SqlValue])] = match filter#search {
            case Some(q) if not String.isEmpty(String.trim(q)) =>
                let pattern = "%" + String.trim(q) + "%";
                ("(name LIKE ? OR description LIKE ? OR sku LIKE ?)",
                 SqlValue.text(pattern) :: SqlValue.text(pattern) :: SqlValue.text(pattern) :: Nil) :: Nil
            case _ => Nil
        };
        let preds = List.append(p1, p2);

        let (countSql, countParams) =
            SqlBuilder.fromSql("SELECT COUNT(*) AS cnt FROM products")
                |> SqlBuilder.appendWhere(preds)
                |> SqlBuilder.build;
        let total = Db.queryOneMap(countSql, countParams, Row.requireInt64("cnt"))
            |> Option.getWithDefault(0i64);

        let orderSql = match filter#sort {
            case "price_asc"  => " ORDER BY price_cents ASC, id ASC"
            case "price_desc" => " ORDER BY price_cents DESC, id ASC"
            case "name_asc"   => " ORDER BY name ASC, id ASC"
            case _            => " ORDER BY id ASC"
        };

        let pg = Page.normalizePage(filter#page);
        let pp = Page.clampPerPage(24, filter#perPage);
        let (listSql, listParams) =
            SqlBuilder.fromSql(selectSql())
                |> SqlBuilder.appendWhere(preds)
                |> SqlBuilder.append(orderSql)
                |> SqlBuilder.appendLimitOffset(pp, Page.offset(pg, pp))
                |> SqlBuilder.build;

        let rows = Db.queryMap(listSql, listParams, decodeProduct);
        Page.make(rows, pg, pp, total)
    }

    def dbListAllProducts(): List[Product] \ {Db, DbError} =
        Db.queryMap(selectSql() + " ORDER BY id DESC", Nil, decodeProduct)

    def dbFindBySlug(slug: String): Option[Product] \ {Db, DbError} =
        Db.queryOneMap(selectSql() + " WHERE slug = ?", SqlValue.text(slug) :: Nil, decodeProduct)

    def dbFindById(pid: Int64): Option[Product] \ {Db, DbError} =
        Db.queryOneMap(selectSql() + " WHERE id = ?", SqlValue.int64(pid) :: Nil, decodeProduct)

    def dbFindImage(pid: Int64): Option[ProductImage] \ {Db, DbError} =
        Db.queryOneMap(
            "SELECT image_mime, image_blob FROM products WHERE id = ? AND image_blob IS NOT NULL",
            SqlValue.int64(pid) :: Nil,
            r -> {
                mime = Row.optionalString("image_mime", r) |> Option.getWithDefault("application/octet-stream"),
                data = Row.requireBlob("image_blob", r)
            }
        )

    def dbCreateProduct(spec: NewProduct): Int64 \ {Db, DbError} = {
        let (mimeVal, blobVal) = match spec#image {
            case Some(img) => (SqlValue.text(img#mime), SqlValue.blob(img#data))
            case None      => (SqlValue.nullVal(), SqlValue.nullVal())
        };
        Db.insertAndGetId(
            "INSERT INTO products (sku, slug, name, category, description, price_cents, stock, image_mime, image_blob) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            SqlValue.text(spec#sku) ::
            SqlValue.text(spec#slug) ::
            SqlValue.text(spec#name) ::
            SqlValue.text(spec#category) ::
            SqlValue.text(spec#description) ::
            SqlValue.int64(spec#priceCents) ::
            SqlValue.int(spec#stock) ::
            mimeVal ::
            blobVal ::
            Nil
        )
    }

    def dbUpdateStock(pid: Int64, newStock: Int32): Bool \ {Db, DbError} =
        Db.execute(
            "UPDATE products SET stock = ? WHERE id = ?",
            SqlValue.int(Int32.max(0, newStock)) :: SqlValue.int64(pid) :: Nil
        ) > 0

}
