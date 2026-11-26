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

    type alias Frame = {
        tag      = String,
        isVoid   = Bool,
        classes  = List[String],
        attrs    = List[(String, Option[String])],
        children = List[String]
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
    pub def renderString(f: Unit -> Unit \ ef): String \ (ef - Html) = region rc {
        let rootFrame: Frame = {
            tag      = "",
            isVoid   = false,
            classes  = Nil,
            attrs    = Nil,
            children = Nil
        };
        let stack: Ref[List[Frame], rc] = Ref.fresh(rc, rootFrame :: Nil);

        def updateTop(fn: Frame -> Frame): Unit \ rc = {
            match Ref.get(stack) {
                case top :: rest => Ref.put(fn(top) :: rest, stack)
                case Nil         => ()
            }
        };

        run {
            f()
        } with handler Html {
            def openTag(tag, isVoid, k) = {
                let frame: Frame = {
                    tag      = tag,
                    isVoid   = isVoid,
                    classes  = Nil,
                    attrs    = Nil,
                    children = Nil
                };
                Ref.transform(s -> frame :: s, stack);
                k()
            }
            def closeTag(k) = {
                match Ref.get(stack) {
                    case top :: parent :: rest =>
                        let rendered = renderFrame(top);
                        let updatedParent = { children = rendered :: parent#children | parent };
                        Ref.put(updatedParent :: rest, stack)
                    case _ =>
                        ()
                };
                k()
            }
            def addAttr(name, valOpt, k) = {
                if (name == "class") {
                    match valOpt {
                        case Some(c) =>
                            let trimmed = String.trim(c);
                            if (not String.isEmpty(trimmed))
                                updateTop(fr -> { classes = trimmed :: fr#classes | fr })
                            else
                                ()
                        case None => ()
                    }
                } else {
                    updateTop(fr -> { attrs = (name, valOpt) :: fr#attrs | fr })
                };
                k()
            }
            def addClass(className, k) = {
                let trimmed = String.trim(className);
                if (not String.isEmpty(trimmed))
                    updateTop(fr -> { classes = trimmed :: fr#classes | fr })
                else
                    ();
                k()
            }
            def addText(content, k) = {
                let escaped = escapeHtml(content);
                updateTop(fr -> { children = escaped :: fr#children | fr });
                k()
            }
            def addRaw(content, k) = {
                updateTop(fr -> { children = content :: fr#children | fr });
                k()
            }
        };

        // Flush any unclosed frames safely, then join root children in order
        let finalFrames = Ref.get(stack);
        let root = flushStack(finalFrames);
        joinStrings(List.reverse(root#children))
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
        document(() ->
            html(() -> {
                lang("en");
                head(() -> {
                    metaCharset("utf-8");
                    metaViewport();
                    titleText(pageTitle);
                    extraHead()
                });
                body(bodyContent)
            })
        )

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
        el(tag, () -> text(content))

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
    pub def br(): Unit \ Html                                  = voidEl("br", () -> ())
    pub def hr(): Unit \ Html                                  = voidEl("hr", () -> ())

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
        a(() -> { href(url); text(labelText) })

    ///
    /// Emits `<img src="..." alt="...">`.
    ///
    pub def img(imgSrc: String, imgAlt: String): Unit \ Html =
        imgEl(() -> { src(imgSrc); alt(imgAlt) })

    ///
    /// Emits `<meta charset="...">`.
    ///
    pub def metaCharset(charset: String): Unit \ Html =
        metaTag(() -> attr("charset", charset))

    ///
    /// Emits `<meta name="viewport" content="width=device-width, initial-scale=1">`.
    ///
    pub def metaViewport(): Unit \ Html =
        meta("viewport", "width=device-width, initial-scale=1")

    ///
    /// Emits `<meta name="..." content="...">`.
    ///
    pub def meta(metaName: String, content: String): Unit \ Html =
        metaTag(() -> { name(metaName); attr("content", content) })

    ///
    /// Emits `<link rel="stylesheet" href="...">`.
    ///
    pub def stylesheet(url: String): Unit \ Html =
        linkTag(() -> { rel("stylesheet"); href(url) })

    ///
    /// Emits `<script src="..." defer></script>`.
    ///
    pub def scriptSrc(url: String): Unit \ Html =
        script(() -> { src(url); defer() })

    ///
    /// Emits `<style>rawCss</style>`.
    ///
    pub def inlineStyle(css: String): Unit \ Html =
        style(() -> raw(css))

    // --- Escaping & Internal Frame Rendering ---

    ///
    /// Escapes `&`, `<`, `>`, `"`, and `'` for safe HTML text and attribute rendering.
    ///
    pub def escapeHtml(s: String): String = region rc {
        let sb = StringBuilder.empty(rc);
        let len = String.length(s);
        def loop(i) = {
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
            }
        };
        loop(0);
        StringBuilder.toString(sb)
    }

    def renderFrame(fr: Frame): String = region rc {
        let sb = StringBuilder.empty(rc);
        StringBuilder.append('<', sb);
        StringBuilder.appendString(fr#tag, sb);

        // Emit merged `class` attribute if any classes were attached
        let orderedClasses = List.reverse(fr#classes);
        if (not List.isEmpty(orderedClasses)) {
            StringBuilder.appendString(" class=\"", sb);
            StringBuilder.appendString(escapeHtml(String.intercalate(" ", orderedClasses)), sb);
            StringBuilder.append('"', sb)
        } else ();

        // Emit remaining attributes in insertion order
        List.forEach(match (k, vOpt) -> {
            StringBuilder.append(' ', sb);
            StringBuilder.appendString(k, sb);
            match vOpt {
                case None => ()
                case Some(v) =>
                    StringBuilder.appendString("=\"", sb);
                    StringBuilder.appendString(escapeHtml(v), sb);
                    StringBuilder.append('"', sb)
            }
        }, List.reverse(fr#attrs));

        StringBuilder.append('>', sb);

        if (not fr#isVoid) {
            List.forEach(chunk -> StringBuilder.appendString(chunk, sb), List.reverse(fr#children));
            StringBuilder.appendString("</", sb);
            StringBuilder.appendString(fr#tag, sb);
            StringBuilder.append('>', sb)
        } else ();

        StringBuilder.toString(sb)
    }

    def flushStack(frames: List[Frame]): Frame = match frames {
        case single :: Nil =>
            single
        case top :: parent :: rest =>
            let rendered = renderFrame(top);
            let updatedParent = { children = rendered :: parent#children | parent };
            flushStack(updatedParent :: rest)
        case Nil =>
            { tag = "", isVoid = false, classes = Nil, attrs = Nil, children = Nil }
    }

    def joinStrings(xs: List[String]): String = region rc {
        let sb = StringBuilder.empty(rc);
        List.forEach(s -> StringBuilder.appendString(s, sb), xs);
        StringBuilder.toString(sb)
    }

}
