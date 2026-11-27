pub mod Shared.Artwork {
    use Shared.Domain.Product
    use weft::Weft.Html
    use weft::Weft.Html.raw

    ///
    /// Art-directed minimalist SVG packaging & equipment illustrations rendered when a
    /// product has no uploaded photograph. Inspired by Scandinavian specialty coffee
    /// roasters (Sey / La Cabra / Fellow) rather than generic gray placeholder boxes.
    ///
    pub def productIllustration(prod: Product): Unit \ Html =
        match prod#category {
            case "coffee"      => coffeeBagSvg(prod)
            case "grinders"    => grinderSvg(prod)
            case "brewers"     => brewerSvg(prod)
            case _             => accessorySvg(prod)
        }

    def coffeeBagSvg(prod: Product): Unit \ Html = {
        let (bgTone, bandColor, roastNote) = coffeePalette(prod#sku);
        let safeSku = escapeSvgText(prod#sku);
        let shortTitle = escapeSvgText(shortName(prod#name));
        raw(
            "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"${shortTitle}\">" +
            "<rect width=\"320\" height=\"240\" fill=\"${bgTone}\"/>" +
            "<g transform=\"translate(96,26)\">" +
            "<rect x=\"2\" y=\"6\" width=\"128\" height=\"186\" rx=\"3\" fill=\"rgba(23,22,20,0.06)\"/>" +
            "<rect x=\"0\" y=\"0\" width=\"128\" height=\"186\" rx=\"2\" fill=\"#fbfaf7\" stroke=\"#d5cfc3\" stroke-width=\"1\"/>" +
            "<line x1=\"0\" y1=\"18\" x2=\"128\" y2=\"18\" stroke=\"#e6e1d7\" stroke-width=\"1\"/>" +
            "<rect x=\"14\" y=\"32\" width=\"100\" height=\"118\" fill=\"#ffffff\" stroke=\"#e6e1d7\" stroke-width=\"1\"/>" +
            "<rect x=\"14\" y=\"32\" width=\"100\" height=\"8\" fill=\"${bandColor}\"/>" +
            "<text x=\"22\" y=\"56\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"7.5\" letter-spacing=\"1.4\" fill=\"#6b665d\">WEFT ROASTERS</text>" +
            "<line x1=\"22\" y1=\"63\" x2=\"106\" y2=\"63\" stroke=\"#e6e1d7\" stroke-width=\"0.8\"/>" +
            "<text x=\"22\" y=\"84\" font-family=\"Georgia,serif\" font-size=\"11.5\" fill=\"#171614\">${shortTitle}</text>" +
            "<text x=\"22\" y=\"100\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"7\" fill=\"#8c4a27\">${roastNote}</text>" +
            "<line x1=\"22\" y1=\"122\" x2=\"106\" y2=\"122\" stroke=\"#ece8df\" stroke-width=\"0.8\"/>" +
            "<text x=\"22\" y=\"136\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"7\" fill=\"#6b665d\">${safeSku} · 250G</text>" +
            "<circle cx=\"64\" cy=\"168\" r=\"4\" fill=\"none\" stroke=\"#c8c1b4\" stroke-width=\"1\"/>" +
            "<circle cx=\"64\" cy=\"168\" r=\"1.2\" fill=\"#c8c1b4\"/>" +
            "</g>" +
            "</svg>"
        )
    }

    def grinderSvg(prod: Product): Unit \ Html = {
        let safeSku = escapeSvgText(prod#sku);
        let isHand = String.contains({substr = "HND"}, prod#sku);
        if (isHand) {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Hand Grinder\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#eeece6\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.5\" fill=\"none\">" +
                "<rect x=\"134\" y=\"74\" width=\"52\" height=\"124\" rx=\"3\" fill=\"#fbfaf7\"/>" +
                "<line x1=\"134\" y1=\"146\" x2=\"186\" y2=\"146\" stroke=\"#b9b3a7\" stroke-width=\"1\"/>" +
                "<rect x=\"142\" y=\"62\" width=\"36\" height=\"12\" rx=\"1\" fill=\"#171614\"/>" +
                "<line x1=\"160\" y1=\"46\" x2=\"160\" y2=\"62\"/>" +
                "<line x1=\"160\" y1=\"46\" x2=\"222\" y2=\"46\"/>" +
                "<circle cx=\"226\" cy=\"46\" r=\"7\" fill=\"#8c4a27\" stroke=\"#171614\"/>" +
                "<line x1=\"146\" y1=\"92\" x2=\"146\" y2=\"134\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"154\" y1=\"92\" x2=\"154\" y2=\"134\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"162\" y1=\"92\" x2=\"162\" y2=\"134\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"170\" y1=\"92\" x2=\"170\" y2=\"134\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"176\" y1=\"92\" x2=\"176\" y2=\"134\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · CNC STEEL</text>" +
                "</svg>"
            )
        } else {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Flat Burr Grinder\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#eceae5\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.5\" fill=\"none\">" +
                "<rect x=\"108\" y=\"188\" width=\"104\" height=\"10\" rx=\"2\" fill=\"#171614\"/>" +
                "<rect x=\"118\" y=\"88\" width=\"64\" height=\"100\" rx=\"2\" fill=\"#262523\"/>" +
                "<path d=\"M122 88 L112 46 L188 46 L178 88 Z\" fill=\"#fbfaf7\"/>" +
                "<rect x=\"176\" y=\"104\" width=\"24\" height=\"14\" rx=\"2\" fill=\"#8c4a27\"/>" +
                "<rect x=\"180\" y=\"152\" width=\"28\" height=\"36\" rx=\"2\" fill=\"#fbfaf7\"/>" +
                "<circle cx=\"150\" cy=\"126\" r=\"16\" stroke=\"#fbfaf7\" stroke-width=\"1.2\"/>" +
                "<circle cx=\"150\" cy=\"126\" r=\"4\" fill=\"#8c4a27\" stroke=\"none\"/>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · 64MM FLAT BURR</text>" +
                "</svg>"
            )
        }
    }

    def brewerSvg(prod: Product): Unit \ Html = {
        let safeSku = escapeSvgText(prod#sku);
        let isKettle = String.contains({substr = "KET"}, prod#sku);
        if (isKettle) {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Gooseneck Kettle\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#efece6\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.6\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" +
                "<rect x=\"98\" y=\"186\" width=\"124\" height=\"12\" rx=\"2\" fill=\"#fbfaf7\"/>" +
                "<path d=\"M118 82 L196 82 L206 184 L108 184 Z\" fill=\"#1f1e1c\"/>" +
                "<line x1=\"116\" y1=\"82\" x2=\"198\" y2=\"82\"/>" +
                "<rect x=\"148\" y=\"71\" width=\"18\" height=\"11\" rx=\"2\" fill=\"#8c4a27\"/>" +
                "<path d=\"M112 162 C78 158 84 96 64 82\"/>" +
                "<path d=\"M198 102 C228 102 228 156 203 160\"/>" +
                "<circle cx=\"196\" cy=\"192\" r=\"2.5\" fill=\"#8c4a27\" stroke=\"none\"/>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · PID TEMP CONTROL</text>" +
                "</svg>"
            )
        } else {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Pour-Over Dripper\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#f0ece4\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.5\" fill=\"none\" stroke-linejoin=\"round\">" +
                "<path d=\"M106 60 L214 60 L182 142 L138 142 Z\" fill=\"#fbfaf7\"/>" +
                "<line x1=\"122\" y1=\"60\" x2=\"146\" y2=\"142\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"144\" y1=\"60\" x2=\"155\" y2=\"142\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"166\" y1=\"60\" x2=\"164\" y2=\"142\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<line x1=\"188\" y1=\"60\" x2=\"173\" y2=\"142\" stroke=\"#d2ccc0\" stroke-width=\"1\"/>" +
                "<rect x=\"122\" y=\"142\" width=\"76\" height=\"8\" rx=\"2\" fill=\"#8c4a27\"/>" +
                "<path d=\"M134 150 L186 150 L194 198 L126 198 Z\" fill=\"rgba(255,255,255,0.65)\"/>" +
                "<path d=\"M198 76 C220 76 220 118 193 118\"/>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · STONEWARE</text>" +
                "</svg>"
            )
        }
    }

    def accessorySvg(prod: Product): Unit \ Html = {
        let safeSku = escapeSvgText(prod#sku);
        let isScale = String.contains({substr = "SCL"}, prod#sku);
        if (isScale) {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Digital Scale\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#eceae5\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.5\" fill=\"none\">" +
                "<rect x=\"76\" y=\"70\" width=\"168\" height=\"124\" rx=\"4\" fill=\"#1d1c1a\"/>" +
                "<rect x=\"88\" y=\"82\" width=\"144\" height=\"78\" rx=\"2\" fill=\"#2a2926\" stroke=\"#3f3d39\"/>" +
                "<text x=\"102\" y=\"181\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"13\" fill=\"#f6f4ef\" stroke=\"none\">01:42</text>" +
                "<text x=\"174\" y=\"181\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"13\" fill=\"#d97706\" stroke=\"none\">240.0g</text>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · 0.1G PRECISION</text>" +
                "</svg>"
            )
        } else {
            raw(
                "<svg class=\"art-svg\" viewBox=\"0 0 320 240\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Stoneware Cups\">" +
                "<rect width=\"320\" height=\"240\" fill=\"#f0ece4\"/>" +
                "<line x1=\"32\" y1=\"204\" x2=\"288\" y2=\"204\" stroke=\"#dcd8ce\" stroke-width=\"1\"/>" +
                "<g stroke=\"#171614\" stroke-width=\"1.5\" fill=\"none\">" +
                "<path d=\"M86 108 L156 108 L148 188 C147 194 140 198 121 198 C102 198 95 194 94 188 Z\" fill=\"#fbfaf7\"/>" +
                "<path d=\"M86 154 L152 154 L148 188 C147 194 140 198 121 198 C102 198 95 194 94 188 Z\" fill=\"#d9c5b2\" stroke=\"none\"/>" +
                "<path d=\"M86 108 L156 108 L148 188 C147 194 140 198 121 198 C102 198 95 194 94 188 Z\"/>" +
                "<path d=\"M168 122 L232 122 L225 188 C224 194 218 198 200 198 C182 198 176 194 175 188 Z\" fill=\"#fbfaf7\"/>" +
                "<path d=\"M168 160 L228 160 L225 188 C224 194 218 198 200 198 C182 198 176 194 175 188 Z\" fill=\"#8c4a27\" opacity=\"0.28\" stroke=\"none\"/>" +
                "<path d=\"M168 122 L232 122 L225 188 C224 194 218 198 200 198 C182 198 176 194 175 188 Z\"/>" +
                "</g>" +
                "<text x=\"24\" y=\"222\" font-family=\"ui-monospace,SFMono-Regular,Menlo,monospace\" font-size=\"8.5\" letter-spacing=\"1\" fill=\"#6b665d\">${safeSku} · HAND-GLAZED</text>" +
                "</svg>"
            )
        }
    }

    def coffeePalette(sku: String): (String, String, String) =
        if (String.contains({substr = "ETH"}, sku))
            ("#eae6dc", "#5b7c68", "WASHED · LIGHT ROAST")
        else if (String.contains({substr = "COL-02"}, sku))
            ("#efe5e0", "#a64d3c", "PINK BOURBON · 1850M")
        else if (String.contains({substr = "ESP"}, sku))
            ("#e6e1da", "#3d2f28", "ESPRESSO · MEDIUM")
        else
            ("#e9e6e2", "#7c6b5a", "SUGARCANE DECAF")

    def shortName(s: String): String =
        if (String.length(s) <= 18) s
        else String.sliceLeft({end = 16}, s) + "…"

    def escapeSvgText(s: String): String =
        String.replace({src = "&"}, {dst = "&amp;"}, s)
            |> String.replace({src = "<"}, {dst = "&lt;"})
            |> String.replace({src = ">"}, {dst = "&gt;"})
            |> String.replace({src = "\""}, {dst = "&quot;"})

    // =========================================================================
    // Crisp 15px Stroke SVG Icons for Admin Sidebar
    // =========================================================================

    pub def iconHome(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 6.8L8 2.2l5.5 4.6v6.2a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1V6.8z\"/><path d=\"M6 14V9.5h4V14\"/></svg>")

    pub def iconOrders(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"2.5\" y=\"2.5\" width=\"11\" height=\"11\" rx=\"1.5\"/><path d=\"M2.5 9.5h3.2l1.1 1.5h2.4l1.1-1.5h3.2\"/></svg>")

    pub def iconBox(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 1.8L13.5 4.8v6.4L8 14.2 2.5 11.2V4.8L8 1.8z\"/><path d=\"M2.5 4.8L8 7.8l5.5-3M8 7.8v6.4\"/></svg>")

    pub def iconPlus(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\"><path d=\"M8 3.2v9.6M3.2 8h9.6\"/></svg>")

    pub def iconAlert(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M8 2.4L14 13H2L8 2.4z\"/><path d=\"M8 6.5v3M8 11.2h.01\"/></svg>")

    pub def iconStore(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M2.5 6l1-3.2h9l1 3.2v1a2 2 0 0 1-4 0 2 2 0 0 1-3 0 2 2 0 0 1-4 0V6z\"/><path d=\"M3.5 9v4.5h9V9\"/></svg>")

    pub def iconActivity(): Unit \ Html =
        raw("<svg class=\"nav-ico\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1.8 8.2h2.7l1.8-4.5 3.1 8.6 1.8-4.1h3\"/></svg>")

}
