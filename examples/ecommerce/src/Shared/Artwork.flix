pub mod Shared.Artwork {
    use Shared.Domain.Product
    use weft::Weft.Html
    use weft::Weft.View
    use weft::Weft.View.raw

    ///
    /// Resolves the static SVG artwork path for a product when no custom image is uploaded.
    /// Served via Weft's `StaticFiles` middleware (`/static/products/*.svg`) with ETag/304 caching.
    ///
    pub def staticArtworkUrl(prod: Product): String =
        match prod#category {
            case "coffee" =>
                if (String.contains({substr = "ETH"}, prod#sku))
                    "/static/products/coffee-eth.svg"
                else if (String.contains({substr = "COL-02"}, prod#sku))
                    "/static/products/coffee-col.svg"
                else if (String.contains({substr = "ESP"}, prod#sku))
                    "/static/products/coffee-esp.svg"
                else
                    "/static/products/coffee-dec.svg"
            case "grinders" =>
                if (String.contains({substr = "HND"}, prod#sku))
                    "/static/products/grinder-hand.svg"
                else
                    "/static/products/grinder-flat.svg"
            case "brewers" =>
                if (String.contains({substr = "KET"}, prod#sku))
                    "/static/products/brewer-kettle.svg"
                else
                    "/static/products/brewer-dripper.svg"
            case _ =>
                if (String.contains({substr = "SCL"}, prod#sku))
                    "/static/products/accessory-scale.svg"
                else
                    "/static/products/accessory-cups.svg"
        }

    ///
    /// Emits a lazy-loaded `<img>` referencing the product's static SVG illustration.
    ///
    pub def productIllustration(prod: Product): View =
        raw(
            "<img class=\"art-svg\" src=\"" +
            staticArtworkUrl(prod) +
            "\" alt=\"" +
            Html.escapeHtml(prod#name) +
            "\" loading=\"lazy\">"
        )

    // =========================================================================
    // Crisp 15px Stroke SVG Icons for Admin Sidebar
    // =========================================================================

    pub def iconHome(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 6.8L8 2.2l5.5 4.6v6.2a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1V6.8z\"/><path d=\"M6 14V9.5h4V14\"/></svg>")

    pub def iconOrders(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"2.5\" width=\"11\" height=\"11\" rx=\"1.5\"/><path d=\"M2.5 9.5h3.2l1.1 1.5h2.4l1.1-1.5h3.2\"/></svg>")

    pub def iconBox(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.8L13.5 4.8v6.4L8 14.2 2.5 11.2V4.8L8 1.8z\"/><path d=\"M2.5 4.8L8 7.8l5.5-3M8 7.8v6.4\"/></svg>")

    pub def iconPlus(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\"><path d=\"M8 3.2v9.6M3.2 8h9.6\"/></svg>")

    pub def iconAlert(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2.4L14 13H2L8 2.4z\"/><path d=\"M8 6.5v3M8 11.2h.01\"/></svg>")

    pub def iconStore(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 6l1-3.2h9l1 3.2v1a2 2 0 0 1-4 0 2 2 0 0 1-3 0 2 2 0 0 1-4 0V6z\"/><path d=\"M3.5 9v4.5h9V9\"/></svg>")

    pub def iconActivity(): View =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1.8 8.2h2.7l1.8-4.5 3.1 8.6 1.8-4.1h3\"/></svg>")

}
