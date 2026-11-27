mod Features.Cart.CartViews {
    use Features.Cart.{CartLine, CartSummary}
    use weft::Weft.Csrf
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, attr, button, cls, div, each, form, h1Text, h2Text, h3, href,
        hxDelete, hxPost, hxSwap, hxTarget, id, input, link, method, name, p,
        pText, placeholder, raw, spanText, strongText, table, tbody, td, tdText,
        text, thText, thead, tr, type_, value, when, whenSome
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session

    pub def cartPage(
        userOpt: Option[Principal],
        summary: CartSummary,
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let panelHtml = renderCartPanelHtml(csrfTok, summary, None, None, false);
        let bodyHtml = Html.renderString(() -> {
            h1Text("Your Cart");
            div(() -> {
                id("cart-panel");
                raw(panelHtml)
            })
        });
        Shared.Layout.renderShell("Your Cart", csrfTok, userOpt, summary#itemCount, flashOk, flashErr, bodyHtml)
    }

    pub def cartPanelPartial(
        summary: CartSummary,
        noticeOk: Option[String],
        noticeErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Html.render(() -> raw(renderCartPanelHtml(csrfTok, summary, noticeOk, noticeErr, true)))
    }

    // --- Pure HTML Sections (split to keep JVM method frames compact) ---

    def renderCartPanelHtml(
        csrfTok: String,
        summary: CartSummary,
        noticeOk: Option[String],
        noticeErr: Option[String],
        includeOobBadge: Bool
    ): String = {
        let leftHtml = Html.renderString(() -> renderCartLinesPanel(csrfTok, summary#lines));
        let rightHtml = Html.renderString(() -> renderCartSummaryPanel(csrfTok, summary));
        Html.renderString(() -> {
            when(includeOobBadge, () -> Shared.Layout.cartBadgeSpan(summary#itemCount, true));
            whenSome(noticeOk, msg -> div(() -> { cls("flash flash-ok"); text(msg) }));
            whenSome(noticeErr, msg -> div(() -> { cls("flash flash-err"); text(msg) }));
            if (List.isEmpty(summary#lines)) {
                div(() -> {
                    cls("panel");
                    h3(() -> text("Your cart is empty"));
                    p(() -> { cls("muted"); text("Explore our freshly roasted coffee and brewing gear.") });
                    a(() -> { cls("btn"); href("/"); text("Browse Catalog") })
                })
            } else {
                div(() -> {
                    cls("two-col");
                    raw(leftHtml);
                    raw(rightHtml)
                })
            }
        })
    }

    def renderCartLinesPanel(csrfTok: String, lines: List[CartLine]): Unit \ Html =
        div(() -> {
            cls("panel");
            table(() -> {
                thead(() -> tr(() -> {
                    thText("Item");
                    thText("Unit Price");
                    thText("Quantity");
                    thText("Subtotal");
                    thText("")
                }));
                tbody(() -> each(lines, line -> renderCartRow(csrfTok, line)))
            })
        })

    def renderCartRow(csrfTok: String, line: CartLine): Unit \ Html =
        tr(() -> {
            td(() -> {
                link("/products/${line#slug}", line#name);
                div(() -> { cls("muted"); attr("style", "font-size:0.8rem"); text("SKU: ${line#sku}") })
            });
            tdText(Shared.Money.formatCents(line#unitCents));
            td(() ->
                div(() -> {
                    cls("qty-box");
                    form(() -> {
                        method("post");
                        action("/cart/items/${line#productId}/qty");
                        hxPost("/cart/items/${line#productId}/qty");
                        hxTarget("#cart-panel");
                        hxSwap("innerHTML");
                        Shared.Layout.csrfInput(csrfTok);
                        input(() -> { type_("hidden"); name("quantity"); value("${line#quantity - 1}") });
                        button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("−") })
                    });
                    strongText("${line#quantity}");
                    form(() -> {
                        method("post");
                        action("/cart/items/${line#productId}/qty");
                        hxPost("/cart/items/${line#productId}/qty");
                        hxTarget("#cart-panel");
                        hxSwap("innerHTML");
                        Shared.Layout.csrfInput(csrfTok);
                        input(() -> { type_("hidden"); name("quantity"); value("${line#quantity + 1}") });
                        button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("+") })
                    })
                })
            );
            td(() -> strongText(Shared.Money.formatCents(line#lineTotalCents)));
            td(() ->
                form(() -> {
                    method("post");
                    action("/cart/items/${line#productId}/remove");
                    hxDelete("/cart/items/${line#productId}");
                    hxTarget("#cart-panel");
                    hxSwap("innerHTML");
                    Shared.Layout.csrfInput(csrfTok);
                    button(() -> { cls("btn-danger btn-sm"); type_("submit"); text("Remove") })
                })
            )
        })

    def renderCartSummaryPanel(csrfTok: String, summary: CartSummary): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Order Summary");
            div(() -> {
                cls("summary-line");
                spanText("Subtotal (${summary#itemCount} items)");
                spanText(Shared.Money.formatCents(summary#subtotalCents))
            });
            when(summary#discountCents > 0i64, () ->
                div(() -> {
                    cls("summary-line");
                    spanText("Promo Discount");
                    spanText("-" + Shared.Money.formatCents(summary#discountCents))
                })
            );
            div(() -> {
                cls("summary-line");
                spanText("Shipping");
                spanText(if (summary#shippingCents == 0i64) "FREE" else Shared.Money.formatCents(summary#shippingCents))
            });
            div(() -> {
                cls("summary-line summary-total");
                spanText("Total");
                spanText(Shared.Money.formatCents(summary#totalCents))
            });
            form(() -> {
                method("post");
                action("/cart/promo");
                hxPost("/cart/promo");
                hxTarget("#cart-panel");
                hxSwap("innerHTML");
                attr("style", "margin:1rem 0;display:flex;gap:0.5rem");
                Shared.Layout.csrfInput(csrfTok);
                input(() -> {
                    type_("text");
                    name("code");
                    placeholder("Promo code (WELCOME10)");
                    value(match summary#promo { case Some(pr) => pr#code case None => "" });
                    attr("style", "flex:1")
                });
                button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("Apply") })
            });
            whenSome(summary#promo, pr ->
                p(() -> { cls("muted"); attr("style", "font-size:0.85rem"); text("Applied: ${pr#code} — ${pr#description}") })
            );
            a(() -> {
                cls("btn");
                href("/checkout");
                attr("style", "width:100%;margin-top:0.5rem");
                text("Proceed to Checkout")
            })
        })

}
