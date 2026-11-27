mod Features.Checkout.CheckoutViews {
    use Features.Cart.CartSummary
    use Features.Checkout.{CheckoutInput, Order, OrderItem}
    use weft::Weft.Csrf
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, attr, button, cls, div, each, form, h1Text, h2Text, h3, href,
        link, method, p, pText, raw, spanText, strongText, table, tbody, td,
        tdText, text, thText, thead, tr, type_, when, whenSome
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.ValidationErrors

    pub def checkoutPage(
        userOpt: Option[Principal],
        summary: CartSummary,
        inputVals: CheckoutInput,
        errs: ValidationErrors,
        conflictErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let formHtml = Html.renderString(() -> renderCheckoutForm(csrfTok, summary#totalCents, inputVals, errs));
        let summaryHtml = Html.renderString(() -> renderCheckoutSummary(summary));
        let bodyHtml = Html.renderString(() -> {
            h1Text("Checkout");
            whenSome(conflictErr, msg -> div(() -> { cls("flash flash-err"); text(msg) }));
            div(() -> {
                cls("two-col");
                raw(formHtml);
                raw(summaryHtml)
            })
        });
        Shared.Layout.renderShell("Checkout", csrfTok, userOpt, summary#itemCount, None, None, bodyHtml)
    }

    pub def orderReceiptPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        order: Order,
        items: List[OrderItem],
        flashOk: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyHtml = Html.renderString(() -> renderReceiptBody(order, items));
        Shared.Layout.renderShell("Order ${order#orderNumber}", csrfTok, userOpt, cartCount, flashOk, None, bodyHtml)
    }

    pub def ordersHistoryPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        orders: List[Order]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyHtml = Html.renderString(() -> renderOrdersHistoryBody(orders));
        Shared.Layout.renderShell("Your Orders", csrfTok, userOpt, cartCount, None, None, bodyHtml)
    }

    // --- Pure HTML Sections ---

    def renderCheckoutForm(
        csrfTok: String,
        totalCents: Int64,
        inputVals: CheckoutInput,
        errs: ValidationErrors
    ): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Shipping Address");
            form(() -> {
                method("post");
                action("/checkout");
                Shared.Layout.csrfInput(csrfTok);
                Shared.Layout.textField("shipping_name", "Full Name", inputVals#shippingName, errs);
                Shared.Layout.textField("address", "Street Address", inputVals#address, errs);
                div(() -> {
                    cls("form-row");
                    Shared.Layout.textField("city", "City", inputVals#city, errs);
                    Shared.Layout.textField("postal_code", "Postal Code", inputVals#postalCode, errs)
                });
                Shared.Layout.textField("country", "Country", inputVals#country, errs);
                button(() -> {
                    type_("submit");
                    attr("style", "width:100%;margin-top:0.5rem");
                    text("Place Order · ${Shared.Money.formatCents(totalCents)}")
                })
            })
        })

    def renderCheckoutSummary(summary: CartSummary): Unit \ Html =
        div(() -> {
            cls("panel");
            h2Text("Order Summary");
            each(summary#lines, line ->
                div(() -> {
                    cls("summary-line");
                    spanText("${line#quantity}× ${line#name}");
                    spanText(Shared.Money.formatCents(line#lineTotalCents))
                })
            );
            div(() -> {
                cls("summary-line");
                attr("style", "border-top:1px solid var(--border);padding-top:0.65rem;margin-top:0.65rem");
                spanText("Subtotal");
                spanText(Shared.Money.formatCents(summary#subtotalCents))
            });
            when(summary#discountCents > 0i64, () ->
                div(() -> {
                    cls("summary-line");
                    spanText("Discount");
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
            })
        })

    def renderReceiptBody(order: Order, items: List[OrderItem]): Unit \ Html = {
        p(() -> link("/orders", "← Back to Order History"));
        div(() -> {
            cls("panel");
            div(() -> {
                attr("style", "display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:0.5rem");
                h1Text("Order ${order#orderNumber}");
                Shared.Layout.statusChip(order#status)
            });
            p(() -> {
                cls("muted");
                text("Placed on ${order#createdAt} · Shipping to ${order#shippingName}, ${order#address}, ${order#city} ${order#postalCode}, ${order#country}")
            });
            table(() -> {
                thead(() -> tr(() -> {
                    thText("Item");
                    thText("SKU");
                    thText("Qty");
                    thText("Unit");
                    thText("Line Total")
                }));
                tbody(() ->
                    each(items, it ->
                        tr(() -> {
                            tdText(it#productName);
                            tdText(it#sku);
                            tdText("${it#quantity}");
                            tdText(Shared.Money.formatCents(it#unitCents));
                            td(() -> strongText(Shared.Money.formatCents(it#lineTotalCents)))
                        })
                    )
                )
            });
            div(() -> {
                attr("style", "max-width:320px;margin-left:auto;margin-top:1.25rem");
                div(() -> { cls("summary-line"); spanText("Subtotal"); spanText(Shared.Money.formatCents(order#subtotalCents)) });
                when(order#discountCents > 0i64, () ->
                    div(() -> { cls("summary-line"); spanText("Discount"); spanText("-" + Shared.Money.formatCents(order#discountCents)) })
                );
                div(() -> {
                    cls("summary-line");
                    spanText("Shipping");
                    spanText(if (order#shippingCents == 0i64) "FREE" else Shared.Money.formatCents(order#shippingCents))
                });
                div(() -> {
                    cls("summary-line summary-total");
                    spanText("Total Paid");
                    spanText(Shared.Money.formatCents(order#totalCents))
                })
            })
        })
    }

    def renderOrdersHistoryBody(orders: List[Order]): Unit \ Html = {
        h1Text("Order History");
        if (List.isEmpty(orders)) {
            div(() -> {
                cls("panel");
                h3(() -> text("No orders yet"));
                pText("When you place an order, your receipts and shipping status will appear here.");
                a(() -> { cls("btn"); href("/"); text("Start Shopping") })
            })
        } else {
            div(() -> {
                cls("panel");
                table(() -> {
                    thead(() -> tr(() -> {
                        thText("Order #");
                        thText("Date");
                        thText("Status");
                        thText("Total");
                        thText("")
                    }));
                    tbody(() ->
                        each(orders, o ->
                            tr(() -> {
                                td(() -> strongText(o#orderNumber));
                                tdText(o#createdAt);
                                td(() -> Shared.Layout.statusChip(o#status));
                                tdText(Shared.Money.formatCents(o#totalCents));
                                td(() -> link("/orders/${o#id}", "View Receipt →"))
                            })
                        )
                    )
                })
            })
        }
    }

}
