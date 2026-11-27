mod Features.Catalog.CatalogViews {
    use Shared.Artwork
    use Shared.Domain.{CatalogFilter, Product}
    use weft::Weft.Csrf
    use weft::Weft.HtmlDoc
    use weft::Weft.Page
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.Url
    use weft::Weft.View
    use weft::Weft.View.{
        a, action, attr, attrIf, button, cls, clsIf, disabled, div, each, form,
        frag, h1, h2Text, h3, href, hxGet, hxPost, hxSwap, hxTarget, hxTrigger,
        id, img, input, label, link, method, name, option, p, placeholder,
        section, select_, selected, span, spanText, strongText, text, type_,
        value, when
    }

    pub def catalogPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        filter: CatalogFilter,
        pg: Page[Product],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyView = frag(Vector#{
            renderEditorialMasthead(),
            renderFilterBar(filter),
            div(Vector#{
                id("product-grid-container"),
                renderProductGridInner(csrfTok, filter, pg)
            })
        });
        Shared.Layout.renderShell("Coffee & Brewing Equipment", csrfTok, userOpt, cartCount, flashOk, flashErr, bodyView)
    }

    pub def productGridPartial(filter: CatalogFilter, pg: Page[Product]): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        View.render(renderProductGridInner(csrfTok, filter, pg))
    }

    pub def productDetailPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        prod: Product,
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Shared.Layout.renderShell(
            prod#name,
            csrfTok,
            userOpt,
            cartCount,
            flashOk,
            flashErr,
            renderProductDetailBody(csrfTok, prod)
        )
    }

    // --- Editorial Masthead ---

    def renderEditorialMasthead(): View =
        section(Vector#{
            cls("masthead"),
            div(Vector#{
                cls("masthead-copy"),
                div(Vector#{ cls("masthead-kicker"), text("AUTUMN HARVEST · ISSUE 04") }),
                h1(Vector#{
                    text("Seasonal single-origin coffee & "),
                    span(Vector#{ cls("serif-italic"), text("precision brew ware.") })
                }),
                p(Vector#{
                    cls("masthead-lead"),
                    text("Washed and honey-processed micro-lots roasted every Tuesday and Friday, alongside tools built for quiet morning rituals.")
                })
            }),
            div(Vector#{
                cls("harvest-ledger"),
                div(Vector#{ cls("ledger-title"), text("ROASTERY LEDGER") }),
                ledgerRow("Roast schedule", "Tue & Fri · Shipped 24h"),
                ledgerRow("Featured lot", "Yirgacheffe Washed"),
                ledgerRow("Promo codes", "WELCOME10 · FREESHIP"),
                ledgerRow("Complimentary shipping", "Orders $75+")
            })
        })

    def ledgerRow(k: String, v: String): View =
        div(Vector#{
            cls("ledger-row"),
            span(Vector#{ cls("ledger-key"), text(k) }),
            span(Vector#{ cls("ledger-val"), text(v) })
        })

    // --- Underline Category Tabs & Search ---

    def renderFilterBar(filter: CatalogFilter): View = {
        let curCat = Option.getWithDefault("", filter#category);
        let curQ = Option.getWithDefault("", filter#search);
        form(Vector#{
            cls("filters-bar"),
            id("catalog-filters"),
            method("get"),
            action("/"),
            div(Vector#{
                cls("category-tabs"),
                renderCategoryTab("", "All", curCat, filter),
                each(Shared.Money.categories(), match (slug, title) ->
                    renderCategoryTab(slug, title, curCat, filter)
                )
            }),
            div(Vector#{
                cls("search-controls"),
                input(Vector#{
                    type_("hidden"),
                    name("category"),
                    id("filter-category"),
                    value(curCat)
                }),
                input(Vector#{
                    cls("search-input"),
                    type_("search"),
                    name("q"),
                    value(curQ),
                    placeholder("Search origin, gear, SKU…"),
                    hxGet("/products/grid"),
                    hxTrigger("keyup changed delay:250ms, search"),
                    hxTarget("#product-grid-container"),
                    attr("hx-include", "#catalog-filters")
                }),
                select_(Vector#{
                    cls("sort-select"),
                    name("sort"),
                    hxGet("/products/grid"),
                    hxTrigger("change"),
                    hxTarget("#product-grid-container"),
                    attr("hx-include", "#catalog-filters"),
                    sortOption("featured", "Featured", filter#sort),
                    sortOption("price_asc", "Price: Low to High", filter#sort),
                    sortOption("price_desc", "Price: High to Low", filter#sort),
                    sortOption("name_asc", "Alphabetical", filter#sort)
                }),
                button(Vector#{ cls("btn-secondary btn-sm"), type_("submit"), text("Apply") })
            })
        })
    }

    def renderCategoryTab(slug: String, title: String, curCat: String, filter: CatalogFilter): View = {
        let qs = buildGridQuery(
            filter#search,
            if (String.isEmpty(slug)) None else Some(slug),
            filter#sort,
            1
        );
        a(Vector#{
            cls("cat-tab"),
            clsIf(curCat == slug, "active"),
            href("/" + qs),
            hxGet("/products/grid" + qs),
            hxTarget("#product-grid-container"),
            text(title)
        })
    }

    def sortOption(valStr: String, labelText: String, activeSort: String): View =
        option(Vector#{
            value(valStr),
            when(activeSort == valStr, selected()),
            text(labelText)
        })

    // --- Gallery Product Grid ---

    def renderProductGridInner(csrfTok: String, filter: CatalogFilter, pg: Page[Product]): View = {
        let items = Page.items(pg);
        frag(Vector#{
            div(Vector#{
                cls("grid-meta"),
                span(Vector#{ cls("mono-meta"), text("Showing ${List.length(items)} of ${Page.totalItems(pg)} products") })
            }),
            if (List.isEmpty(items)) {
                div(Vector#{
                    cls("empty-catalog"),
                    h3(Vector#{ text("No products match those filters") }),
                    p(Vector#{ cls("muted"), text("Clear your search term or browse another category.") }),
                    a(Vector#{ cls("btn btn-secondary btn-sm"), href("/"), text("Reset catalog") })
                })
            } else {
                frag(Vector#{
                    div(Vector#{
                        cls("product-grid"),
                        each(items, prod -> renderProductCard(csrfTok, prod))
                    }),
                    when(Page.totalPages(pg) > 1, renderPagination(filter, pg))
                })
            }
        })
    }

    def renderProductCard(csrfTok: String, prod: Product): View =
        div(Vector#{
            cls("product-card"),
            a(Vector#{
                cls("product-media"),
                href("/products/${prod#slug}"),
                if (prod#hasImage)
                    img("/media/products/${prod#id}", prod#name)
                else
                    Artwork.productIllustration(prod)
            }),
            div(Vector#{
                cls("product-body"),
                div(Vector#{
                    cls("product-meta-row"),
                    span(Vector#{ cls("product-cat"), text(prod#category) }),
                    span(Vector#{ cls("product-sku"), text(prod#sku) })
                }),
                h3(Vector#{
                    cls("product-title"),
                    link("/products/${prod#slug}", prod#name)
                }),
                p(Vector#{ cls("product-desc"), text(prod#description) }),
                div(Vector#{
                    cls("product-foot"),
                    div(Vector#{
                        span(Vector#{ cls("price tabular"), text(Shared.Money.formatCents(prod#priceCents)) }),
                        renderStockLine(prod#stock)
                    }),
                    form(Vector#{
                        method("post"),
                        action("/cart/items"),
                        hxPost("/cart/items"),
                        hxTarget("#cart-badge"),
                        hxSwap("outerHTML"),
                        Shared.Layout.csrfInput(csrfTok),
                        input(Vector#{ type_("hidden"), name("product_id"), value("${prod#id}") }),
                        input(Vector#{ type_("hidden"), name("quantity"), value("1") }),
                        button(Vector#{
                            type_("submit"),
                            cls("btn-sm"),
                            when(prod#stock <= 0, disabled()),
                            text(if (prod#stock > 0) "Add to Bag" else "Sold Out")
                        })
                    })
                })
            })
        })

    def renderStockLine(stock: Int32): View =
        if (stock <= 0)
            div(Vector#{ cls("stock-line out"), text("Out of stock") })
        else if (stock <= 5)
            div(Vector#{ cls("stock-line low"), text("Only ${stock} remaining") })
        else
            div(Vector#{ cls("stock-line ok"), text("In stock") })

    def renderPagination(filter: CatalogFilter, pg: Page[Product]): View = {
        let cur = Page.page(pg);
        let tot = Page.totalPages(pg);
        div(Vector#{
            cls("pagination"),
            when(Page.hasPrev(pg), {
                let prevQs = buildGridQuery(filter#search, filter#category, filter#sort, cur - 1);
                a(Vector#{
                    cls("btn btn-secondary btn-sm"),
                    href("/" + prevQs),
                    hxGet("/products/grid" + prevQs),
                    hxTarget("#product-grid-container"),
                    text("← Previous")
                })
            }),
            span(Vector#{ cls("mono-meta"), text("Page ${cur} / ${tot}") }),
            when(Page.hasNext(pg), {
                let nextQs = buildGridQuery(filter#search, filter#category, filter#sort, cur + 1);
                a(Vector#{
                    cls("btn btn-secondary btn-sm"),
                    href("/" + nextQs),
                    hxGet("/products/grid" + nextQs),
                    hxTarget("#product-grid-container"),
                    text("Next →")
                })
            })
        })
    }

    // --- Editorial Product Detail Page ---

    def renderProductDetailBody(csrfTok: String, prod: Product): View =
        frag(Vector#{
            div(Vector#{
                cls("breadcrumb-bar"),
                link("/", "Shop"),
                span(Vector#{ cls("crumb-sep"), text("/") }),
                span(Vector#{ cls("muted"), text(prod#name) })
            }),
            div(Vector#{
                cls("detail-layout"),
                div(Vector#{
                    cls("detail-media"),
                    if (prod#hasImage)
                        img("/media/products/${prod#id}", prod#name)
                    else
                        Artwork.productIllustration(prod)
                }),
                div(Vector#{
                    cls("detail-info"),
                    div(Vector#{
                        cls("product-meta-row"),
                        span(Vector#{ cls("product-cat"), text(prod#category) }),
                        span(Vector#{ cls("product-sku"), text(prod#sku) })
                    }),
                    h1(Vector#{ cls("detail-title"), text(prod#name) }),
                    div(Vector#{
                        cls("detail-price-row"),
                        h2Text(Shared.Money.formatCents(prod#priceCents)),
                        renderStockLine(prod#stock)
                    }),
                    p(Vector#{ cls("detail-desc"), text(prod#description) }),
                    form(Vector#{
                        cls("detail-form"),
                        method("post"),
                        action("/cart/items"),
                        hxPost("/cart/items"),
                        hxTarget("#cart-badge"),
                        hxSwap("outerHTML"),
                        Shared.Layout.csrfInput(csrfTok),
                        input(Vector#{ type_("hidden"), name("product_id"), value("${prod#id}") }),
                        div(Vector#{
                            cls("detail-buy-row"),
                            div(Vector#{
                                cls("form-group"),
                                attr("style", "margin:0;width:96px"),
                                label(Vector#{ attr("for", "qty"), text("Qty") }),
                                input(Vector#{
                                    id("qty"),
                                    type_("number"),
                                    name("quantity"),
                                    value("1"),
                                    attr("min", "1"),
                                    attrIf(prod#stock > 0, "max", "${prod#stock}")
                                })
                            }),
                            button(Vector#{
                                cls("btn-buy"),
                                type_("submit"),
                                when(prod#stock <= 0, disabled()),
                                text(if (prod#stock > 0) "Add to Bag" else "Sold Out")
                            })
                        })
                    }),
                    div(Vector#{
                        cls("detail-specs"),
                        div(Vector#{ cls("spec-row"), spanText("SKU"), strongText(prod#sku) }),
                        div(Vector#{ cls("spec-row"), spanText("Availability"), strongText("${prod#stock} units ready") }),
                        div(Vector#{ cls("spec-row"), spanText("Shipping"), strongText("Free over $75 · $8 flat") })
                    })
                })
            })
        })

    def buildGridQuery(q: Option[String], cat: Option[String], sort: String, pageNum: Int32): String = {
        let p1 = match q {
            case Some(s) if not String.isEmpty(String.trim(s)) => ("q", String.trim(s)) :: Nil
            case _ => Nil
        };
        let p2 = match cat {
            case Some(c) if not String.isEmpty(String.trim(c)) => ("category", String.trim(c)) :: Nil
            case _ => Nil
        };
        let p3 = if (sort != "featured") ("sort", sort) :: Nil else Nil;
        let p4 = if (pageNum > 1) ("page", "${pageNum}") :: Nil else Nil;
        let all = List.flatten(p1 :: p2 :: p3 :: p4 :: Nil);
        if (List.isEmpty(all)) "" else "?" + Url.encodeQuery(all)
    }

}
