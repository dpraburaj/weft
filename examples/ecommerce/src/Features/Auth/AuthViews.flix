mod Features.Auth.AuthViews {
    use weft::Weft.Csrf
    use weft::Weft.HtmlDoc
    use weft::Weft.Principal
    use weft::Weft.Random
    use weft::Weft.Session
    use weft::Weft.ValidationErrors
    use weft::Weft.View
    use weft::Weft.View.{
        action, attr, button, cls, codeText, div, for_, form, h1Text, id,
        input, label, link, method, name, p, strongText, text, type_, value,
        whenSome
    }

    pub def loginPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        emailVal: String,
        errOpt: Option[String],
        flashOk: Option[String],
        flashErr: Option[String]
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Shared.Layout.renderShell("Sign In", csrfTok, userOpt, cartCount, flashOk, flashErr, renderLoginBody(csrfTok, emailVal, errOpt))
    }

    pub def registerPage(
        userOpt: Option[Principal],
        cartCount: Int32,
        nameVal: String,
        emailVal: String,
        errs: ValidationErrors
    ): HtmlDoc \ {Session, Random} = {
        let csrfTok = Csrf.token();
        Shared.Layout.renderShell("Create Account", csrfTok, userOpt, cartCount, None, None, renderRegisterBody(csrfTok, nameVal, emailVal, errs))
    }

    // --- Pure View Sections ---

    def renderLoginBody(csrfTok: String, emailVal: String, errOpt: Option[String]): View =
        div(Vector#{
            cls("panel"),
            attr("style", "max-width:460px;margin:1rem auto"),
            h1Text("Sign In"),
            whenSome(errOpt, msg -> div(Vector#{ cls("flash flash-err"), text(msg) })),
            form(Vector#{
                method("post"),
                action("/login"),
                Shared.Layout.csrfInput(csrfTok),
                div(Vector#{
                    cls("form-group"),
                    label(Vector#{ for_("email"), text("Email") }),
                    input(Vector#{ id("email"), type_("email"), name("email"), value(emailVal) })
                }),
                div(Vector#{
                    cls("form-group"),
                    label(Vector#{ for_("password"), text("Password") }),
                    input(Vector#{ id("password"), type_("password"), name("password") })
                }),
                button(Vector#{ type_("submit"), attr("style", "width:100%"), text("Sign In") })
            }),
            p(Vector#{
                cls("muted"),
                attr("style", "margin-top:1rem;font-size:0.88rem"),
                text("New to Weft Roasters? "),
                link("/register", "Create an account")
            }),
            div(Vector#{
                attr("style", "margin-top:1rem;padding:0.75rem;background:var(--surface-alt);border:1px solid var(--border);border-radius:2px;font-size:0.84rem"),
                strongText("Demo accounts: "),
                codeText("ada@example.com / coffee123"),
                text(" (customer) or "),
                codeText("admin@weftroasters.com / admin123"),
                text(" (admin)")
            })
        })

    def renderRegisterBody(
        csrfTok: String,
        nameVal: String,
        emailVal: String,
        errs: ValidationErrors
    ): View =
        div(Vector#{
            cls("panel"),
            attr("style", "max-width:460px;margin:1rem auto"),
            h1Text("Create Account"),
            form(Vector#{
                method("post"),
                action("/register"),
                Shared.Layout.csrfInput(csrfTok),
                Shared.Layout.textField("name", "Full Name", nameVal, errs),
                div(Vector#{
                    cls("form-group"),
                    label(Vector#{ for_("email"), text("Email") }),
                    input(Vector#{ id("email"), type_("email"), name("email"), value(emailVal) }),
                    ValidationErrors.fieldErrorView("email", errs)
                }),
                div(Vector#{
                    cls("form-group"),
                    label(Vector#{ for_("password"), text("Password (min 6 characters)") }),
                    input(Vector#{ id("password"), type_("password"), name("password") }),
                    ValidationErrors.fieldErrorView("password", errs)
                }),
                button(Vector#{ type_("submit"), attr("style", "width:100%"), text("Create Account") })
            }),
            p(Vector#{
                cls("muted"),
                attr("style", "margin-top:1rem;font-size:0.88rem"),
                text("Already have an account? "),
                link("/login", "Sign in")
            })
        })

}
