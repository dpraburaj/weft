pub mod Shared.Schema {
    use weft::Weft.Crypto
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.JobStore
    use weft::Weft.Migration
    use weft::Weft.Random
    use weft::Weft.Row
    use weft::Weft.SessionStore
    use weft::Weft.SqlValue

    ///
    /// Versioned SQLite migrations for the Weft Roasters e-commerce store.
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1,
            "create_ecommerce_tables",
            "CREATE TABLE users (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  email TEXT NOT NULL UNIQUE," +
            "  name TEXT NOT NULL," +
            "  password_hash TEXT NOT NULL," +
            "  role TEXT NOT NULL DEFAULT 'customer'," +
            "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" +
            ");" +
            "CREATE TABLE products (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  sku TEXT NOT NULL UNIQUE," +
            "  slug TEXT NOT NULL UNIQUE," +
            "  name TEXT NOT NULL," +
            "  category TEXT NOT NULL," +
            "  description TEXT NOT NULL," +
            "  price_cents INTEGER NOT NULL CHECK (price_cents > 0)," +
            "  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0)," +
            "  image_mime TEXT," +
            "  image_blob BLOB," +
            "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP," +
            "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" +
            ");" +
            "CREATE INDEX idx_products_category ON products(category);" +
            "CREATE TABLE cart_items (" +
            "  owner_key TEXT NOT NULL," +
            "  product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE," +
            "  quantity INTEGER NOT NULL CHECK (quantity > 0)," +
            "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP," +
            "  PRIMARY KEY (owner_key, product_id)" +
            ");" +
            "CREATE TABLE promo_codes (" +
            "  code TEXT PRIMARY KEY," +
            "  percent_off INTEGER NOT NULL DEFAULT 0," +
            "  free_ship INTEGER NOT NULL DEFAULT 0," +
            "  description TEXT NOT NULL" +
            ");" +
            "CREATE TABLE orders (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  order_number TEXT NOT NULL UNIQUE," +
            "  user_id INTEGER NOT NULL REFERENCES users(id)," +
            "  shipping_name TEXT NOT NULL," +
            "  address TEXT NOT NULL," +
            "  city TEXT NOT NULL," +
            "  postal_code TEXT NOT NULL," +
            "  country TEXT NOT NULL," +
            "  promo_code TEXT," +
            "  subtotal_cents INTEGER NOT NULL," +
            "  discount_cents INTEGER NOT NULL DEFAULT 0," +
            "  shipping_cents INTEGER NOT NULL DEFAULT 0," +
            "  total_cents INTEGER NOT NULL," +
            "  status TEXT NOT NULL DEFAULT 'paid'," +
            "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" +
            ");" +
            "CREATE INDEX idx_orders_user ON orders(user_id);" +
            "CREATE TABLE order_items (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE," +
            "  product_id INTEGER NOT NULL REFERENCES products(id)," +
            "  sku TEXT NOT NULL," +
            "  product_name TEXT NOT NULL," +
            "  unit_cents INTEGER NOT NULL," +
            "  quantity INTEGER NOT NULL," +
            "  line_total_cents INTEGER NOT NULL" +
            ");"
        ) ::
        Migration.make(
            2,
            "add_product_updated_at_trigger",
            "CREATE TRIGGER trg_products_updated_at AFTER UPDATE ON products " +
            "BEGIN " +
            "  UPDATE products SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id; " +
            "END;"
        ) ::
        Nil

    ///
    /// Runs all application + Weft framework migrations (`_weft_sessions`, `_weft_jobs`)
    /// and seeds the demo catalog, promo codes, and demo accounts idempotently.
    ///
    pub def initAndSeed(passwordIterations: Int32): Unit \ {Db, DbError, Random} = {
        let _ = Migration.runAll(migrations());
        SessionStore.initSchema();
        JobStore.initSchema();
        seedDemoData(passwordIterations)
    }

    def seedDemoData(passwordIterations: Int32): Unit \ {Db, DbError, Random} = {
        let existingCount = Db.queryOneMap("SELECT COUNT(*) AS cnt FROM products", Nil, Row.requireInt64("cnt"))
            |> Option.getWithDefault(0i64);
        if (existingCount == 0i64) {
            seedProducts();
            seedPromoCodes();
            seedUsers(passwordIterations)
        } else ()
    }

    def seedProducts(): Unit \ {Db, DbError} = {
        let items =
            ("COF-ETH-01", "ethiopia-yirgacheffe", "Ethiopia Yirgacheffe Washed", "coffee",
             "Floral jasmine, bergamot zest, and white peach notes. Roasted light for pour-over clarity.", 2200i64, 24) ::
            ("COF-COL-02", "colombia-huila-pink-bourbon", "Colombia Huila Pink Bourbon", "coffee",
             "Silky blood orange, panela sweetness, and crisp hibiscus finish from 1,850m high farms.", 2400i64, 18) ::
            ("COF-ESP-03", "velvet-espresso-blend", "Velvet Espresso Blend", "coffee",
             "Dark chocolate, toasted hazelnut, and caramelized fig balanced for espresso & milk drinks.", 1950i64, 35) ::
            ("COF-DEC-04", "colombia-sugarcane-decaf", "Colombia Sugarcane Decaf", "coffee",
             "Naturally decaffeinated with ethyl acetate from fermented sugarcane. Milk chocolate & cherry.", 2050i64, 14) ::
            ("GRD-BUR-01", "precision-flat-burr-grinder", "Precision 64mm Flat Burr Grinder", "grinders",
             "Low-retention single-dose electric grinder with stepless dial for espresso to cold brew.", 34900i64, 6) ::
            ("GRD-HND-02", "field-steel-hand-grinder", "Field Stainless Hand Grinder", "grinders",
             "CNC-machined heptagonal steel burrs with 40-click external adjustment for travel brewing.", 8900i64, 12) ::
            ("BRW-V60-01", "ceramic-ribbed-pour-over", "Ceramic Ribbed Pour-Over Dripper", "brewers",
             "Heat-retaining stoneware cone with spiral ribs for even extraction and clean cups.", 3200i64, 20) ::
            ("BRW-KET-02", "gooseneck-variable-kettle", "Gooseneck Variable Temp Kettle", "brewers",
             "1-degree precision PID temperature control, built-in brew stopwatch, matte obsidian steel.", 14500i64, 9) ::
            ("ACC-SCL-01", "barista-flow-scale", "Barista Flow-Rate Digital Scale", "accessories",
             "0.1g resolution waterproof scale with real-time pour rate indicator and USB-C charging.", 6400i64, 15) ::
            ("ACC-MUG-02", "stoneware-tasting-cups", "Stoneware Tasting Cups (Set of 2)", "accessories",
             "Hand-glazed 8oz double-walled ceramic cups engineered to concentrate coffee aromatics.", 3800i64, 4) ::
            Nil;

        List.forEach(match (sku, slug, name, cat, desc, price, stock) -> {
            let _ = Db.execute(
                "INSERT OR IGNORE INTO products (sku, slug, name, category, description, price_cents, stock) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                SqlValue.text(sku) ::
                SqlValue.text(slug) ::
                SqlValue.text(name) ::
                SqlValue.text(cat) ::
                SqlValue.text(desc) ::
                SqlValue.int64(price) ::
                SqlValue.int(stock) ::
                Nil
            );
            ()
        }, items)
    }

    def seedPromoCodes(): Unit \ {Db, DbError} = {
        let _ = Db.execute(
            "INSERT OR IGNORE INTO promo_codes (code, percent_off, free_ship, description) VALUES (?, ?, ?, ?)",
            SqlValue.text("WELCOME10") :: SqlValue.int(10) :: SqlValue.bool(false) :: SqlValue.text("10% off your order") :: Nil
        );
        let _ = Db.execute(
            "INSERT OR IGNORE INTO promo_codes (code, percent_off, free_ship, description) VALUES (?, ?, ?, ?)",
            SqlValue.text("FREESHIP") :: SqlValue.int(0) :: SqlValue.bool(true) :: SqlValue.text("Complimentary shipping") :: Nil
        );
        ()
    }

    def seedUsers(passwordIterations: Int32): Unit \ {Db, DbError, Random} = {
        let custHash = Crypto.hashPasswordWithIterations(passwordIterations, "coffee123");
        let adminHash = Crypto.hashPasswordWithIterations(passwordIterations, "admin123");
        let _ = Db.execute(
            "INSERT OR IGNORE INTO users (email, name, password_hash, role) VALUES (?, ?, ?, ?)",
            SqlValue.text("ada@example.com") :: SqlValue.text("Ada Lovelace") :: SqlValue.text(custHash) :: SqlValue.text("customer") :: Nil
        );
        let _ = Db.execute(
            "INSERT OR IGNORE INTO users (email, name, password_hash, role) VALUES (?, ?, ?, ?)",
            SqlValue.text("admin@weftroasters.com") :: SqlValue.text("Store Admin") :: SqlValue.text(adminHash) :: SqlValue.text("admin") :: Nil
        );
        ()
    }

}
