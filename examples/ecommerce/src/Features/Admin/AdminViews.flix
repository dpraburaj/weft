mod Features.Admin.AdminViews {
    use Shared.Artwork
    use Shared.Domain.{Order, Product}
    use weft::Weft.Csrf
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.View
    use weft::Weft.View.{
        a, action, attr, button, cls, clsIf, div, each, for_, form, frag,
        h1Text, h2Text, h3Text, href, hxPost, hxSwap, hxTarget, id, img, input,
        label, link, method, name, option, p, rows, section, select_, selected,
        span, spanText, table, tbody, td, text, textarea, th, thText, thead,
        tr, type_, value, when, whenSome
    }

    // =========================================================================
    // 1. GET /admin — Overview
    // =========================================================================

    pub def overviewPage(
        userOpt: Option[Principal],
        products: List[Product],
        orders: List[Order],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let pendingOrders = List.filter(o -> o#status == "paid" or o#status == "roasted", orders);
        let lowStockProducts = List.filter(p -> p#stock <= 5, products);
        let pendingCount = List.length(pendingOrders);
        let lowStockCount = List.length(lowStockProducts);

        let bodyView = frag(Vector#{
            div(Vector#{ cls("admin-page-head"), h1Text("Overview") }),
            renderMetricStrip(products, orders, pendingCount, lowStockCount),
            renderOverviewWorkspaces(csrfTok, pendingOrders, orders, lowStockProducts)
        });

        Shared.Layout.renderAdminShell(
            "Overview",
            "overview",
            csrfTok,
            userOpt,
            List.length(products),
            pendingCount,
            lowStockCount,
            flashOk,
            flashErr,
            bodyView
        )
    }

    // =========================================================================
    // 2. GET /admin/orders — Orders & Fulfillment
    // =========================================================================

    pub def ordersPage(
        userOpt: Option[Principal],
        products: List[Product],
        allOrders: List[Order],
        statusFilter: Option[String],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let pendingCount = List.count(o -> o#status == "paid" or o#status == "roasted", allOrders);
        let lowStockCount = List.count(p -> p#stock <= 5, products);
        let filtered = match statusFilter {
            case None     => allOrders
            case Some(st) => List.filter(o -> o#status == st, allOrders)
        };

        let bodyView = frag(Vector#{
            div(Vector#{
                cls("admin-page-head"),
                h1Text("Orders"),
                span(Vector#{ cls("admin-head-meta"), text("${List.length(allOrders)} total · ${pendingCount} awaiting fulfillment") })
            }),
            renderOrdersTableCard(csrfTok, allOrders, filtered, statusFilter)
        });

        Shared.Layout.renderAdminShell(
            "Orders",
            "orders",
            csrfTok,
            userOpt,
            List.length(products),
            pendingCount,
            lowStockCount,
            flashOk,
            flashErr,
            bodyView
        )
    }

    // =========================================================================
    // 3. GET /admin/products — Products & Inventory
    // =========================================================================

    pub def productsPage(
        userOpt: Option[Principal],
        allProducts: List[Product],
        orders: List[Order],
        catFilter: Option[String],
        stockFilter: Option[String],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let pendingCount = List.count(o -> o#status == "paid" or o#status == "roasted", orders);
        let lowStockCount = List.count(p -> p#stock <= 5, allProducts);

        let byCat = match catFilter {
            case None    => allProducts
            case Some(c) => List.filter(p -> p#category == c, allProducts)
        };
        let filtered = match stockFilter {
            case Some("low") => List.filter(p -> p#stock <= 5, byCat)
            case Some("out") => List.filter(p -> p#stock == 0, byCat)
            case _           => byCat
        };
        let activeNav = if (stockFilter == Some("low")) "low-stock" else "products";

        let bodyView = frag(Vector#{
            div(Vector#{
                cls("admin-page-head"),
                h1Text("Products"),
                a(Vector#{ cls("admin-btn-primary"), href("/admin/products/new"), text("Add product") })
            }),
            renderInventoryTableCard(csrfTok, allProducts, filtered, catFilter, stockFilter)
        });

        Shared.Layout.renderAdminShell(
            "Products",
            activeNav,
            csrfTok,
            userOpt,
            List.length(allProducts),
            pendingCount,
            lowStockCount,
            flashOk,
            flashErr,
            bodyView
        )
    }

    // =========================================================================
    // 4. GET /admin/products/new — Add Product
    // =========================================================================

    pub def newProductPage(
        userOpt: Option[Principal],
        products: List[Product],
        orders: List[Order],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let pendingCount = List.count(o -> o#status == "paid" or o#status == "roasted", orders);
        let lowStockCount = List.count(p -> p#stock <= 5, products);

        let bodyView = frag(Vector#{
            div(Vector#{
                cls("admin-page-head"),
                div(Vector#{
                    a(Vector#{ cls("admin-back-link"), href("/admin/products"), text("← Products") }),
                    h1Text("Add product")
                })
            }),
            renderCreateProductCard(csrfTok)
        });

        Shared.Layout.renderAdminShell(
            "Add product",
            "new-product",
            csrfTok,
            userOpt,
            List.length(products),
            pendingCount,
            lowStockCount,
            flashOk,
            flashErr,
            bodyView
        )
    }

    // --- HTMX Partials ---

    pub def stockFormPartial(prod: Product): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        View.render(renderStockForm(csrfTok, prod))
    }

    pub def orderRowPartial(order: Order): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        View.render(renderOrderRow(csrfTok, order))
    }

    // =========================================================================
    // Calm, High-Density Merchant Components
    // =========================================================================

    def renderMetricStrip(
        products: List[Product],
        orders: List[Order],
        pendingCount: Int32,
        lowStockCount: Int32
    ): View = {
        let gmvCents = List.foldLeft((acc, o) -> acc + o#totalCents, 0i64, orders);
        let orderCount = List.length(orders);
        let aovCents = if (orderCount == 0) 0i64 else gmvCents / Int32.toInt64(orderCount);
        let totalUnits = List.foldLeft((acc, p) -> acc + p#stock, 0, products);

        div(Vector#{
            cls("metric-strip"),
            metricCell("Gross sales", Shared.Money.formatCents(gmvCents), "AOV ${Shared.Money.formatCents(aovCents)}", "/admin/orders", false),
            metricCell("Unfulfilled", "${pendingCount}", "of ${orderCount} total orders", "/admin/orders?status=paid", pendingCount > 0),
            metricCell("On hand", "${totalUnits}", "${List.length(products)} active SKUs", "/admin/products", false),
            metricCell("Low stock", "${lowStockCount}", "SKUs at 5 units or fewer", "/admin/products?stock=low", lowStockCount > 0)
        })
    }

    def metricCell(labelStr: String, valStr: String, subStr: String, destHref: String, highlight: Bool): View =
        a(Vector#{
            cls("metric-cell"),
            href(destHref),
            div(Vector#{ cls("metric-label"), text(labelStr) }),
            div(Vector#{
                cls("metric-val tabular"),
                clsIf(highlight, "attention"),
                text(valStr)
            }),
            div(Vector#{ cls("metric-sub"), text(subStr) })
        })

    def renderOverviewWorkspaces(
        csrfTok: String,
        pendingOrders: List[Order],
        allOrders: List[Order],
        lowStockProducts: List[Product]
    ): View = {
        let previewOrders = List.take(6, if (List.isEmpty(pendingOrders)) allOrders else pendingOrders);
        div(Vector#{
            cls("admin-overview-grid"),
            section(Vector#{
                cls("admin-card"),
                div(Vector#{
                    cls("admin-card-header"),
                    h2Text("Recent orders"),
                    a(Vector#{ cls("admin-inline-link"), href("/admin/orders"), text("View all") })
                }),
                if (List.isEmpty(previewOrders)) {
                    div(Vector#{
                        cls("admin-empty-state"),
                        p(Vector#{ cls("muted"), text("No orders have been placed yet.") })
                    })
                } else {
                    div(Vector#{
                        cls("table-scroll"),
                        table(Vector#{
                            cls("admin-table"),
                            thead(Vector#{ tr(Vector#{
                                thText("Order"),
                                thText("Customer"),
                                th(Vector#{ cls("num-col"), text("Total") }),
                                thText("Status")
                            }) }),
                            tbody(Vector#{
                                each(previewOrders, o ->
                                    tr(Vector#{
                                        td(Vector#{ div(Vector#{ cls("order-num-cell"), link("/orders/${o#id}", o#orderNumber) }) }),
                                        td(Vector#{
                                            div(Vector#{ cls("cell-primary"), text(o#shippingName) }),
                                            div(Vector#{ cls("cell-sub"), text(o#customerEmail) })
                                        }),
                                        td(Vector#{ cls("num-col cell-primary tabular"), text(Shared.Money.formatCents(o#totalCents)) }),
                                        td(Vector#{ Shared.Layout.statusChip(o#status) })
                                    })
                                )
                            })
                        })
                    })
                }
            }),
            section(Vector#{
                cls("admin-card"),
                div(Vector#{
                    cls("admin-card-header"),
                    h2Text("Inventory needing restock"),
                    a(Vector#{ cls("admin-inline-link"), href("/admin/products"), text("All products") })
                }),
                if (List.isEmpty(lowStockProducts)) {
                    div(Vector#{
                        cls("admin-empty-state"),
                        p(Vector#{ cls("muted"), text("All SKUs are above the 5-unit threshold.") })
                    })
                } else {
                    div(Vector#{
                        cls("low-stock-list"),
                        each(lowStockProducts, prod ->
                            div(Vector#{
                                cls("low-stock-item"),
                                div(Vector#{
                                    div(Vector#{ cls("cell-primary"), link("/products/${prod#slug}", prod#name) }),
                                    div(Vector#{
                                        cls("cell-sub mono"),
                                        text("${prod#sku} · ${prod#stock} left")
                                    })
                                }),
                                renderStockForm(csrfTok, prod)
                            })
                        )
                    })
                }
            })
        })
    }

    // --- Orders Table ---

    def renderOrdersTableCard(
        csrfTok: String,
        allOrders: List[Order],
        filteredOrders: List[Order],
        activeStatus: Option[String]
    ): View = {
        let paidN = List.count(o -> o#status == "paid", allOrders);
        let roastedN = List.count(o -> o#status == "roasted", allOrders);
        let shippedN = List.count(o -> o#status == "shipped", allOrders);
        let deliveredN = List.count(o -> o#status == "delivered", allOrders);

        section(Vector#{
            cls("admin-card"),
            div(Vector#{
                cls("admin-filter-tabs"),
                filterTab("All", List.length(allOrders), "/admin/orders", Option.isEmpty(activeStatus)),
                filterTab("Paid", paidN, "/admin/orders?status=paid", activeStatus == Some("paid")),
                filterTab("Roasted", roastedN, "/admin/orders?status=roasted", activeStatus == Some("roasted")),
                filterTab("Shipped", shippedN, "/admin/orders?status=shipped", activeStatus == Some("shipped")),
                filterTab("Delivered", deliveredN, "/admin/orders?status=delivered", activeStatus == Some("delivered"))
            }),
            if (List.isEmpty(filteredOrders)) {
                div(Vector#{
                    cls("admin-empty-state"),
                    p(Vector#{ cls("muted"), text("No orders in this status.") })
                })
            } else {
                div(Vector#{
                    cls("table-scroll"),
                    table(Vector#{
                        cls("admin-table"),
                        thead(Vector#{ tr(Vector#{
                            thText("Order"),
                            thText("Date"),
                            thText("Customer"),
                            th(Vector#{ cls("num-col"), text("Total") }),
                            thText("Status"),
                            thText("Fulfillment")
                        }) }),
                        tbody(Vector#{ each(filteredOrders, o -> renderOrderRow(csrfTok, o)) })
                    })
                })
            }
        })
    }

    def filterTab(labelStr: String, count: Int32, destHref: String, isActive: Bool): View =
        a(Vector#{
            cls("admin-tab"),
            clsIf(isActive, "active"),
            href(destHref),
            spanText(labelStr),
            span(Vector#{ cls("admin-tab-count"), text("${count}") })
        })

    def renderOrderRow(csrfTok: String, order: Order): View =
        tr(Vector#{
            id("order-row-${order#id}"),
            td(Vector#{ div(Vector#{ cls("order-num-cell"), link("/orders/${order#id}", order#orderNumber) }) }),
            td(Vector#{ span(Vector#{ cls("cell-sub mono"), text(order#createdAt) }) }),
            td(Vector#{
                div(Vector#{ cls("cell-primary"), text(order#shippingName) }),
                div(Vector#{ cls("cell-sub"), text(order#customerEmail) })
            }),
            td(Vector#{
                cls("num-col"),
                div(Vector#{ cls("cell-primary tabular"), text(Shared.Money.formatCents(order#totalCents)) }),
                whenSome(order#promoCode, code ->
                    span(Vector#{ cls("promo-tag"), text(code) })
                )
            }),
            td(Vector#{ Shared.Layout.statusChip(order#status) }),
            td(Vector#{
                form(Vector#{
                    cls("inline-action-form"),
                    method("post"),
                    action("/admin/orders/${order#id}/status"),
                    hxPost("/admin/orders/${order#id}/status"),
                    hxTarget("#order-row-${order#id}"),
                    hxSwap("outerHTML"),
                    Shared.Layout.csrfInput(csrfTok),
                    select_(Vector#{
                        cls("compact-select"),
                        name("status"),
                        each(Shared.Money.orderStatuses(), st ->
                            option(Vector#{
                                value(st),
                                when(order#status == st, selected()),
                                text(st)
                            })
                        )
                    }),
                    button(Vector#{ cls("admin-btn-secondary"), type_("submit"), text("Update") })
                })
            })
        })

    // --- Products & Inventory Table ---

    def renderInventoryTableCard(
        csrfTok: String,
        allProducts: List[Product],
        filteredProducts: List[Product],
        catFilter: Option[String],
        stockFilter: Option[String]
    ): View = {
        let lowCount = List.count(p -> p#stock <= 5, allProducts);
        let outCount = List.count(p -> p#stock == 0, allProducts);

        section(Vector#{
            cls("admin-card"),
            div(Vector#{
                cls("admin-filter-tabs"),
                filterTab("All", List.length(allProducts), "/admin/products", Option.isEmpty(catFilter) and Option.isEmpty(stockFilter)),
                filterTab("Low stock", lowCount, "/admin/products?stock=low", stockFilter == Some("low")),
                filterTab("Out of stock", outCount, "/admin/products?stock=out", stockFilter == Some("out")),
                each(Shared.Money.categories(), match (slug, title) -> {
                    let cnt = List.count(p -> p#category == slug, allProducts);
                    filterTab(title, cnt, "/admin/products?category=${slug}", catFilter == Some(slug) and Option.isEmpty(stockFilter))
                })
            }),
            if (List.isEmpty(filteredProducts)) {
                div(Vector#{
                    cls("admin-empty-state"),
                    p(Vector#{ cls("muted"), text("No products match this view.") })
                })
            } else {
                div(Vector#{
                    cls("table-scroll"),
                    table(Vector#{
                        cls("admin-table"),
                        thead(Vector#{ tr(Vector#{
                            thText("Product"),
                            thText("SKU"),
                            thText("Category"),
                            th(Vector#{ cls("num-col"), text("Price") }),
                            thText("Inventory"),
                            thText("On hand")
                        }) }),
                        tbody(Vector#{
                            each(filteredProducts, prod ->
                                tr(Vector#{
                                    td(Vector#{
                                        div(Vector#{
                                            cls("prod-cell"),
                                            div(Vector#{
                                                cls("prod-thumb-sm"),
                                                if (prod#hasImage)
                                                    a(Vector#{ href("/media/products/${prod#id}"), img("/media/products/${prod#id}", prod#name) })
                                                else
                                                    Artwork.productIllustration(prod)
                                            }),
                                            div(Vector#{
                                                div(Vector#{ cls("cell-primary"), link("/products/${prod#slug}", prod#name) }),
                                                when(prod#hasImage,
                                                    div(Vector#{ cls("cell-sub"), link("/media/products/${prod#id}", "Custom photo") })
                                                )
                                            })
                                        })
                                    }),
                                    td(Vector#{ span(Vector#{ cls("sku-code"), text(prod#sku) }) }),
                                    td(Vector#{ span(Vector#{ cls("cell-sub"), text(prod#category) }) }),
                                    td(Vector#{
                                        cls("num-col cell-primary tabular"),
                                        text(Shared.Money.formatCents(prod#priceCents))
                                    }),
                                    td(Vector#{ renderStockStatus(prod#stock) }),
                                    td(Vector#{ renderStockForm(csrfTok, prod) })
                                })
                            )
                        })
                    })
                })
            }
        })
    }

    def renderStockStatus(stock: Int32): View =
        if (stock <= 0)
            span(Vector#{ cls("inv-state out"), text("Out of stock") })
        else if (stock <= 5)
            span(Vector#{ cls("inv-state low"), text("Low · ${stock} left") })
        else
            span(Vector#{ cls("inv-state ok"), text("In stock") })

    def renderStockForm(csrfTok: String, prod: Product): View =
        form(Vector#{
            id("stock-form-${prod#id}"),
            cls("inline-action-form"),
            method("post"),
            action("/admin/products/${prod#id}/stock"),
            hxPost("/admin/products/${prod#id}/stock"),
            hxTarget("#stock-form-${prod#id}"),
            hxSwap("outerHTML"),
            Shared.Layout.csrfInput(csrfTok),
            input(Vector#{
                cls("stock-input tabular"),
                type_("number"),
                name("stock"),
                value("${prod#stock}"),
                attr("min", "0")
            }),
            button(Vector#{ cls("admin-btn-secondary"), type_("submit"), text("Save") })
        })

    // --- Add Product Composer ---

    def renderCreateProductCard(csrfTok: String): View =
        form(Vector#{
            method("post"),
            action("/admin/products"),
            attr("enctype", "multipart/form-data"),
            Shared.Layout.csrfInput(csrfTok),
            div(Vector#{
                cls("composer-grid"),
                div(Vector#{
                    cls("composer-main"),
                    div(Vector#{
                        cls("admin-card composer-pad"),
                        h3Text("Product information"),
                        div(Vector#{
                            cls("form-group"),
                            label(Vector#{ for_("name"), text("Title") }),
                            input(Vector#{ id("name"), type_("text"), name("name"), attr("placeholder", "Kenya AA Nyeri Washed") })
                        }),
                        div(Vector#{
                            cls("form-group"),
                            attr("style", "margin-bottom:0"),
                            label(Vector#{ for_("description"), text("Description") }),
                            textarea(Vector#{ id("description"), name("description"), rows(4), attr("placeholder", "Tasting notes, origin, elevation, and recommended brew method.") })
                        })
                    }),
                    div(Vector#{
                        cls("admin-card composer-pad"),
                        h3Text("Media"),
                        div(Vector#{
                            cls("upload-zone"),
                            label(Vector#{ for_("image"), cls("upload-label"), text("Product photo") }),
                            input(Vector#{ id("image"), type_("file"), name("image"), attr("accept", "image/*") }),
                            p(Vector#{ cls("upload-hint"), text("PNG, JPG, or WebP. Optional — products without photos display a roastery label.") })
                        })
                    })
                }),
                div(Vector#{
                    cls("composer-side"),
                    div(Vector#{
                        cls("admin-card composer-pad"),
                        h3Text("Pricing & inventory"),
                        div(Vector#{
                            cls("form-group"),
                            label(Vector#{ for_("sku"), text("SKU") }),
                            input(Vector#{ id("sku"), type_("text"), name("sku"), attr("placeholder", "COF-KEN-05") })
                        }),
                        div(Vector#{
                            cls("form-group"),
                            label(Vector#{ for_("category"), text("Category") }),
                            select_(Vector#{
                                id("category"),
                                name("category"),
                                each(Shared.Money.categories(), match (slug, title) ->
                                    option(Vector#{ value(slug), text(title) })
                                )
                            })
                        }),
                        div(Vector#{
                            cls("form-row"),
                            div(Vector#{
                                cls("form-group"),
                                label(Vector#{ for_("price_cents"), text("Price (cents)") }),
                                input(Vector#{ id("price_cents"), type_("number"), name("price_cents"), value("2400") })
                            }),
                            div(Vector#{
                                cls("form-group"),
                                label(Vector#{ for_("stock"), text("Quantity") }),
                                input(Vector#{ id("stock"), type_("number"), name("stock"), value("15") })
                            })
                        }),
                        div(Vector#{
                            cls("composer-actions"),
                            button(Vector#{ cls("admin-btn-primary btn-full"), type_("submit"), text("Create Product") }),
                            a(Vector#{ cls("admin-btn-ghost btn-full"), href("/admin/products"), text("Discard") })
                        })
                    })
                })
            })
        })

}
