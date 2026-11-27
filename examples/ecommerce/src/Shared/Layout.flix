pub mod Shared.Layout {
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, attr, attrIf, button, cls, clsIf, div, footer, for_, form,
        header, href, id, img, input, label, link, main_, meta, method, name,
        nav, raw, script, scriptSrc, span, spanText, stylesheet, text, type_,
        value, when, whenSome
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

    ///
    /// Shared page shell accepting pre-rendered `bodyHtml` so each vertical slice
    /// renders its own markup cleanly without duplicating or inlining the page shell.
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
            "${pageTitle} · Weft Roasters",
            () -> {
                stylesheet("/static/styles.css");
                meta("csrf-token", csrfTok);
                scriptSrc("https://unpkg.com/htmx.org@2.0.4");
                script(() -> raw(
                    "document.addEventListener('htmx:configRequest',function(e){" +
                    "var m=document.querySelector('meta[name=\"csrf-token\"]');" +
                    "if(m){e.detail.headers['X-CSRF-Token']=m.getAttribute('content');}" +
                    "});"
                ))
            },
            () -> {
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

    def siteHeader(csrfTok: String, userOpt: Option[Principal], cartCount: Int32): Unit \ Html =
        header(() -> {
            cls("site-header");
            div(() -> {
                cls("container header-inner");
                a(() -> {
                    cls("brand");
                    href("/");
                    img("/static/brand-mark.svg", "Weft Roasters");
                    spanText("Weft Roasters")
                });
                nav(() -> {
                    cls("nav-links");
                    link("/", "Shop");
                    match userOpt {
                        case Some(p) =>
                            link("/orders", "Orders");
                            when(Principal.hasRole("admin", p), () -> link("/admin", "Admin"));
                            span(() -> { cls("muted"); text("Hi, ${Principal.name(p)}") });
                            form(() -> {
                                method("post");
                                action("/logout");
                                attr("style", "display:inline");
                                csrfInput(csrfTok);
                                button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("Sign Out") })
                            })
                        case None =>
                            link("/login", "Sign In");
                            link("/register", "Register")
                    };
                    a(() -> {
                        cls("cart-link");
                        href("/cart");
                        text("Cart");
                        cartBadgeSpan(cartCount, false)
                    })
                })
            })
        })

    def siteFooter(): Unit \ Html =
        footer(() -> {
            cls("site-footer");
            div(() -> {
                cls("container");
                text("Weft Roasters — Built with Flix, Weft algebraic effects, SQLite, SSR HTML & HTMX. ");
                link("/api/products", "JSON Catalog API")
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
