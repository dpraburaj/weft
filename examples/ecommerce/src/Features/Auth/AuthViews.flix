mod Features.Auth.AuthViews {
    use weft::Weft.Csrf
    use weft::Weft.Html
    use weft::Weft.Html.{
        action, attr, button, cls, codeText, div, for_, form, h1Text, id, input,
        label, link, method, name, p, raw, strongText, text, type_, value, whenSome
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.ValidationErrors

    pub def loginPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        emailVal: String,
        errOpt: Option[String],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyHtml = Html.renderString(() -> renderLoginBody(csrfTok, emailVal, errOpt));
        Shared.Layout.renderShell("Sign In", csrfTok, userOpt, cartCount, flashOk, flashErr, bodyHtml)
    }

    pub def registerPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        nameVal: String,
        emailVal: String,
        errs: ValidationErrors
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        let bodyHtml = Html.renderString(() -> renderRegisterBody(csrfTok, nameVal, emailVal, errs));
        Shared.Layout.renderShell("Create Account", csrfTok, userOpt, cartCount, None, None, bodyHtml)
    }

    // --- Pure HTML Sections ---

    def renderLoginBody(csrfTok: String, emailVal: String, errOpt: Option[String]): Unit \ Html =
        div(() -> {
            cls("panel");
            attr("style", "max-width:460px;margin:1rem auto");
            h1Text("Sign In");
            whenSome(errOpt, msg -> div(() -> { cls("flash flash-err"); text(msg) }));
            form(() -> {
                method("post");
                action("/login");
                Shared.Layout.csrfInput(csrfTok);
                div(() -> {
                    cls("form-group");
                    label(() -> { for_("email"); text("Email") });
                    input(() -> { id("email"); type_("email"); name("email"); value(emailVal) })
                });
                div(() -> {
                    cls("form-group");
                    label(() -> { for_("password"); text("Password") });
                    input(() -> { id("password"); type_("password"); name("password") })
                });
                button(() -> { type_("submit"); attr("style", "width:100%"); text("Sign In") })
            });
            p(() -> {
                cls("muted");
                attr("style", "margin-top:1rem;font-size:0.88rem");
                text("New to Weft Roasters? ");
                link("/register", "Create an account")
            });
            div(() -> {
                attr("style", "margin-top:1rem;padding:0.75rem;background:var(--surface-alt);border:1px solid var(--border);border-radius:2px;font-size:0.84rem");
                strongText("Demo accounts: ");
                codeText("ada@example.com / coffee123");
                text(" (customer) or ");
                codeText("admin@weftroasters.com / admin123");
                text(" (admin)")
            })
        })

    def renderRegisterBody(
        csrfTok: String,
        nameVal: String,
        emailVal: String,
        errs: ValidationErrors
    ): Unit \ Html =
        div(() -> {
            cls("panel");
            attr("style", "max-width:460px;margin:1rem auto");
            h1Text("Create Account");
            form(() -> {
                method("post");
                action("/register");
                Shared.Layout.csrfInput(csrfTok);
                Shared.Layout.textField("name", "Full Name", nameVal, errs);
                div(() -> {
                    cls("form-group");
                    label(() -> { for_("email"); text("Email") });
                    input(() -> { id("email"); type_("email"); name("email"); value(emailVal) });
                    ValidationErrors.renderFieldError("email", errs)
                });
                div(() -> {
                    cls("form-group");
                    label(() -> { for_("password"); text("Password (min 6 characters)") });
                    input(() -> { id("password"); type_("password"); name("password") });
                    ValidationErrors.renderFieldError("password", errs)
                });
                button(() -> { type_("submit"); attr("style", "width:100%"); text("Create Account") })
            });
            p(() -> {
                cls("muted");
                attr("style", "margin-top:1rem;font-size:0.88rem");
                text("Already have an account? ");
                link("/login", "Sign in")
            })
        })

}
