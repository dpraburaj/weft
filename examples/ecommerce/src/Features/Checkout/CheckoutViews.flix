mod Features.Checkout.CheckoutViews {
    use Shared.Domain.{CartSummary, CheckoutInput, Order, OrderItem}
    use weft::Weft.Csrf
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.ValidationErrors
    use weft::Weft.View
    use weft::Weft.View.{
        a, action, attr, button, cls, div, each, form, frag, h1Text, h2Text,
        h3, href, link, method, p, pText, spanText, strongText, table, tbody,
        td, tdText, text, thText, thead, tr, type_, when, whenSome
    }

    pub def checkoutPage(
        userOpt: Option[Principal],
        summary: CartSummary,
        inputVals: CheckoutInput,
        errs: ValidationErrors,
        conflictErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyView = frag(Vector#{
            h1Text("Checkout"),
            whenSome(conflictErr, msg -> div(Vector#{ cls("flash flash-err"), text(msg) })),
            div(Vector#{
                cls("two-col"),
                renderCheckoutForm(csrfTok, summary#totalCents, inputVals, errs),
                renderCheckoutSummary(summary)
            })
        });
        Shared.Layout.renderShell("Checkout", csrfTok, userOpt, summary#itemCount, None, None, bodyView)
    }

    pub def orderReceiptPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        order: Order,
        items: List[OrderItem],
        flashOk: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Shared.Layout.renderShell("Order ${order#orderNumber}", csrfTok, userOpt, cartCount, flashOk, None, renderReceiptBody(order, items))
    }

    pub def ordersHistoryPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        orders: List[Order]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Shared.Layout.renderShell("Your Orders", csrfTok, userOpt, cartCount, None, None, renderOrdersHistoryBody(orders))
    }

    // --- Pure View Sections ---

    def renderCheckoutForm(
        csrfTok: String,
        totalCents: Int64,
        inputVals: CheckoutInput,
        errs: ValidationErrors
    ): View =
        div(Vector#{
            cls("panel"),
            h2Text("Shipping Address"),
            form(Vector#{
                method("post"),
                action("/checkout"),
                Shared.Layout.csrfInput(csrfTok),
                Shared.Layout.textField("shipping_name", "Full Name", inputVals#shippingName, errs),
                Shared.Layout.textField("address", "Street Address", inputVals#address, errs),
                div(Vector#{
                    cls("form-row"),
                    Shared.Layout.textField("city", "City", inputVals#city, errs),
                    Shared.Layout.textField("postal_code", "Postal Code", inputVals#postalCode, errs)
                }),
                Shared.Layout.textField("country", "Country", inputVals#country, errs),
                button(Vector#{
                    type_("submit"),
                    attr("style", "width:100%;margin-top:0.5rem"),
                    text("Place Order · ${Shared.Money.formatCents(totalCents)}")
                })
            })
        })

    def renderCheckoutSummary(summary: CartSummary): View =
        div(Vector#{
            cls("panel"),
            h2Text("Order Summary"),
            each(summary#lines, line ->
                div(Vector#{
                    cls("summary-line"),
                    spanText("${line#quantity}× ${line#name}"),
                    spanText(Shared.Money.formatCents(line#lineTotalCents))
                })
            ),
            div(Vector#{
                cls("summary-line"),
                attr("style", "border-top:1px solid var(--border);padding-top:0.65rem;margin-top:0.65rem"),
                spanText("Subtotal"),
                spanText(Shared.Money.formatCents(summary#subtotalCents))
            }),
            when(summary#discountCents > 0i64,
                div(Vector#{
                    cls("summary-line"),
                    spanText("Discount"),
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
            })
        })

    def renderReceiptBody(order: Order, items: List[OrderItem]): View =
        frag(Vector#{
            p(Vector#{ link("/orders", "← Back to Order History") }),
            div(Vector#{
                cls("panel"),
                div(Vector#{
                    attr("style", "display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:0.5rem"),
                    h1Text("Order ${order#orderNumber}"),
                    Shared.Layout.statusChip(order#status)
                }),
                p(Vector#{
                    cls("muted"),
                    text("Placed on ${order#createdAt} · Shipping to ${order#shippingName}, ${order#address}, ${order#city} ${order#postalCode}, ${order#country}")
                }),
                table(Vector#{
                    thead(Vector#{ tr(Vector#{
                        thText("Item"),
                        thText("SKU"),
                        thText("Qty"),
                        thText("Unit"),
                        thText("Line Total")
                    }) }),
                    tbody(Vector#{
                        each(items, it ->
                            tr(Vector#{
                                tdText(it#productName),
                                tdText(it#sku),
                                tdText("${it#quantity}"),
                                tdText(Shared.Money.formatCents(it#unitCents)),
                                td(Vector#{ strongText(Shared.Money.formatCents(it#lineTotalCents)) })
                            })
                        )
                    })
                }),
                div(Vector#{
                    attr("style", "max-width:320px;margin-left:auto;margin-top:1.25rem"),
                    div(Vector#{ cls("summary-line"), spanText("Subtotal"), spanText(Shared.Money.formatCents(order#subtotalCents)) }),
                    when(order#discountCents > 0i64,
                        div(Vector#{ cls("summary-line"), spanText("Discount"), spanText("-" + Shared.Money.formatCents(order#discountCents)) })
                    ),
                    div(Vector#{
                        cls("summary-line"),
                        spanText("Shipping"),
                        spanText(if (order#shippingCents == 0i64) "FREE" else Shared.Money.formatCents(order#shippingCents))
                    }),
                    div(Vector#{
                        cls("summary-line summary-total"),
                        spanText("Total Paid"),
                        spanText(Shared.Money.formatCents(order#totalCents))
                    })
                })
            })
        })

    def renderOrdersHistoryBody(orders: List[Order]): View =
        frag(Vector#{
            h1Text("Order History"),
            if (List.isEmpty(orders)) {
                div(Vector#{
                    cls("panel"),
                    h3(Vector#{ text("No orders yet") }),
                    pText("When you place an order, your receipts and shipping status will appear here."),
                    a(Vector#{ cls("btn"), href("/"), text("Start Shopping") })
                })
            } else {
                div(Vector#{
                    cls("panel"),
                    table(Vector#{
                        thead(Vector#{ tr(Vector#{
                            thText("Order #"),
                            thText("Date"),
                            thText("Status"),
                            thText("Total"),
                            thText("")
                        }) }),
                        tbody(Vector#{
                            each(orders, o ->
                                tr(Vector#{
                                    td(Vector#{ strongText(o#orderNumber) }),
                                    tdText(o#createdAt),
                                    td(Vector#{ Shared.Layout.statusChip(o#status) }),
                                    tdText(Shared.Money.formatCents(o#totalCents)),
                                    td(Vector#{ link("/orders/${o#id}", "View Receipt →") })
                                })
                            )
                        })
                    })
                })
            }
        })

}
