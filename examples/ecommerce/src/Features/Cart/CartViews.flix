mod Features.Cart.CartViews {
    use Shared.Domain.{CartLine, CartSummary}
    use weft::Weft.Csrf
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.View
    use weft::Weft.View.{
        a, action, attr, button, cls, div, each, form, frag, h1Text, h2Text,
        h3, href, hxDelete, hxPost, hxSwap, hxTarget, id, input, link, method,
        name, p, placeholder, spanText, strongText, table, tbody, td, tdText,
        text, thText, thead, tr, type_, value, when, whenSome
    }

    pub def cartPage(
        userOpt: Option[Principal],
        summary: CartSummary,
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyView = frag(Vector#{
            h1Text("Your Cart"),
            div(Vector#{
                id("cart-panel"),
                renderCartPanel(csrfTok, summary, None, None, false)
            })
        });
        Shared.Layout.renderShell("Your Cart", csrfTok, userOpt, summary#itemCount, flashOk, flashErr, bodyView)
    }

    pub def cartPanelPartial(
        summary: CartSummary,
        noticeOk: Option[String],
        noticeErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        View.render(renderCartPanel(csrfTok, summary, noticeOk, noticeErr, true))
    }

    // --- Pure View Sections ---

    def renderCartPanel(
        csrfTok: String,
        summary: CartSummary,
        noticeOk: Option[String],
        noticeErr: Option[String],
        includeOobBadge: Bool
    ): View =
        frag(Vector#{
            when(includeOobBadge, Shared.Layout.cartBadgeSpan(summary#itemCount, true)),
            whenSome(noticeOk, msg -> div(Vector#{ cls("flash flash-ok"), text(msg) })),
            whenSome(noticeErr, msg -> div(Vector#{ cls("flash flash-err"), text(msg) })),
            if (List.isEmpty(summary#lines)) {
                div(Vector#{
                    cls("panel"),
                    h3(Vector#{ text("Your cart is empty") }),
                    p(Vector#{ cls("muted"), text("Explore our freshly roasted coffee and brewing gear.") }),
                    a(Vector#{ cls("btn"), href("/"), text("Browse Catalog") })
                })
            } else {
                div(Vector#{
                    cls("two-col"),
                    renderCartLinesPanel(csrfTok, summary#lines),
                    renderCartSummaryPanel(csrfTok, summary)
                })
            }
        })

    def renderCartLinesPanel(csrfTok: String, lines: List[CartLine]): View =
        div(Vector#{
            cls("panel"),
            table(Vector#{
                thead(Vector#{ tr(Vector#{
                    thText("Item"),
                    thText("Unit Price"),
                    thText("Quantity"),
                    thText("Subtotal"),
                    thText("")
                }) }),
                tbody(Vector#{ each(lines, line -> renderCartRow(csrfTok, line)) })
            })
        })

    def renderCartRow(csrfTok: String, line: CartLine): View =
        tr(Vector#{
            td(Vector#{
                link("/products/${line#slug}", line#name),
                div(Vector#{ cls("muted"), attr("style", "font-size:0.8rem"), text("SKU: ${line#sku}") })
            }),
            tdText(Shared.Money.formatCents(line#unitCents)),
            td(Vector#{
                div(Vector#{
                    cls("qty-box"),
                    form(Vector#{
                        method("post"),
                        action("/cart/items/${line#productId}/qty"),
                        hxPost("/cart/items/${line#productId}/qty"),
                        hxTarget("#cart-panel"),
                        hxSwap("innerHTML"),
                        Shared.Layout.csrfInput(csrfTok),
                        input(Vector#{ type_("hidden"), name("quantity"), value("${line#quantity - 1}") }),
                        button(Vector#{ cls("btn-secondary btn-sm"), type_("submit"), text("−") })
                    }),
                    strongText("${line#quantity}"),
                    form(Vector#{
                        method("post"),
                        action("/cart/items/${line#productId}/qty"),
                        hxPost("/cart/items/${line#productId}/qty"),
                        hxTarget("#cart-panel"),
                        hxSwap("innerHTML"),
                        Shared.Layout.csrfInput(csrfTok),
                        input(Vector#{ type_("hidden"), name("quantity"), value("${line#quantity + 1}") }),
                        button(Vector#{ cls("btn-secondary btn-sm"), type_("submit"), text("+") })
                    })
                })
            }),
            td(Vector#{ strongText(Shared.Money.formatCents(line#lineTotalCents)) }),
            td(Vector#{
                form(Vector#{
                    method("post"),
                    action("/cart/items/${line#productId}/remove"),
                    hxDelete("/cart/items/${line#productId}"),
                    hxTarget("#cart-panel"),
                    hxSwap("innerHTML"),
                    Shared.Layout.csrfInput(csrfTok),
                    button(Vector#{ cls("btn-danger btn-sm"), type_("submit"), text("Remove") })
                })
            })
        })

    def renderCartSummaryPanel(csrfTok: String, summary: CartSummary): View =
        div(Vector#{
            cls("panel"),
            h2Text("Order Summary"),
            div(Vector#{
                cls("summary-line"),
                spanText("Subtotal (${summary#itemCount} items)"),
                spanText(Shared.Money.formatCents(summary#subtotalCents))
            }),
            when(summary#discountCents > 0i64,
                div(Vector#{
                    cls("summary-line"),
                    spanText("Promo Discount"),
                    spanText("-" + Shared.Money.formatCents(summary#discountCents))
                })
            ),
            div(Vector#{
                cls("summary-line"),
                spanText("Shipping"),
                spanText(if (summary#shippingCents == 0i64) "FREE" else Shared.Money.formatCents(summary#shippingCents))
            }),
            div(Vector#{
                cls("summary-line summary-total"),
                spanText("Total"),
                spanText(Shared.Money.formatCents(summary#totalCents))
            }),
            form(Vector#{
                method("post"),
                action("/cart/promo"),
                hxPost("/cart/promo"),
                hxTarget("#cart-panel"),
                hxSwap("innerHTML"),
                attr("style", "margin:1rem 0;display:flex;gap:0.5rem"),
                Shared.Layout.csrfInput(csrfTok),
                input(Vector#{
                    type_("text"),
                    name("code"),
                    placeholder("Promo code (WELCOME10)"),
                    value(match summary#promo { case Some(pr) => pr#code case None => "" }),
                    attr("style", "flex:1")
                }),
                button(Vector#{ cls("btn-secondary btn-sm"), type_("submit"), text("Apply") })
            }),
            whenSome(summary#promo, pr ->
                p(Vector#{ cls("muted"), attr("style", "font-size:0.85rem"), text("Applied: ${pr#code} — ${pr#description}") })
            ),
            a(Vector#{
                cls("btn"),
                href("/checkout"),
                attr("style", "width:100%;margin-top:0.5rem"),
                text("Proceed to Checkout")
            })
        })

}
