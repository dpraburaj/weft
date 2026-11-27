pub mod Shared.Layout {
    use Shared.Artwork
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, aside, attr, attrIf, button, cls, clsIf, div, footer, for_,
        form, header, href, id, img, input, label, link, main_, meta, method,
        name, nav, raw, script, scriptSrc, span, spanText, strongText,
        stylesheet, text, type_, value, when, whenSome
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.ValidationErrors

    pub def csrfInput(tok: String): Unit \ Html =
        input(() -> {
            type_("hidden");
            name("_csrf");
            value(tok)
        })

    def sharedHead(csrfTok: String): Unit \ Html = {
        raw("<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">");
        raw("<link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>");
        stylesheet("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;0,6..72,600;1,6..72,400&display=swap");
        stylesheet("/static/styles.css");
        meta("csrf-token", csrfTok);
        scriptSrc("https://unpkg.com/htmx.org@2.0.4");
        script(() -> raw(
            "document.addEventListener('htmx:configRequest',function(e){" +
            "var m=document.querySelector('meta[name=\"csrf-token\"]');" +
            "if(m){e.detail.headers['X-CSRF-Token']=m.getAttribute('content');}" +
            "});"
        ))
    }

    ///
    /// Editorial specialty coffee storefront page shell.
    ///
    pub def renderShell(
        pageTitle: String,
        csrfTok: String,
        userOpt: Option[Principal],
        cartCount: Int32,
        flashOk: Option[String],
        flashErr: Option[String],
        bodyHtml: String
    ): HtmlDoc =
        Html.pageWithHead(
            "${pageTitle} — Weft Roasters",
            () -> sharedHead(csrfTok),
            () -> {
                div(() -> {
                    cls("announcement-bar");
                    div(() -> {
                        cls("container");
                        text("ROASTED TO ORDER IN SMALL LOTS  ·  FREE SHIPPING OVER $75  ·  CODE WELCOME10 FOR 10% OFF")
                    })
                });
                siteHeader(csrfTok, userOpt, cartCount);
                main_(() ->
                    div(() -> {
                        cls("container");
                        whenSome(flashOk, msg -> div(() -> { cls("flash flash-ok"); text(msg) }));
                        whenSome(flashErr, msg -> div(() -> { cls("flash flash-err"); text(msg) }));
                        raw(bodyHtml)
                    })
                );
                siteFooter()
            }
        )

    ///
    /// Calm, high-density light-neutral merchant backoffice shell.
    ///
    pub def renderAdminShell(
        pageTitle: String,
        activeNav: String,
        csrfTok: String,
        userOpt: Option[Principal],
        productCount: Int32,
        pendingOrderCount: Int32,
        lowStockCount: Int32,
        flashOk: Option[String],
        flashErr: Option[String],
        bodyHtml: String
    ): HtmlDoc =
        Html.pageWithHead(
            "${pageTitle} — Weft Roasters Admin",
            () -> sharedHead(csrfTok),
            () ->
                div(() -> {
                    cls("admin-shell");
                    adminSidebar(activeNav, csrfTok, userOpt, productCount, pendingOrderCount, lowStockCount);
                    div(() -> {
                        cls("admin-workspace");
                        adminTopbar(pageTitle);
                        main_(() -> {
                            cls("admin-main");
                            whenSome(flashOk, msg -> div(() -> { cls("flash flash-ok"); text(msg) }));
                            whenSome(flashErr, msg -> div(() -> { cls("flash flash-err"); text(msg) }));
                            raw(bodyHtml)
                        })
                    })
                })
        )

    def adminSidebar(
        activeNav: String,
        csrfTok: String,
        userOpt: Option[Principal],
        productCount: Int32,
        pendingOrderCount: Int32,
        lowStockCount: Int32
    ): Unit \ Html =
        aside(() -> {
            cls("admin-sidebar");
            div(() -> {
                cls("admin-brand-wrap");
                a(() -> {
                    cls("admin-brand");
                    href("/admin");
                    img("/static/brand-mark.svg", "Weft Roasters");
                    div(() -> {
                        div(() -> { cls("admin-brand-name"); text("Weft Roasters") });
                        div(() -> { cls("admin-brand-sub"); text("Merchant Backoffice") })
                    })
                })
            });
            nav(() -> {
                cls("admin-nav");
                div(() -> { cls("admin-nav-section"); text("Store") });
                a(() -> {
                    cls("admin-nav-item");
                    clsIf(activeNav == "overview", "active");
                    href("/admin");
                    div(() -> { cls("admin-nav-label"); Artwork.iconHome(); spanText("Overview") })
                });
                a(() -> {
                    cls("admin-nav-item");
                    clsIf(activeNav == "orders", "active");
                    href("/admin/orders");
                    div(() -> { cls("admin-nav-label"); Artwork.iconOrders(); spanText("Orders") });
                    when(pendingOrderCount > 0, () ->
                        span(() -> { cls("admin-nav-count"); text("${pendingOrderCount}") })
                    )
                });
                a(() -> {
                    cls("admin-nav-item");
                    clsIf(activeNav == "products", "active");
                    href("/admin/products");
                    div(() -> { cls("admin-nav-label"); Artwork.iconBox(); spanText("Products") });
                    span(() -> { cls("admin-nav-count"); text("${productCount}") })
                });
                a(() -> {
                    cls("admin-nav-item");
                    clsIf(activeNav == "new-product", "active");
                    href("/admin/products/new");
                    div(() -> { cls("admin-nav-label"); Artwork.iconPlus(); spanText("Add product") })
                });
                when(lowStockCount > 0, () ->
                    a(() -> {
                        cls("admin-nav-item");
                        clsIf(activeNav == "low-stock", "active");
                        href("/admin/products?stock=low");
                        div(() -> { cls("admin-nav-label"); Artwork.iconAlert(); spanText("Low stock") });
                        span(() -> { cls("admin-nav-count alert"); text("${lowStockCount}") })
                    })
                );

                div(() -> { cls("admin-nav-section"); text("Channels") });
                a(() -> {
                    cls("admin-nav-item");
                    href("/");
                    div(() -> { cls("admin-nav-label"); Artwork.iconStore(); spanText("Online store") })
                });
                a(() -> {
                    cls("admin-nav-item");
                    href("/health");
                    div(() -> { cls("admin-nav-label"); Artwork.iconActivity(); spanText("System status") })
                })
            });
            div(() -> {
                cls("admin-sidebar-footer");
                match userOpt {
                    case Some(p) =>
                        div(() -> {
                            cls("admin-user-row");
                            div(() -> {
                                cls("admin-user-meta");
                                div(() -> { cls("admin-user-name"); text(Principal.name(p)) });
                                div(() -> { cls("admin-user-role"); text("Administrator") })
                            });
                            form(() -> {
                                method("post");
                                action("/logout");
                                csrfInput(csrfTok);
                                button(() -> { cls("admin-signout-btn"); type_("submit"); text("Log out") })
                            })
                        })
                    case None => ()
                }
            })
        })

    def adminTopbar(pageTitle: String): Unit \ Html =
        header(() -> {
            cls("admin-topbar");
            div(() -> {
                cls("admin-topbar-left");
                a(() -> { cls("admin-crumb"); href("/admin"); text("Weft Roasters") });
                span(() -> { cls("admin-crumb-sep"); text("/") });
                strongText(pageTitle)
            });
            div(() -> {
                cls("admin-topbar-actions");
                a(() -> { cls("admin-btn-ghost"); href("/"); text("View store") });
                a(() -> { cls("admin-btn-primary"); href("/admin/products/new"); text("Add product") })
            })
        })

    def siteHeader(csrfTok: String, userOpt: Option[Principal], cartCount: Int32): Unit \ Html =
        header(() -> {
            cls("site-header");
            div(() -> {
                cls("container header-inner");
                a(() -> {
                    cls("brand");
                    href("/");
                    img("/static/brand-mark.svg", "Weft Roasters");
                    span(() -> { cls("brand-wordmark"); text("Weft Roasters") })
                });
                nav(() -> {
                    cls("nav-links");
                    link("/", "Shop");
                    match userOpt {
                        case Some(p) =>
                            link("/orders", "Orders");
                            when(Principal.hasRole("admin", p), () -> link("/admin", "Admin"));
                            span(() -> { cls("nav-user"); text("Hi, ${Principal.name(p)}") });
                            form(() -> {
                                method("post");
                                action("/logout");
                                attr("style", "display:inline");
                                csrfInput(csrfTok);
                                button(() -> { cls("nav-signout"); type_("submit"); text("Sign Out") })
                            })
                        case None =>
                            link("/login", "Sign In");
                            link("/register", "Register")
                    };
                    a(() -> {
                        cls("cart-link");
                        href("/cart");
                        spanText("Bag");
                        cartBadgeSpan(cartCount, false)
                    })
                })
            })
        })

    def siteFooter(): Unit \ Html =
        footer(() -> {
            cls("site-footer");
            div(() -> {
                cls("container footer-inner");
                div(() -> {
                    cls("footer-brand");
                    strongText("Weft Roasters");
                    span(() -> { cls("muted"); text(" · Portland & Copenhagen · Small-batch coffee & precision brew ware.") })
                });
                div(() -> {
                    cls("footer-links");
                    link("/", "Catalog");
                    link("/cart", "Bag");
                    link("/api/products", "Catalog API");
                    link("/health", "Status")
                })
            })
        })

    ///
    /// Renders the live navbar cart count badge (optionally as an HTMX Out-Of-Band swap).
    ///
    pub def cartBadgeSpan(count: Int32, oob: Bool): Unit \ Html =
        span(() -> {
            id("cart-badge");
            cls("badge");
            clsIf(count == 0, "empty");
            attrIf(oob, "hx-swap-oob", "true");
            text("${count}")
        })

    pub def cartBadgePartial(count: Int32): HtmlDoc =
        Html.render(() -> cartBadgeSpan(count, false))

    pub def textField(fieldName: String, labelText: String, fieldVal: String, errs: ValidationErrors): Unit \ Html =
        div(() -> {
            cls("form-group");
            label(() -> { for_(fieldName); text(labelText) });
            input(() -> { id(fieldName); type_("text"); name(fieldName); value(fieldVal) });
            ValidationErrors.renderFieldError(fieldName, errs)
        })

    pub def statusChip(st: String): Unit \ Html =
        span(() -> {
            cls("status-chip status-${st}");
            text(st)
        })

}
