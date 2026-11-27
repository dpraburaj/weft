mod Features.Admin.AdminViews {
    use Features.Catalog.Product
    use Features.Checkout.Order
    use weft::Weft.Csrf
    use weft::Weft.Html
    use weft::Weft.Html.{
        action, attr, button, cls, div, each, for_, form, h1Text, h2Text,
        hxPost, hxSwap, hxTarget, id, input, label, link, method, name, option,
        p, raw, rows, select_, selected, span, strongText, table, tbody, td,
        tdText, text, textarea, thText, thead, tr, type_, value, when
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session

    pub def adminPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        products: List[Product],
        orders: List[Order],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let createHtml = Html.renderString(() -> renderCreateProductPanel(csrfTok));
        let invHtml = Html.renderString(() -> renderInventoryPanel(csrfTok, products));
        let ordersHtml = Html.renderString(() -> renderOrdersPanel(csrfTok, orders));
        let bodyHtml = Html.renderString(() -> {
            h1Text("Store Admin Dashboard");
            raw(createHtml);
            raw(invHtml);
            raw(ordersHtml)
        });
        Shared.Layout.renderShell("Admin Dashboard", csrfTok, userOpt, cartCount, flashOk, flashErr, bodyHtml)
    }

    pub def stockFormPartial(prod: Product): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Html.render(() -> renderStockForm(csrfTok, prod))
    }

    pub def orderRowPartial(order: Order): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Html.render(() -> renderOrderRow(csrfTok, order))
    }

    // --- Pure HTML Sections ---

    def renderCreateProductPanel(csrfTok: String): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Add New Product (with optional image upload)");
            form(() -> {
                method("post");
                action("/admin/products");
                attr("enctype", "multipart/form-data");
                Shared.Layout.csrfInput(csrfTok);
                div(() -> {
                    cls("form-row");
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("sku"); text("SKU") });
                        input(() -> { id("sku"); type_("text"); name("sku"); attr("placeholder", "COF-KEN-05") })
                    });
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("name"); text("Product Name") });
                        input(() -> { id("name"); type_("text"); name("name"); attr("placeholder", "Kenya AA Nyeri") })
                    });
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("category"); text("Category") });
                        select_(() -> {
                            id("category");
                            name("category");
                            each(Shared.Money.categories(), match (slug, title) ->
                                option(() -> { value(slug); text(title) })
                            )
                        })
                    })
                });
                div(() -> {
                    cls("form-row");
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("price_cents"); text("Price (cents, e.g. 2600 = $26.00)") });
                        input(() -> { id("price_cents"); type_("number"); name("price_cents"); value("2400") })
                    });
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("stock"); text("Initial Stock") });
                        input(() -> { id("stock"); type_("number"); name("stock"); value("15") })
                    });
                    div(() -> {
                        cls("form-group");
                        label(() -> { for_("image"); text("Product Image (PNG/JPEG/WebP)") });
                        input(() -> { id("image"); type_("file"); name("image"); attr("accept", "image/*") })
                    })
                });
                div(() -> {
                    cls("form-group");
                    label(() -> { for_("description"); text("Description") });
                    textarea(() -> { id("description"); name("description"); rows(2) })
                });
                button(() -> { type_("submit"); text("Create Product") })
            })
        })

    def renderInventoryPanel(csrfTok: String, products: List[Product]): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Inventory (${List.length(products)} products)");
            table(() -> {
                thead(() -> tr(() -> {
                    thText("SKU");
                    thText("Product");
                    thText("Price");
                    thText("Image");
                    thText("Stock (HTMX Inline Update)")
                }));
                tbody(() ->
                    each(products, prod ->
                        tr(() -> {
                            tdText(prod#sku);
                            td(() -> link("/products/${prod#slug}", prod#name));
                            tdText(Shared.Money.formatCents(prod#priceCents));
                            td(() ->
                                if (prod#hasImage) link("/media/products/${prod#id}", "View BLOB")
                                else span(() -> { cls("muted"); text("—") })
                            );
                            td(() -> renderStockForm(csrfTok, prod))
                        })
                    )
                )
            })
        })

    def renderStockForm(csrfTok: String, prod: Product): Unit \ Html =
        form(() -> {
            id("stock-form-${prod#id}");
            method("post");
            action("/admin/products/${prod#id}/stock");
            hxPost("/admin/products/${prod#id}/stock");
            hxTarget("#stock-form-${prod#id}");
            hxSwap("outerHTML");
            attr("style", "display:flex;gap:0.4rem;align-items:center");
            Shared.Layout.csrfInput(csrfTok);
            input(() -> {
                type_("number");
                name("stock");
                value("${prod#stock}");
                attr("min", "0");
                attr("style", "width:80px")
            });
            button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("Save") })
        })

    def renderOrdersPanel(csrfTok: String, orders: List[Order]): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Recent Orders (${List.length(orders)})");
            if (List.isEmpty(orders)) {
                p(() -> { cls("muted"); text("No customer orders placed yet.") })
            } else {
                table(() -> {
                    thead(() -> tr(() -> {
                        thText("Order #");
                        thText("Customer");
                        thText("Total");
                        thText("Status");
                        thText("Update Fulfillment")
                    }));
                    tbody(() -> each(orders, o -> renderOrderRow(csrfTok, o)))
                })
            }
        })

    def renderOrderRow(csrfTok: String, order: Order): Unit \ Html =
        tr(() -> {
            id("order-row-${order#id}");
            td(() -> link("/orders/${order#id}", order#orderNumber));
            td(() -> {
                strongText(order#shippingName);
                div(() -> { cls("muted"); attr("style", "font-size:0.8rem"); text(order#customerEmail) })
            });
            tdText(Shared.Money.formatCents(order#totalCents));
            td(() -> Shared.Layout.statusChip(order#status));
            td(() ->
                form(() -> {
                    method("post");
                    action("/admin/orders/${order#id}/status");
                    hxPost("/admin/orders/${order#id}/status");
                    hxTarget("#order-row-${order#id}");
                    hxSwap("outerHTML");
                    attr("style", "display:flex;gap:0.4rem;align-items:center");
                    Shared.Layout.csrfInput(csrfTok);
                    select_(() -> {
                        name("status");
                        each(Shared.Money.orderStatuses(), st ->
                            option(() -> {
                                value(st);
                                when(order#status == st, () -> selected());
                                text(st)
                            })
                        )
                    });
                    button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("Update") })
                })
            )
        })

}
