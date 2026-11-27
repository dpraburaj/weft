pub mod Weft.Html {
    use Weft.Html
    use Weft.HtmlDoc

    ///
    /// Algebraic effect for ergonomic, XSS-safe, effect-polymorphic HTML construction.
    ///
    /// Because `Html` is an algebraic effect rather than a rigid nested-list AST:
    /// - Control flow is ordinary Flix (`if`, `match`, `Html.each`, `Html.when`, `Html.whenSome`).
    /// - Attributes are attached inside the element block, and multiple `cls(...)` calls
    ///   automatically merge into a single `class="..."` attribute.
    /// - Components can freely combine `Html` with `Req`, `Auth`, `Db`, or custom domain effects.
    /// - All text and attribute values are HTML-escaped by default (`raw(...)` is explicit opt-in).
    ///
    /// Example:
    /// ```flix
    /// Html.page("Hello", () -> {
    ///     main_(() -> {
    ///         cls("container");
    ///         h1Text("Hello, ${name}!");
    ///         ul(() ->
    ///             each(items, item ->
    ///                 li(() -> link("/items/${item#id}", item#title))
    ///             )
    ///         )
    ///     })
    /// })
    /// ```
    ///
    pub eff Html {
        def openTag(tag: String, isVoid: Bool): Unit
        def closeTag(): Unit
        def addAttr(name: String, value: Option[String]): Unit
        def addClass(className: String): Unit
        def addText(content: String): Unit
        def addRaw(content: String): Unit
    }

    // --- Handlers / Entry Points ---

    ///
    /// Renders an `Html`-effectful builder block into an `HtmlDoc` (which implements `IntoResponse`).
    /// Discharges `Html` purely using a local `region` (zero `IO`).
    ///
    pub def render(f: Unit -> Unit \ ef): HtmlDoc \ (ef - Html) =
        HtmlDoc.HtmlDoc(renderString(f))

    ///
    /// Renders an `Html`-effectful builder block directly into a `String`.
    ///
    /// Uses a single shared `StringBuilder` with deferred open-tag flushing so leaf
    /// content is written once in O(output_size) instead of O(depth * output_size).
    ///
    pub def renderString(f: Unit -> Unit \ ef): String \ (ef - Html) = region rc {
        let out = StringBuilder.empty(rc);
        let openTagName: Ref[Option[String], rc] = Ref.fresh(rc, None);
        let openIsVoid: Ref[Bool, rc] = Ref.fresh(rc, false);
        let openClasses: Ref[List[String], rc] = Ref.fresh(rc, Nil);
        let openAttrs: Ref[List[(String, Option[String])], rc] = Ref.fresh(rc, Nil);
        let closedTagStack: Ref[List[String], rc] = Ref.fresh(rc, Nil);

        def flushOpenTag(pushIfNonVoid: Bool): Unit \ rc =
            match Ref.get(openTagName) {
                case None => ()
                case Some(tag) =>
                    StringBuilder.append('<', out);
                    StringBuilder.appendString(tag, out);

                    // Emit merged `class` attribute (fast path for 0 or 1 class)
                    match Ref.get(openClasses) {
                        case Nil => ()
                        case single :: Nil =>
                            StringBuilder.appendString(" class=\"", out);
                            appendEscaped(single, out);
                            StringBuilder.append('"', out)
                        case many =>
                            StringBuilder.appendString(" class=\"", out);
                            appendJoinedClasses(List.reverse(many), true, out);
                            StringBuilder.append('"', out)
                    };

                    // Emit remaining attributes in insertion order (fast path for 0 or 1 attr)
                    match Ref.get(openAttrs) {
                        case Nil => ()
                        case (attrName, vOpt) :: Nil =>
                            appendAttr(attrName, vOpt, out)
                        case many =>
                            List.forEach(match (attrName, vOpt) -> appendAttr(attrName, vOpt, out), List.reverse(many))
                    };

                    StringBuilder.append('>', out);

                    if (pushIfNonVoid and not Ref.get(openIsVoid))
                        Ref.transform(s -> tag :: s, closedTagStack)
                    else ();

                    Ref.put(None, openTagName);
                    Ref.put(false, openIsVoid);
                    Ref.put(Nil, openClasses);
                    Ref.put(Nil, openAttrs)
            };

        run {
            f()
        } with handler Html {
            def openTag(tag, isVoid, k) = {
                flushOpenTag(true);
                Ref.put(Some(tag), openTagName);
                Ref.put(isVoid, openIsVoid);
                k()
            }
            def closeTag(k) = {
                match Ref.get(openTagName) {
                    case Some(tag) =>
                        let isVoid = Ref.get(openIsVoid);
                        flushOpenTag(false);
                        if (not isVoid) {
                            StringBuilder.appendString("</", out);
                            StringBuilder.appendString(tag, out);
                            StringBuilder.append('>', out)
                        } else ()
                    case None =>
                        match Ref.get(closedTagStack) {
                            case tag :: rest =>
                                Ref.put(rest, closedTagStack);
                                StringBuilder.appendString("</", out);
                                StringBuilder.appendString(tag, out);
                                StringBuilder.append('>', out)
                            case Nil => ()
                        }
                };
                k()
            }
            def addAttr(name, valOpt, k) = {
                if (name == "class") {
                    match valOpt {
                        case Some(c) =>
                            let trimmed = String.trim(c);
                            if (not String.isEmpty(trimmed))
                                Ref.transform(cs -> trimmed :: cs, openClasses)
                            else
                                ()
                        case None => ()
                    }
                } else {
                    Ref.transform(xs -> (name, valOpt) :: xs, openAttrs)
                };
                k()
            }
            def addClass(className, k) = {
                let trimmed = String.trim(className);
                if (not String.isEmpty(trimmed))
                    Ref.transform(cs -> trimmed :: cs, openClasses)
                else
                    ();
                k()
            }
            def addText(content, k) = {
                flushOpenTag(true);
                appendEscaped(content, out);
                k()
            }
            def addRaw(content, k) = {
                flushOpenTag(true);
                StringBuilder.appendString(content, out);
                k()
            }
        };

        // Flush any unclosed open tag and close any remaining open ancestors safely
        flushOpenTag(true);
        List.forEach(tag -> {
            StringBuilder.appendString("</", out);
            StringBuilder.appendString(tag, out);
            StringBuilder.append('>', out)
        }, Ref.get(closedTagStack));
        StringBuilder.toString(out)
    }

    ///
    /// Renders an HTML5 document with a leading `<!DOCTYPE html>`.
    ///
    pub def document(f: Unit -> Unit \ ef): HtmlDoc \ (ef - Html) =
        render(() -> {
            doctype();
            f()
        })

    ///
    /// Renders a complete HTML5 page with UTF-8 charset, responsive viewport, and `<title>`.
    ///
    pub def page(pageTitle: String, bodyContent: Unit -> Unit \ ef): HtmlDoc \ (ef - Html) =
        pageWithHead(pageTitle, () -> (), bodyContent)

    ///
    /// Renders a complete HTML5 page with custom `<head>` elements (stylesheets, scripts, meta tags).
    ///
    pub def pageWithHead(
        pageTitle: String,
        extraHead: Unit -> Unit \ ef1,
        bodyContent: Unit -> Unit \ ef2
    ): HtmlDoc \ (ef1 + ef2 - Html) =
        render(() -> {
            Html.addRaw(
                "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" +
                escapeHtml(pageTitle) +
                "</title>"
            );
            extraHead();
            Html.addRaw("</head><body>");
            bodyContent();
            Html.addRaw("</body></html>")
        })

    // --- Core Primitives & Control-Flow Helpers ---

    ///
    /// Emits `<!DOCTYPE html>`.
    ///
    pub def doctype(): Unit \ Html =
        Html.addRaw("<!DOCTYPE html>")

    ///
    /// Emits an HTML-escaped text node (safe against XSS).
    ///
    pub def text(s: String): Unit \ Html =
        Html.addText(s)

    ///
    /// Emits trusted raw HTML without escaping. Use only for vetted markup/CSS/JS.
    ///
    pub def raw(s: String): Unit \ Html =
        Html.addRaw(s)

    ///
    /// Emits a non-void HTML element `<tag ...>...</tag>`.
    ///
    pub def el(tag: String, body: Unit -> Unit \ ef): Unit \ ef + Html = {
        Html.openTag(tag, false);
        body();
        Html.closeTag()
    }

    ///
    /// Emits a void HTML5 element `<tag ...>` (no closing tag).
    ///
    pub def voidEl(tag: String, attrs: Unit -> Unit \ ef): Unit \ ef + Html = {
        Html.openTag(tag, true);
        attrs();
        Html.closeTag()
    }

    ///
    /// Emits a non-void element containing only escaped text: `<tag>escaped(s)</tag>`.
    ///
    pub def elText(tag: String, content: String): Unit \ Html =
        Html.addRaw("<" + tag + ">" + escapeHtml(content) + "</" + tag + ">")

    ///
    /// Iterates over `xs` in order, invoking `f` for each element.
    /// Puts the collection first so templates read cleanly top-to-bottom.
    ///
    pub def each(xs: List[a], f: a -> Unit \ ef): Unit \ ef =
        List.forEach(f, xs)

    ///
    /// Runs `f` only when `cond` is `true` (avoids `else ()` noise in templates).
    ///
    pub def when(cond: Bool, f: Unit -> Unit \ ef): Unit \ ef =
        if (cond) f() else ()

    ///
    /// Runs `f(v)` only when `opt` is `Some(v)`.
    ///
    pub def whenSome(opt: Option[a], f: a -> Unit \ ef): Unit \ ef =
        match opt {
            case Some(v) => f(v)
            case None    => ()
        }

    // --- Attributes ---

    ///
    /// Sets an attribute `name="escaped(v)"` on the enclosing element.
    /// If `name == "class"`, merges with other `cls(...)` calls on the same element.
    ///
    pub def attr(name: String, v: String): Unit \ Html =
        Html.addAttr(name, Some(v))

    ///
    /// Conditionally sets `name="escaped(v)"` when `cond` is `true`.
    ///
    pub def attrIf(cond: Bool, name: String, v: String): Unit \ Html =
        if (cond) attr(name, v) else ()

    ///
    /// Conditionally sets a valueless boolean attribute (e.g., `disabled`, `checked`) when `cond` is `true`.
    ///
    pub def boolAttr(name: String, cond: Bool): Unit \ Html =
        if (cond) Html.addAttr(name, None) else ()

    ///
    /// Adds one or more CSS classes to the enclosing element.
    /// Multiple `cls(...)` calls automatically merge into a single `class="..."` attribute.
    ///
    pub def cls(className: String): Unit \ Html =
        Html.addClass(className)

    ///
    /// Conditionally adds a CSS class when `cond` is `true`.
    ///
    pub def clsIf(cond: Bool, className: String): Unit \ Html =
        if (cond) cls(className) else ()

    ///
    /// Sets a `data-<key>="v"` attribute.
    ///
    pub def data(key: String, v: String): Unit \ Html =
        attr("data-${key}", v)

    ///
    /// Sets an `aria-<key>="v"` attribute.
    ///
    pub def aria(key: String, v: String): Unit \ Html =
        attr("aria-${key}", v)

    // Common global & element attributes
    pub def id(v: String): Unit \ Html          = attr("id", v)
    pub def styleAttr(v: String): Unit \ Html   = attr("style", v)
    pub def titleAttr(v: String): Unit \ Html   = attr("title", v)
    pub def lang(v: String): Unit \ Html        = attr("lang", v)
    pub def role(v: String): Unit \ Html        = attr("role", v)
    pub def tabindex(n: Int32): Unit \ Html     = attr("tabindex", "${n}")
    pub def hidden(): Unit \ Html               = boolAttr("hidden", true)

    pub def href(v: String): Unit \ Html        = attr("href", v)
    pub def src(v: String): Unit \ Html         = attr("src", v)
    pub def alt(v: String): Unit \ Html         = attr("alt", v)
    pub def rel(v: String): Unit \ Html         = attr("rel", v)
    pub def target(v: String): Unit \ Html      = attr("target", v)
    pub def width(v: String): Unit \ Html       = attr("width", v)
    pub def height(v: String): Unit \ Html      = attr("height", v)
    pub def loading(v: String): Unit \ Html     = attr("loading", v)

    pub def action(v: String): Unit \ Html      = attr("action", v)
    pub def method(v: String): Unit \ Html      = attr("method", v)
    pub def name(v: String): Unit \ Html        = attr("name", v)
    pub def value(v: String): Unit \ Html       = attr("value", v)
    pub def type_(v: String): Unit \ Html       = attr("type", v)
    pub def placeholder(v: String): Unit \ Html = attr("placeholder", v)
    pub def for_(v: String): Unit \ Html        = attr("for", v)
    pub def rows(n: Int32): Unit \ Html         = attr("rows", "${n}")
    pub def cols(n: Int32): Unit \ Html         = attr("cols", "${n}")
    pub def autocomplete(v: String): Unit \ Html = attr("autocomplete", v)

    pub def required(): Unit \ Html             = boolAttr("required", true)
    pub def disabled(): Unit \ Html             = boolAttr("disabled", true)
    pub def checked(): Unit \ Html              = boolAttr("checked", true)
    pub def selected(): Unit \ Html             = boolAttr("selected", true)
    pub def readonly(): Unit \ Html             = boolAttr("readonly", true)
    pub def multiple(): Unit \ Html             = boolAttr("multiple", true)
    pub def autofocus(): Unit \ Html            = boolAttr("autofocus", true)
    pub def defer(): Unit \ Html                = boolAttr("defer", true)

    // HTMX attributes
    pub def hxGet(url: String): Unit \ Html     = attr("hx-get", url)
    pub def hxPost(url: String): Unit \ Html    = attr("hx-post", url)
    pub def hxPut(url: String): Unit \ Html     = attr("hx-put", url)
    pub def hxPatch(url: String): Unit \ Html   = attr("hx-patch", url)
    pub def hxDelete(url: String): Unit \ Html  = attr("hx-delete", url)
    pub def hxTarget(sel: String): Unit \ Html  = attr("hx-target", sel)
    pub def hxSwap(mode: String): Unit \ Html   = attr("hx-swap", mode)
    pub def hxTrigger(ev: String): Unit \ Html  = attr("hx-trigger", ev)

    // --- Document & Section Elements ---

    pub def html(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("html", b)
    pub def head(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("head", b)
    pub def title(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("title", b)
    pub def body(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("body", b)
    pub def header(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("header", b)
    pub def footer(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("footer", b)
    pub def main_(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("main", b)
    pub def nav(b: Unit -> Unit \ ef): Unit \ ef + Html        = el("nav", b)
    pub def section(b: Unit -> Unit \ ef): Unit \ ef + Html    = el("section", b)
    pub def article(b: Unit -> Unit \ ef): Unit \ ef + Html    = el("article", b)
    pub def aside(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("aside", b)
    pub def div(b: Unit -> Unit \ ef): Unit \ ef + Html        = el("div", b)

    // --- Headings & Text Content ---

    pub def h1(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h1", b)
    pub def h2(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h2", b)
    pub def h3(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h3", b)
    pub def h4(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h4", b)
    pub def h5(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h5", b)
    pub def h6(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("h6", b)
    pub def p(b: Unit -> Unit \ ef): Unit \ ef + Html          = el("p", b)
    pub def span(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("span", b)
    pub def a(b: Unit -> Unit \ ef): Unit \ ef + Html          = el("a", b)
    pub def strong(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("strong", b)
    pub def em(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("em", b)
    pub def small(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("small", b)
    pub def code(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("code", b)
    pub def pre(b: Unit -> Unit \ ef): Unit \ ef + Html        = el("pre", b)
    pub def blockquote(b: Unit -> Unit \ ef): Unit \ ef + Html = el("blockquote", b)
    pub def details(b: Unit -> Unit \ ef): Unit \ ef + Html    = el("details", b)
    pub def summary(b: Unit -> Unit \ ef): Unit \ ef + Html    = el("summary", b)
    pub def figure(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("figure", b)
    pub def figcaption(b: Unit -> Unit \ ef): Unit \ ef + Html = el("figcaption", b)

    // --- Lists & Tables ---

    pub def ul(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("ul", b)
    pub def ol(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("ol", b)
    pub def li(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("li", b)
    pub def dl(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("dl", b)
    pub def dt(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("dt", b)
    pub def dd(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("dd", b)
    pub def table(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("table", b)
    pub def thead(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("thead", b)
    pub def tbody(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("tbody", b)
    pub def tfoot(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("tfoot", b)
    pub def tr(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("tr", b)
    pub def th(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("th", b)
    pub def td(b: Unit -> Unit \ ef): Unit \ ef + Html         = el("td", b)

    // --- Forms & Interactive Elements ---

    pub def form(b: Unit -> Unit \ ef): Unit \ ef + Html       = el("form", b)
    pub def label(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("label", b)
    pub def button(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("button", b)
    pub def select_(b: Unit -> Unit \ ef): Unit \ ef + Html    = el("select", b)
    pub def optgroup(b: Unit -> Unit \ ef): Unit \ ef + Html   = el("optgroup", b)
    pub def option(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("option", b)
    pub def textarea(b: Unit -> Unit \ ef): Unit \ ef + Html   = el("textarea", b)
    pub def fieldset(b: Unit -> Unit \ ef): Unit \ ef + Html   = el("fieldset", b)
    pub def legend(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("legend", b)

    // --- Embedded Resources & Void Elements ---

    pub def style(b: Unit -> Unit \ ef): Unit \ ef + Html      = el("style", b)
    pub def script(b: Unit -> Unit \ ef): Unit \ ef + Html     = el("script", b)
    pub def input(attrs: Unit -> Unit \ ef): Unit \ ef + Html  = voidEl("input", attrs)
    pub def imgEl(attrs: Unit -> Unit \ ef): Unit \ ef + Html  = voidEl("img", attrs)
    pub def linkTag(attrs: Unit -> Unit \ ef): Unit \ ef + Html = voidEl("link", attrs)
    pub def metaTag(attrs: Unit -> Unit \ ef): Unit \ ef + Html = voidEl("meta", attrs)
    pub def br(): Unit \ Html                                  = Html.addRaw("<br>")
    pub def hr(): Unit \ Html                                  = Html.addRaw("<hr>")

    // --- Ergonomic One-Liner Shorthands ---

    pub def titleText(s: String): Unit \ Html   = elText("title", s)
    pub def h1Text(s: String): Unit \ Html      = elText("h1", s)
    pub def h2Text(s: String): Unit \ Html      = elText("h2", s)
    pub def h3Text(s: String): Unit \ Html      = elText("h3", s)
    pub def pText(s: String): Unit \ Html       = elText("p", s)
    pub def spanText(s: String): Unit \ Html    = elText("span", s)
    pub def liText(s: String): Unit \ Html      = elText("li", s)
    pub def thText(s: String): Unit \ Html      = elText("th", s)
    pub def tdText(s: String): Unit \ Html      = elText("td", s)
    pub def codeText(s: String): Unit \ Html    = elText("code", s)
    pub def strongText(s: String): Unit \ Html  = elText("strong", s)
    pub def emText(s: String): Unit \ Html      = elText("em", s)

    ///
    /// Emits `<a href="...">escaped(label)</a>`.
    ///
    pub def link(url: String, labelText: String): Unit \ Html =
        Html.addRaw("<a href=\"" + escapeHtml(url) + "\">" + escapeHtml(labelText) + "</a>")

    ///
    /// Emits `<img src="..." alt="...">`.
    ///
    pub def img(imgSrc: String, imgAlt: String): Unit \ Html =
        Html.addRaw("<img src=\"" + escapeHtml(imgSrc) + "\" alt=\"" + escapeHtml(imgAlt) + "\">")

    ///
    /// Emits `<meta charset="...">`.
    ///
    pub def metaCharset(charset: String): Unit \ Html =
        Html.addRaw("<meta charset=\"" + escapeHtml(charset) + "\">")

    ///
    /// Emits `<meta name="viewport" content="width=device-width, initial-scale=1">`.
    ///
    pub def metaViewport(): Unit \ Html =
        Html.addRaw("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")

    ///
    /// Emits `<meta name="..." content="...">`.
    ///
    pub def meta(metaName: String, content: String): Unit \ Html =
        Html.addRaw("<meta name=\"" + escapeHtml(metaName) + "\" content=\"" + escapeHtml(content) + "\">")

    ///
    /// Emits `<link rel="stylesheet" href="...">`.
    ///
    pub def stylesheet(url: String): Unit \ Html =
        Html.addRaw("<link rel=\"stylesheet\" href=\"" + escapeHtml(url) + "\">")

    ///
    /// Emits `<script src="..." defer></script>`.
    ///
    pub def scriptSrc(url: String): Unit \ Html =
        Html.addRaw("<script src=\"" + escapeHtml(url) + "\" defer></script>")

    ///
    /// Emits `<style>rawCss</style>`.
    ///
    pub def inlineStyle(css: String): Unit \ Html =
        Html.addRaw("<style>" + css + "</style>")

    // --- Escaping & Internal Streaming Helpers ---

    ///
    /// Escapes `&`, `<`, `>`, `"`, and `'` for safe HTML text and attribute rendering.
    /// Zero-allocation fast path when no special characters are present.
    ///
    pub def escapeHtml(s: String): String =
        if (not needsEscape(s))
            s
        else
            region rc {
                let sb = StringBuilder.empty(rc);
                appendEscapedSlow(s, sb);
                StringBuilder.toString(sb)
            }

    def needsEscape(s: String): Bool = {
        let len = String.length(s);
        def loop(i) =
            if (i >= len)
                false
            else {
                let c = String.charAt(i, s);
                if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'')
                    true
                else
                    loop(i + 1)
            };
        loop(0)
    }

    def appendEscaped(s: String, sb: StringBuilder[r]): Unit \ r =
        if (not needsEscape(s))
            StringBuilder.appendString(s, sb)
        else
            appendEscapedSlow(s, sb)

    def appendEscapedSlow(s: String, sb: StringBuilder[r]): Unit \ r = {
        let len = String.length(s);
        def loop(i) =
            if (i >= len)
                ()
            else {
                match String.charAt(i, s) {
                    case '&'  => StringBuilder.appendString("&amp;", sb)
                    case '<'  => StringBuilder.appendString("&lt;", sb)
                    case '>'  => StringBuilder.appendString("&gt;", sb)
                    case '"'  => StringBuilder.appendString("&quot;", sb)
                    case '\'' => StringBuilder.appendString("&#39;", sb)
                    case c    => StringBuilder.append(c, sb)
                };
                loop(i + 1)
            };
        loop(0)
    }

    def appendJoinedClasses(xs: List[String], isFirst: Bool, sb: StringBuilder[r]): Unit \ r = match xs {
        case Nil => ()
        case c :: rest =>
            if (not isFirst) StringBuilder.append(' ', sb) else ();
            appendEscaped(c, sb);
            appendJoinedClasses(rest, false, sb)
    }

    def appendAttr(attrName: String, vOpt: Option[String], sb: StringBuilder[r]): Unit \ r = {
        StringBuilder.append(' ', sb);
        StringBuilder.appendString(attrName, sb);
        match vOpt {
            case None => ()
            case Some(v) =>
                StringBuilder.appendString("=\"", sb);
                appendEscaped(v, sb);
                StringBuilder.append('"', sb)
        }
    }

}
