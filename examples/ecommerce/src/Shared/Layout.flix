pub mod Shared.Layout {
    use Shared.Artwork
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.ValidationErrors
    use weft::Weft.View
    use weft::Weft.View.{
        a, action, aside, attr, attrIf, button, cls, clsIf, div, empty, footer,
        for_, form, frag, header, href, id, img, input, label, link, main_,
        meta, method, name, nav, raw, script, scriptSrc, span, spanText,
        strongText, stylesheet, text, type_, value, when, whenSome
    }

    pub def csrfInput(tok: String): View =
        input(Vector#{
            type_("hidden"),
            name("_csrf"),
            value(tok)
        })

    def sharedHead(csrfTok: String): View =
        frag(Vector#{
            raw("<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\"><link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>"),
            stylesheet("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;0,6..72,600;1,6..72,400&display=swap"),
            stylesheet("/static/styles.css"),
            meta("csrf-token", csrfTok),
            scriptSrc("https://unpkg.com/htmx.org@2.0.4"),
            script(Vector#{ raw(
                "document.addEventListener('htmx:configRequest',function(e){" +
                "var m=document.querySelector('meta[name=\"csrf-token\"]');" +
                "if(m){e.detail.headers['X-CSRF-Token']=m.getAttribute('content');}" +
                "});"
            ) })
        })

    ///
    /// Editorial specialty coffee storefront page shell (single-pass pure `Weft.View`).
    ///
    pub def renderShell(
        pageTitle: String,
        csrfTok: String,
        userOpt: Option[Principal],
        cartCount: Int32,
        flashOk: Option[String],
        flashErr: Option[String],
        bodyView: View
    ): HtmlDoc =
        View.pageWithHead(
            "${pageTitle} — Weft Roasters",
            sharedHead(csrfTok),
            frag(Vector#{
                div(Vector#{
                    cls("announcement-bar"),
                    div(Vector#{
                        cls("container"),
                        text("ROASTED TO ORDER IN SMALL LOTS  ·  FREE SHIPPING OVER $75  ·  CODE WELCOME10 FOR 10% OFF")
                    })
                }),
                siteHeader(csrfTok, userOpt, cartCount),
                main_(Vector#{
                    div(Vector#{
                        cls("container"),
                        whenSome(flashOk, msg -> div(Vector#{ cls("flash flash-ok"), text(msg) })),
                        whenSome(flashErr, msg -> div(Vector#{ cls("flash flash-err"), text(msg) })),
                        bodyView
                    })
                }),
                siteFooter()
            })
        )

    ///
    /// Calm, high-density light-neutral merchant backoffice shell (single-pass pure `Weft.View`).
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
        bodyView: View
    ): HtmlDoc =
        View.pageWithHead(
            "${pageTitle} — Weft Roasters Admin",
            sharedHead(csrfTok),
            div(Vector#{
                cls("admin-shell"),
                adminSidebar(activeNav, csrfTok, userOpt, productCount, pendingOrderCount, lowStockCount),
                div(Vector#{
                    cls("admin-workspace"),
                    adminTopbar(pageTitle),
                    main_(Vector#{
                        cls("admin-main"),
                        whenSome(flashOk, msg -> div(Vector#{ cls("flash flash-ok"), text(msg) })),
                        whenSome(flashErr, msg -> div(Vector#{ cls("flash flash-err"), text(msg) })),
                        bodyView
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
    ): View =
        aside(Vector#{
            cls("admin-sidebar"),
            div(Vector#{
                cls("admin-brand-wrap"),
                a(Vector#{
                    cls("admin-brand"),
                    href("/admin"),
                    img("/static/brand-mark.svg", "Weft Roasters"),
                    div(Vector#{
                        div(Vector#{ cls("admin-brand-name"), text("Weft Roasters") }),
                        div(Vector#{ cls("admin-brand-sub"), text("Merchant Backoffice") })
                    })
                })
            }),
            nav(Vector#{
                cls("admin-nav"),
                div(Vector#{ cls("admin-nav-section"), text("Store") }),
                a(Vector#{
                    cls("admin-nav-item"),
                    clsIf(activeNav == "overview", "active"),
                    href("/admin"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconHome(), spanText("Overview") })
                }),
                a(Vector#{
                    cls("admin-nav-item"),
                    clsIf(activeNav == "orders", "active"),
                    href("/admin/orders"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconOrders(), spanText("Orders") }),
                    when(pendingOrderCount > 0,
                        span(Vector#{ cls("admin-nav-count"), text("${pendingOrderCount}") })
                    )
                }),
                a(Vector#{
                    cls("admin-nav-item"),
                    clsIf(activeNav == "products", "active"),
                    href("/admin/products"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconBox(), spanText("Products") }),
                    span(Vector#{ cls("admin-nav-count"), text("${productCount}") })
                }),
                a(Vector#{
                    cls("admin-nav-item"),
                    clsIf(activeNav == "new-product", "active"),
                    href("/admin/products/new"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconPlus(), spanText("Add product") })
                }),
                when(lowStockCount > 0,
                    a(Vector#{
                        cls("admin-nav-item"),
                        clsIf(activeNav == "low-stock", "active"),
                        href("/admin/products?stock=low"),
                        div(Vector#{ cls("admin-nav-label"), Artwork.iconAlert(), spanText("Low stock") }),
                        span(Vector#{ cls("admin-nav-count alert"), text("${lowStockCount}") })
                    })
                ),
                div(Vector#{ cls("admin-nav-section"), text("Channels") }),
                a(Vector#{
                    cls("admin-nav-item"),
                    href("/"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconStore(), spanText("Online store") })
                }),
                a(Vector#{
                    cls("admin-nav-item"),
                    href("/health"),
                    div(Vector#{ cls("admin-nav-label"), Artwork.iconActivity(), spanText("System status") })
                })
            }),
            div(Vector#{
                cls("admin-sidebar-footer"),
                whenSome(userOpt, p ->
                    div(Vector#{
                        cls("admin-user-row"),
                        div(Vector#{
                            cls("admin-user-meta"),
                            div(Vector#{ cls("admin-user-name"), text(Principal.name(p)) }),
                            div(Vector#{ cls("admin-user-role"), text("Administrator") })
                        }),
                        form(Vector#{
                            method("post"),
                            action("/logout"),
                            csrfInput(csrfTok),
                            button(Vector#{ cls("admin-signout-btn"), type_("submit"), text("Log out") })
                        })
                    })
                )
            })
        })

    def adminTopbar(pageTitle: String): View =
        header(Vector#{
            cls("admin-topbar"),
            div(Vector#{
                cls("admin-topbar-left"),
                a(Vector#{ cls("admin-crumb"), href("/admin"), text("Weft Roasters") }),
                span(Vector#{ cls("admin-crumb-sep"), text("/") }),
                strongText(pageTitle)
            }),
            div(Vector#{
                cls("admin-topbar-actions"),
                a(Vector#{ cls("admin-btn-ghost"), href("/"), text("View store") }),
                a(Vector#{ cls("admin-btn-primary"), href("/admin/products/new"), text("Add product") })
            })
        })

    def siteHeader(csrfTok: String, userOpt: Option[Principal], cartCount: Int32): View =
        header(Vector#{
            cls("site-header"),
            div(Vector#{
                cls("container header-inner"),
                a(Vector#{
                    cls("brand"),
                    href("/"),
                    img("/static/brand-mark.svg", "Weft Roasters"),
                    span(Vector#{ cls("brand-wordmark"), text("Weft Roasters") })
                }),
                nav(Vector#{
                    cls("nav-links"),
                    link("/", "Shop"),
                    match userOpt {
                        case Some(p) =>
                            frag(Vector#{
                                link("/orders", "Orders"),
                                when(Principal.hasRole("admin", p), link("/admin", "Admin")),
                                span(Vector#{ cls("nav-user"), text("Hi, ${Principal.name(p)}") }),
                                form(Vector#{
                                    method("post"),
                                    action("/logout"),
                                    attr("style", "display:inline"),
                                    csrfInput(csrfTok),
                                    button(Vector#{ cls("nav-signout"), type_("submit"), text("Sign Out") })
                                })
                            })
                        case None =>
                            frag(Vector#{
                                link("/login", "Sign In"),
                                link("/register", "Register")
                            })
                    },
                    a(Vector#{
                        cls("cart-link"),
                        href("/cart"),
                        spanText("Bag"),
                        cartBadgeSpan(cartCount, false)
                    })
                })
            })
        })

    def siteFooter(): View =
        footer(Vector#{
            cls("site-footer"),
            div(Vector#{
                cls("container footer-inner"),
                div(Vector#{
                    cls("footer-brand"),
                    strongText("Weft Roasters"),
                    span(Vector#{ cls("muted"), text(" · Portland & Copenhagen · Small-batch coffee & precision brew ware.") })
                }),
                div(Vector#{
                    cls("footer-links"),
                    link("/", "Catalog"),
                    link("/cart", "Bag"),
                    link("/api/products", "Catalog API"),
                    link("/health", "Status")
                })
            })
        })

    ///
    /// Renders the live navbar cart count badge (optionally as an HTMX Out-Of-Band swap).
    ///
    pub def cartBadgeSpan(count: Int32, oob: Bool): View =
        span(Vector#{
            id("cart-badge"),
            cls("badge"),
            clsIf(count == 0, "empty"),
            attrIf(oob, "hx-swap-oob", "true"),
            text("${count}")
        })

    pub def cartBadgePartial(count: Int32): HtmlDoc =
        View.render(cartBadgeSpan(count, false))

    pub def textField(fieldName: String, labelText: String, fieldVal: String, errs: ValidationErrors): View =
        div(Vector#{
            cls("form-group"),
            label(Vector#{ for_(fieldName), text(labelText) }),
            input(Vector#{ id(fieldName), type_("text"), name(fieldName), value(fieldVal) }),
            ValidationErrors.fieldErrorView(fieldName, errs)
        })

    pub def statusChip(st: String): View =
        span(Vector#{
            cls("status-chip status-${st}"),
            text(st)
        })

}
