pub mod Weft.View {
    use Weft.Html
    use Weft.HtmlDoc
    use Weft.IntoResponse
    use Weft.Response
    use Weft.View

    ///
    /// Pure, immutable HTML representation uniting attributes and child nodes into a single
    /// algebraic data type (`Vector#{ ... }`) for zero-effect, single-pass HTML rendering.
    ///
    /// Unlike `Weft.Html` (which uses an algebraic effect per tag/attribute), `Weft.View`
    /// builds plain Flix values with zero effect continuations, zero per-tag closures, and
    /// zero region parameters in view signatures — rendering an entire document in one pass
    /// into a single `StringBuilder`.
    ///
    /// Example:
    /// ```flix
    /// View.div(Vector#{
    ///     View.cls("card"),
    ///     View.h2Text("Hello, ${name}"),
    ///     View.p(Vector#{ View.cls("muted"), View.text(bio) })
    /// })
    /// ```
    ///
    pub enum View with Eq {
        case Empty
        case Text(String)
        case Raw(String)
        case Attr(String, Option[String])
        case Class(String)
        case Elem(String, Vector[View])
        case VoidElem(String, Vector[View])
        case Frag(Vector[View])
        case ListFrag(List[View])
    }

    instance IntoResponse[View] {
        pub def intoResponse(v: View): Response =
            Response.html(Weft.View.renderString(v))
    }

    // --- Rendering Entry Points ---

    ///
    /// Renders a `View` tree into an `HtmlDoc` (`IntoResponse`) in a single pure pass.
    ///
    pub def toHtmlDoc(v: View): HtmlDoc =
        HtmlDoc.HtmlDoc(renderString(v))

    ///
    /// Alias for `toHtmlDoc`.
    ///
    pub def render(v: View): HtmlDoc =
        toHtmlDoc(v)

    ///
    /// Renders a `View` tree directly into an HTML `String` using a single `StringBuilder`
    /// with zero algebraic effects and zero intermediate element strings.
    ///
    pub def renderString(v: View): String = region rc {
        let sb = StringBuilder.empty(rc);
        renderNode(v, sb);
        StringBuilder.toString(sb)
    }

    ///
    /// Renders a complete HTML5 document with a leading `<!DOCTYPE html>`.
    ///
    pub def document(v: View): HtmlDoc =
        HtmlDoc.HtmlDoc(region rc {
            let sb = StringBuilder.empty(rc);
            StringBuilder.appendString("<!DOCTYPE html>", sb);
            renderNode(v, sb);
            StringBuilder.toString(sb)
        })

    ///
    /// Renders a complete HTML5 page with UTF-8 charset, responsive viewport, and `<title>`.
    ///
    pub def page(pageTitle: String, bodyContent: View): HtmlDoc =
        pageWithHead(pageTitle, View.Empty, bodyContent)

    ///
    /// Renders a complete HTML5 page with custom `<head>` nodes (stylesheets, scripts, meta tags).
    ///
    pub def pageWithHead(pageTitle: String, extraHead: View, bodyContent: View): HtmlDoc =
        HtmlDoc.HtmlDoc(region rc {
            let sb = StringBuilder.empty(rc);
            StringBuilder.appendString(
                "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>",
                sb
            );
            appendEscaped(pageTitle, sb);
            StringBuilder.appendString("</title>", sb);
            renderNode(extraHead, sb);
            StringBuilder.appendString("</head><body>", sb);
            renderNode(bodyContent, sb);
            StringBuilder.appendString("</body></html>", sb);
            StringBuilder.toString(sb)
        })

    // --- Core Primitives & Control-Flow Helpers ---

    pub def empty(): View = View.Empty
    pub def doctype(): View = View.Raw("<!DOCTYPE html>")
    pub def text(s: String): View = View.Text(s)
    pub def raw(s: String): View = View.Raw(s)
    pub def frag(nodes: Vector[View]): View = View.Frag(nodes)
    pub def fragList(nodes: List[View]): View = View.ListFrag(nodes)

    pub def el(tag: String, items: Vector[View]): View = View.Elem(tag, items)
    pub def voidEl(tag: String, items: Vector[View]): View = View.VoidElem(tag, items)

    pub def elText(tag: String, content: String): View =
        View.Raw("<" + tag + ">" + Html.escapeHtml(content) + "</" + tag + ">")

    ///
    /// Maps `xs` to `View` nodes without allocating an intermediate `Vector`.
    ///
    pub def each(xs: List[a], f: a -> View \ ef): View \ ef =
        View.ListFrag(List.map(f, xs))

    ///
    /// Includes `node` when `cond` is `true`, otherwise `View.Empty`.
    ///
    pub def when(cond: Bool, node: View): View =
        if (cond) node else View.Empty

    ///
    /// Lazily builds a `View` only when `cond` is `true`.
    ///
    pub def whenLazy(cond: Bool, f: Unit -> View \ ef): View \ ef =
        if (cond) f() else View.Empty

    ///
    /// Renders `f(v)` when `opt` is `Some(v)`, otherwise `View.Empty`.
    ///
    pub def whenSome(opt: Option[a], f: a -> View \ ef): View \ ef = match opt {
        case Some(v) => f(v)
        case None    => View.Empty
    }

    // --- Attributes ---

    pub def attr(name: String, v: String): View =
        if (name == "class") cls(v) else View.Attr(name, Some(v))

    pub def attrIf(cond: Bool, name: String, v: String): View =
        if (cond) attr(name, v) else View.Empty

    pub def boolAttr(name: String, cond: Bool): View =
        if (cond) View.Attr(name, None) else View.Empty

    pub def cls(className: String): View = {
        let trimmed = String.trim(className);
        if (String.isEmpty(trimmed)) View.Empty else View.Class(trimmed)
    }

    pub def clsIf(cond: Bool, className: String): View =
        if (cond) cls(className) else View.Empty

    pub def data(key: String, v: String): View = attr("data-${key}", v)
    pub def aria(key: String, v: String): View = attr("aria-${key}", v)

    // Common global & element attributes
    pub def id(v: String): View           = attr("id", v)
    pub def styleAttr(v: String): View    = attr("style", v)
    pub def titleAttr(v: String): View    = attr("title", v)
    pub def lang(v: String): View         = attr("lang", v)
    pub def role(v: String): View         = attr("role", v)
    pub def tabindex(n: Int32): View      = attr("tabindex", "${n}")
    pub def hidden(): View                = View.Attr("hidden", None)

    pub def href(v: String): View         = attr("href", v)
    pub def src(v: String): View          = attr("src", v)
    pub def alt(v: String): View          = attr("alt", v)
    pub def rel(v: String): View          = attr("rel", v)
    pub def target(v: String): View       = attr("target", v)
    pub def width(v: String): View        = attr("width", v)
    pub def height(v: String): View       = attr("height", v)
    pub def loading(v: String): View      = attr("loading", v)

    pub def action(v: String): View       = attr("action", v)
    pub def method(v: String): View       = attr("method", v)
    pub def name(v: String): View         = attr("name", v)
    pub def value(v: String): View        = attr("value", v)
    pub def type_(v: String): View        = attr("type", v)
    pub def placeholder(v: String): View  = attr("placeholder", v)
    pub def for_(v: String): View         = attr("for", v)
    pub def rows(n: Int32): View          = attr("rows", "${n}")
    pub def cols(n: Int32): View          = attr("cols", "${n}")
    pub def autocomplete(v: String): View = attr("autocomplete", v)
    pub def enctype(v: String): View      = attr("enctype", v)
    pub def minAttr(v: String): View      = attr("min", v)
    pub def maxAttr(v: String): View      = attr("max", v)
    pub def accept(v: String): View       = attr("accept", v)

    pub def required(): View              = View.Attr("required", None)
    pub def disabled(): View              = View.Attr("disabled", None)
    pub def checked(): View               = View.Attr("checked", None)
    pub def selected(): View              = View.Attr("selected", None)
    pub def readonly(): View              = View.Attr("readonly", None)
    pub def multiple(): View              = View.Attr("multiple", None)
    pub def autofocus(): View             = View.Attr("autofocus", None)
    pub def defer(): View                 = View.Attr("defer", None)

    // HTMX attributes
    pub def hxGet(url: String): View      = attr("hx-get", url)
    pub def hxPost(url: String): View     = attr("hx-post", url)
    pub def hxPut(url: String): View      = attr("hx-put", url)
    pub def hxPatch(url: String): View    = attr("hx-patch", url)
    pub def hxDelete(url: String): View   = attr("hx-delete", url)
    pub def hxTarget(sel: String): View   = attr("hx-target", sel)
    pub def hxSwap(mode: String): View    = attr("hx-swap", mode)
    pub def hxTrigger(ev: String): View   = attr("hx-trigger", ev)

    // --- Document & Section Elements ---

    pub def html(items: Vector[View]): View       = View.Elem("html", items)
    pub def head(items: Vector[View]): View       = View.Elem("head", items)
    pub def title(items: Vector[View]): View      = View.Elem("title", items)
    pub def body(items: Vector[View]): View       = View.Elem("body", items)
    pub def header(items: Vector[View]): View     = View.Elem("header", items)
    pub def footer(items: Vector[View]): View     = View.Elem("footer", items)
    pub def main_(items: Vector[View]): View      = View.Elem("main", items)
    pub def nav(items: Vector[View]): View        = View.Elem("nav", items)
    pub def section(items: Vector[View]): View    = View.Elem("section", items)
    pub def article(items: Vector[View]): View    = View.Elem("article", items)
    pub def aside(items: Vector[View]): View      = View.Elem("aside", items)
    pub def div(items: Vector[View]): View        = View.Elem("div", items)

    // --- Headings & Text Content ---

    pub def h1(items: Vector[View]): View         = View.Elem("h1", items)
    pub def h2(items: Vector[View]): View         = View.Elem("h2", items)
    pub def h3(items: Vector[View]): View         = View.Elem("h3", items)
    pub def h4(items: Vector[View]): View         = View.Elem("h4", items)
    pub def h5(items: Vector[View]): View         = View.Elem("h5", items)
    pub def h6(items: Vector[View]): View         = View.Elem("h6", items)
    pub def p(items: Vector[View]): View          = View.Elem("p", items)
    pub def span(items: Vector[View]): View       = View.Elem("span", items)
    pub def a(items: Vector[View]): View          = View.Elem("a", items)
    pub def strong(items: Vector[View]): View     = View.Elem("strong", items)
    pub def em(items: Vector[View]): View         = View.Elem("em", items)
    pub def small(items: Vector[View]): View      = View.Elem("small", items)
    pub def code(items: Vector[View]): View       = View.Elem("code", items)
    pub def pre(items: Vector[View]): View        = View.Elem("pre", items)
    pub def blockquote(items: Vector[View]): View = View.Elem("blockquote", items)
    pub def details(items: Vector[View]): View    = View.Elem("details", items)
    pub def summary(items: Vector[View]): View    = View.Elem("summary", items)
    pub def figure(items: Vector[View]): View     = View.Elem("figure", items)
    pub def figcaption(items: Vector[View]): View = View.Elem("figcaption", items)

    // --- Lists & Tables ---

    pub def ul(items: Vector[View]): View         = View.Elem("ul", items)
    pub def ol(items: Vector[View]): View         = View.Elem("ol", items)
    pub def li(items: Vector[View]): View         = View.Elem("li", items)
    pub def dl(items: Vector[View]): View         = View.Elem("dl", items)
    pub def dt(items: Vector[View]): View         = View.Elem("dt", items)
    pub def dd(items: Vector[View]): View         = View.Elem("dd", items)
    pub def table(items: Vector[View]): View      = View.Elem("table", items)
    pub def thead(items: Vector[View]): View      = View.Elem("thead", items)
    pub def tbody(items: Vector[View]): View      = View.Elem("tbody", items)
    pub def tfoot(items: Vector[View]): View      = View.Elem("tfoot", items)
    pub def tr(items: Vector[View]): View         = View.Elem("tr", items)
    pub def th(items: Vector[View]): View         = View.Elem("th", items)
    pub def td(items: Vector[View]): View         = View.Elem("td", items)

    // --- Forms & Interactive Elements ---

    pub def form(items: Vector[View]): View       = View.Elem("form", items)
    pub def label(items: Vector[View]): View      = View.Elem("label", items)
    pub def button(items: Vector[View]): View     = View.Elem("button", items)
    pub def select_(items: Vector[View]): View    = View.Elem("select", items)
    pub def optgroup(items: Vector[View]): View   = View.Elem("optgroup", items)
    pub def option(items: Vector[View]): View     = View.Elem("option", items)
    pub def textarea(items: Vector[View]): View   = View.Elem("textarea", items)
    pub def fieldset(items: Vector[View]): View   = View.Elem("fieldset", items)
    pub def legend(items: Vector[View]): View     = View.Elem("legend", items)

    // --- Embedded Resources & Void Elements ---

    pub def style(items: Vector[View]): View      = View.Elem("style", items)
    pub def script(items: Vector[View]): View     = View.Elem("script", items)
    pub def input(items: Vector[View]): View      = View.VoidElem("input", items)
    pub def imgEl(items: Vector[View]): View      = View.VoidElem("img", items)
    pub def linkTag(items: Vector[View]): View    = View.VoidElem("link", items)
    pub def metaTag(items: Vector[View]): View    = View.VoidElem("meta", items)
    pub def br(): View                            = View.Raw("<br>")
    pub def hr(): View                            = View.Raw("<hr>")

    // --- Ergonomic One-Liner Shorthands ---

    pub def titleText(s: String): View   = elText("title", s)
    pub def h1Text(s: String): View      = elText("h1", s)
    pub def h2Text(s: String): View      = elText("h2", s)
    pub def h3Text(s: String): View      = elText("h3", s)
    pub def pText(s: String): View       = elText("p", s)
    pub def spanText(s: String): View    = elText("span", s)
    pub def liText(s: String): View      = elText("li", s)
    pub def thText(s: String): View      = elText("th", s)
    pub def tdText(s: String): View      = elText("td", s)
    pub def codeText(s: String): View    = elText("code", s)
    pub def strongText(s: String): View  = elText("strong", s)
    pub def emText(s: String): View      = elText("em", s)

    pub def link(url: String, labelText: String): View =
        View.Raw("<a href=\"" + Html.escapeHtml(url) + "\">" + Html.escapeHtml(labelText) + "</a>")

    pub def img(imgSrc: String, imgAlt: String): View =
        View.Raw("<img src=\"" + Html.escapeHtml(imgSrc) + "\" alt=\"" + Html.escapeHtml(imgAlt) + "\">")

    pub def metaCharset(charset: String): View =
        View.Raw("<meta charset=\"" + Html.escapeHtml(charset) + "\">")

    pub def metaViewport(): View =
        View.Raw("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")

    pub def meta(metaName: String, content: String): View =
        View.Raw("<meta name=\"" + Html.escapeHtml(metaName) + "\" content=\"" + Html.escapeHtml(content) + "\">")

    pub def stylesheet(url: String): View =
        View.Raw("<link rel=\"stylesheet\" href=\"" + Html.escapeHtml(url) + "\">")

    pub def scriptSrc(url: String): View =
        View.Raw("<script src=\"" + Html.escapeHtml(url) + "\" defer></script>")

    pub def inlineStyle(css: String): View =
        View.Raw("<style>" + css + "</style>")

    // --- Single-Pass Streaming Renderer (Zero Effect Overhead) ---

    def renderNode(v: View, sb: StringBuilder[r]): Unit \ r = match v {
        case View.Empty           => ()
        case View.Text(s)         => appendEscaped(s, sb)
        case View.Raw(s)          => StringBuilder.appendString(s, sb)
        case View.Attr(_, _)      => ()
        case View.Class(_)        => ()
        case View.Frag(items)     => renderVectorChildren(items, sb)
        case View.ListFrag(items) => renderListChildren(items, sb)
        case View.VoidElem(tag, items) =>
            StringBuilder.append('<', sb);
            StringBuilder.appendString(tag, sb);
            writeAttrs(items, sb);
            StringBuilder.append('>', sb)
        case View.Elem(tag, items) =>
            StringBuilder.append('<', sb);
            StringBuilder.appendString(tag, sb);
            writeAttrs(items, sb);
            StringBuilder.append('>', sb);
            renderVectorChildren(items, sb);
            StringBuilder.appendString("</", sb);
            StringBuilder.appendString(tag, sb);
            StringBuilder.append('>', sb)
    }

    def renderVectorChildren(items: Vector[View], sb: StringBuilder[r]): Unit \ r = {
        let len = Vector.length(items);
        def loop(i) =
            if (i >= len) ()
            else {
                renderNode(Vector.get(i, items), sb);
                loop(i + 1)
            };
        loop(0)
    }

    def renderListChildren(items: List[View], sb: StringBuilder[r]): Unit \ r = match items {
        case Nil => ()
        case x :: rest =>
            renderNode(x, sb);
            renderListChildren(rest, sb)
    }

    def writeAttrs(items: Vector[View], sb: StringBuilder[r]): Unit \ r = {
        let openedClass = writeVectorClasses(items, false, sb);
        if (openedClass) StringBuilder.append('"', sb) else ();
        writeVectorNonClassAttrs(items, sb)
    }

    def writeVectorClasses(items: Vector[View], opened: Bool, sb: StringBuilder[r]): Bool \ r = {
        let len = Vector.length(items);
        def loop(i, isOpen) =
            if (i >= len) isOpen
            else {
                let nextOpen = writeNodeClasses(Vector.get(i, items), isOpen, sb);
                loop(i + 1, nextOpen)
            };
        loop(0, opened)
    }

    def writeListClasses(items: List[View], opened: Bool, sb: StringBuilder[r]): Bool \ r = match items {
        case Nil => opened
        case x :: rest =>
            let nextOpen = writeNodeClasses(x, opened, sb);
            writeListClasses(rest, nextOpen, sb)
    }

    def writeNodeClasses(v: View, opened: Bool, sb: StringBuilder[r]): Bool \ r = match v {
        case View.Class(c) =>
            if (opened) StringBuilder.append(' ', sb)
            else StringBuilder.appendString(" class=\"", sb);
            appendEscaped(c, sb);
            true
        case View.Attr("class", Some(c)) =>
            let trimmed = String.trim(c);
            if (String.isEmpty(trimmed)) opened
            else {
                if (opened) StringBuilder.append(' ', sb)
                else StringBuilder.appendString(" class=\"", sb);
                appendEscaped(trimmed, sb);
                true
            }
        case View.Frag(sub)     => writeVectorClasses(sub, opened, sb)
        case View.ListFrag(sub) => writeListClasses(sub, opened, sb)
        case _                  => opened
    }

    def writeVectorNonClassAttrs(items: Vector[View], sb: StringBuilder[r]): Unit \ r = {
        let len = Vector.length(items);
        def loop(i) =
            if (i >= len) ()
            else {
                writeNodeNonClassAttrs(Vector.get(i, items), sb);
                loop(i + 1)
            };
        loop(0)
    }

    def writeListNonClassAttrs(items: List[View], sb: StringBuilder[r]): Unit \ r = match items {
        case Nil => ()
        case x :: rest =>
            writeNodeNonClassAttrs(x, sb);
            writeListNonClassAttrs(rest, sb)
    }

    def writeNodeNonClassAttrs(v: View, sb: StringBuilder[r]): Unit \ r = match v {
        case View.Attr(k, vOpt) if k != "class" =>
            StringBuilder.append(' ', sb);
            StringBuilder.appendString(k, sb);
            match vOpt {
                case None => ()
                case Some(valStr) =>
                    StringBuilder.appendString("=\"", sb);
                    appendEscaped(valStr, sb);
                    StringBuilder.append('"', sb)
            }
        case View.Frag(sub)     => writeVectorNonClassAttrs(sub, sb)
        case View.ListFrag(sub) => writeListNonClassAttrs(sub, sb)
        case _                  => ()
    }

    def appendEscaped(s: String, sb: StringBuilder[r]): Unit \ r = {
        let len = String.length(s);
        def needsEsc(i) =
            if (i >= len) false
            else {
                let c = String.charAt(i, s);
                if (c == '&' or c == '<' or c == '>' or c == '"' or c == '\'') true
                else needsEsc(i + 1)
            };
        if (not needsEsc(0))
            StringBuilder.appendString(s, sb)
        else {
            def loop(i) =
                if (i >= len) ()
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
    }

}
