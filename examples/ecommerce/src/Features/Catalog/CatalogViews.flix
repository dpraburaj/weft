mod Features.Catalog.CatalogViews {
    use Features.Catalog.{CatalogFilter, Product}
    use weft::Weft.Csrf
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, attr, attrIf, button, cls, clsIf, disabled, div, each, form,
        h1, h1Text, h2Text, h3, href, hxGet, hxPost, hxSwap, hxTarget, hxTrigger,
        id, img, input, label, link, method, name, option, p, pText, placeholder,
        raw, section, select_, selected, span, spanText, text, type_, value, when
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Page
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.Url

    pub def catalogPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        filter: CatalogFilter,
        pg: Page[Product],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let gridHtml = Html.renderString(() -> renderProductGridInner(csrfTok, filter, pg));
        let bodyHtml = Html.renderString(() -> {
            renderHero();
            renderFilterBar(filter);
            div(() -> {
                id("product-grid-container");
                raw(gridHtml)
            })
        });
        Shared.Layout.renderShell("Shop Specialty Coffee & Gear", csrfTok, userOpt, cartCount, flashOk, flashErr, bodyHtml)
    }

    pub def productGridPartial(filter: CatalogFilter, pg: Page[Product]): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Html.render(() -> renderProductGridInner(csrfTok, filter, pg))
    }

    pub def productDetailPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        prod: Product,
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyHtml = Html.renderString(() -> renderProductDetailBody(csrfTok, prod));
        Shared.Layout.renderShell(prod#name, csrfTok, userOpt, cartCount, flashOk, flashErr, bodyHtml)
    }

    // --- Pure HTML Sections ---

    def renderHero(): Unit \ Html =
        section(() -> {
            cls("hero");
            div(() -> {
                span(() -> { cls("hero-pill"); text("Small-Batch Roastery & Precision Gear") });
                h1Text("Freshly roasted single-origin coffee & precision brewers");
                pText("Use promo code WELCOME10 for 10% off or FREESHIP for complimentary shipping. Free shipping automatically over $75.")
            })
        })

    def renderFilterBar(filter: CatalogFilter): Unit \ Html = {
        let curCat = Option.getWithDefault("", filter#category);
        let curQ = Option.getWithDefault("", filter#search);
        form(() -> {
            cls("filters-bar");
            id("catalog-filters");
            method("get");
            action("/");
            div(() -> {
                cls("category-pills");
                renderCategoryPill("", "All", curCat, filter);
                each(Shared.Money.categories(), match (slug, title) ->
                    renderCategoryPill(slug, title, curCat, filter)
                )
            });
            div(() -> {
                cls("search-controls");
                input(() -> {
                    type_("hidden");
                    name("category");
                    id("filter-category");
                    value(curCat)
                });
                input(() -> {
                    type_("search");
                    name("q");
                    value(curQ);
                    placeholder("Search coffee, grinders, SKUs...");
                    hxGet("/products/grid");
                    hxTrigger("keyup changed delay:250ms, search");
                    hxTarget("#product-grid-container");
                    attr("hx-include", "#catalog-filters")
                });
                select_(() -> {
                    name("sort");
                    hxGet("/products/grid");
                    hxTrigger("change");
                    hxTarget("#product-grid-container");
                    attr("hx-include", "#catalog-filters");
                    sortOption("featured", "Featured", filter#sort);
                    sortOption("price_asc", "Price: Low to High", filter#sort);
                    sortOption("price_desc", "Price: High to Low", filter#sort);
                    sortOption("name_asc", "Name: A–Z", filter#sort)
                });
                button(() -> { cls("btn-secondary btn-sm"); type_("submit"); text("Filter") })
            })
        })
    }

    def renderCategoryPill(slug: String, title: String, curCat: String, filter: CatalogFilter): Unit \ Html = {
        let qs = buildGridQuery(
            filter#search,
            if (String.isEmpty(slug)) None else Some(slug),
            filter#sort,
            1
        );
        a(() -> {
            cls("pill");
            clsIf(curCat == slug, "active");
            href("/" + qs);
            hxGet("/products/grid" + qs);
            hxTarget("#product-grid-container");
            text(title)
        })
    }

    def sortOption(valStr: String, labelText: String, activeSort: String): Unit \ Html =
        option(() -> {
            value(valStr);
            when(activeSort == valStr, () -> selected());
            text(labelText)
        })

    def renderProductGridInner(csrfTok: String, filter: CatalogFilter, pg: Page[Product]): Unit \ Html = {
        let items = Page.items(pg);
        p(() -> {
            cls("muted");
            text("Showing ${List.length(items)} of ${Page.totalItems(pg)} products")
        });
        if (List.isEmpty(items)) {
            div(() -> {
                cls("panel");
                h3(() -> text("No products match your filters"));
                p(() -> { cls("muted"); text("Try clearing the search query or switching categories.") })
            })
        } else {
            div(() -> {
                cls("product-grid");
                each(items, prod -> renderProductCard(csrfTok, prod))
            });
            when(Page.totalPages(pg) > 1, () -> renderPagination(filter, pg))
        }
    }

    def renderProductCard(csrfTok: String, prod: Product): Unit \ Html =
        div(() -> {
            cls("card");
            div(() -> {
                cls("product-thumb");
                if (prod#hasImage)
                    img("/media/products/${prod#id}", prod#name)
                else
                    span(() -> { cls("thumb-placeholder"); text(prod#sku) })
            });
            div(() -> {
                cls("card-body");
                span(() -> { cls("cat-tag"); text(prod#category) });
                h3(() -> {
                    cls("product-title");
                    link("/products/${prod#slug}", prod#name)
                });
                p(() -> { cls("product-desc"); text(prod#description) });
                renderStockBadge(prod#stock);
                div(() -> {
                    cls("price-row");
                    span(() -> { cls("price"); text(Shared.Money.formatCents(prod#priceCents)) });
                    form(() -> {
                        method("post");
                        action("/cart/items");
                        hxPost("/cart/items");
                        hxTarget("#cart-badge");
                        hxSwap("outerHTML");
                        Shared.Layout.csrfInput(csrfTok);
                        input(() -> { type_("hidden"); name("product_id"); value("${prod#id}") });
                        input(() -> { type_("hidden"); name("quantity"); value("1") });
                        button(() -> {
                            type_("submit");
                            cls("btn-sm");
                            when(prod#stock <= 0, () -> disabled());
                            text(if (prod#stock > 0) "Add to Cart" else "Sold Out")
                        })
                    })
                })
            })
        })

    def renderStockBadge(stock: Int32): Unit \ Html =
        if (stock <= 0)
            span(() -> { cls("stock-out"); text("Out of stock") })
        else if (stock <= 5)
            span(() -> { cls("stock-low"); text("Only ${stock} left") })
        else
            span(() -> { cls("stock-ok"); text("In stock (${stock})") })

    def renderPagination(filter: CatalogFilter, pg: Page[Product]): Unit \ Html = {
        let cur = Page.page(pg);
        let tot = Page.totalPages(pg);
        div(() -> {
            cls("pagination");
            when(Page.hasPrev(pg), () -> {
                let prevQs = buildGridQuery(filter#search, filter#category, filter#sort, cur - 1);
                a(() -> {
                    cls("btn btn-secondary btn-sm");
                    href("/" + prevQs);
                    hxGet("/products/grid" + prevQs);
                    hxTarget("#product-grid-container");
                    text("← Previous")
                })
            });
            span(() -> { cls("muted"); text("Page ${cur} of ${tot}") });
            when(Page.hasNext(pg), () -> {
                let nextQs = buildGridQuery(filter#search, filter#category, filter#sort, cur + 1);
                a(() -> {
                    cls("btn btn-secondary btn-sm");
                    href("/" + nextQs);
                    hxGet("/products/grid" + nextQs);
                    hxTarget("#product-grid-container");
                    text("Next →")
                })
            })
        })
    }

    def renderProductDetailBody(csrfTok: String, prod: Product): Unit \ Html = {
        p(() -> link("/", "← Back to Catalog"));
        div(() -> {
            cls("panel two-col");
            div(() -> {
                div(() -> {
                    cls("product-thumb");
                    attr("style", "height:300px;border-radius:10px;border:1px solid var(--border);margin-bottom:1rem");
                    if (prod#hasImage)
                        img("/media/products/${prod#id}", prod#name)
                    else
                        span(() -> { cls("thumb-placeholder"); text(prod#sku) })
                });
                span(() -> { cls("cat-tag"); text(prod#category) });
                h1(() -> text(prod#name));
                p(() -> { cls("muted"); text("SKU: ${prod#sku}") });
                pText(prod#description)
            });
            div(() -> {
                h2Text(Shared.Money.formatCents(prod#priceCents));
                renderStockBadge(prod#stock);
                form(() -> {
                    method("post");
                    action("/cart/items");
                    hxPost("/cart/items");
                    hxTarget("#cart-badge");
                    hxSwap("outerHTML");
                    attr("style", "margin-top:1.25rem");
                    Shared.Layout.csrfInput(csrfTok);
                    input(() -> { type_("hidden"); name("product_id"); value("${prod#id}") });
                    div(() -> {
                        cls("form-group");
                        label(() -> { attr("for", "qty"); text("Quantity") });
                        input(() -> {
                            id("qty");
                            type_("number");
                            name("quantity");
                            value("1");
                            attr("min", "1");
                            attrIf(prod#stock > 0, "max", "${prod#stock}")
                        })
                    });
                    button(() -> {
                        type_("submit");
                        attr("style", "width:100%");
                        when(prod#stock <= 0, () -> disabled());
                        text(if (prod#stock > 0) "Add to Cart" else "Sold Out")
                    })
                })
            })
        })
    }

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
