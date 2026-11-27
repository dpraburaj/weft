pub mod Features.Auth.AuthFeature {
    use Features.Auth.AuthViews
    use Features.Auth.UserStore
    use Features.Cart.CartStore
    use weft::Weft.Auth
    use weft::Weft.Crypto
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.IntoResponse
    use weft::Weft.OptionalAuth
    use weft::Weft.Random
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Session
    use weft::Weft.Status
    use weft::Weft.Validate
    use weft::Weft.ValidationErrors

    // --- Slice Route Builders ---

    pub def readRoutes(): Router[{Req, HttpError, OptionalAuth, Session, Random, CartStore}] =
        Router.empty()
            |> Router.get("/login", loginPage)
            |> Router.get("/register", registerPage)

    pub def mutationRoutes(passwordIterations: Int32): Router[{Req, HttpError, OptionalAuth, Session, Random, UserStore, CartStore}] =
        Router.empty()
            |> Router.post("/login", loginPost)
            |> Router.post("/register", () -> registerPost(passwordIterations))
            |> Router.post("/logout", logoutPost)

    // --- Handlers (Zero SQL / Zero `Db` coupling) ---

    pub def loginPage(): HtmlDoc \ {OptionalAuth, Session, Random, CartStore} = {
        let flashOk = Session.takeFlash("ok");
        let flashErr = Session.takeFlash("err");
        AuthViews.loginPage(OptionalAuth.current(), Shared.CartContext.currentCount(), "", None, flashOk, flashErr)
    }

    pub def loginPost(): Response \ {Req, HttpError, OptionalAuth, Session, Random, UserStore, CartStore} = {
        let form = Req.formParams();
        let email = Map.getWithDefault("email", "", form) |> String.trim;
        let pass = Map.getWithDefault("password", "", form);
        match UserStore.findByEmail(email) {
            case Some(user) if Crypto.verifyPassword(pass, user#passwordHash) =>
                let guestOpt = Session.get("guest_cart_key");
                Option.forEach(gk -> CartStore.mergeGuestIntoUser(gk, "user:${user#id}"), guestOpt);
                Session.remove("guest_cart_key");
                Auth.loginSession("${user#id}");
                Session.putFlash("ok", "Welcome back, ${user#name}!");
                Response.seeOther("/")
            case _ =>
                let doc = AuthViews.loginPage(
                    OptionalAuth.current(),
                    Shared.CartContext.currentCount(),
                    email,
                    Some("Invalid email or password."),
                    None,
                    None
                );
                IntoResponse.intoResponse(doc) |> Response.withStatus(Status.unprocessableEntity())
        }
    }

    pub def registerPage(): HtmlDoc \ {OptionalAuth, Session, Random, CartStore} =
        AuthViews.registerPage(OptionalAuth.current(), Shared.CartContext.currentCount(), "", "", ValidationErrors.empty())

    pub def registerPost(passwordIterations: Int32): Response \ {Req, HttpError, OptionalAuth, Session, Random, UserStore, CartStore} = {
        let form = Req.formParams();
        let ((name, email, pass), errs0) = Validate.collect(() -> {
            let n = Validate.requireNonEmpty("name", Map.get("name", form))
                |> Validate.minLength("name", 2);
            let e = Validate.requireEmail("email", Map.get("email", form));
            let pw = Validate.requireNonEmpty("password", Map.get("password", form))
                |> Validate.minLength("password", 6);
            (n, e, pw)
        });
        let errs =
            if (not String.isEmpty(email) and Option.nonEmpty(UserStore.findByEmail(email)))
                ValidationErrors.add("email", "An account with this email already exists", errs0)
            else
                errs0;

        if (not ValidationErrors.isEmpty(errs)) {
            let doc = AuthViews.registerPage(
                OptionalAuth.current(),
                Shared.CartContext.currentCount(),
                Map.getWithDefault("name", "", form),
                Map.getWithDefault("email", "", form),
                errs
            );
            IntoResponse.intoResponse(doc) |> Response.withStatus(Status.unprocessableEntity())
        } else {
            let hash = Crypto.hashPasswordWithIterations(passwordIterations, pass);
            let uid = UserStore.createUser(email, name, hash);
            let guestOpt = Session.get("guest_cart_key");
            Option.forEach(gk -> CartStore.mergeGuestIntoUser(gk, "user:${uid}"), guestOpt);
            Session.remove("guest_cart_key");
            Auth.loginSession("${uid}");
            Session.putFlash("ok", "Account created! Welcome to Weft Roasters, ${name}.");
            Response.seeOther("/")
        }
    }

    pub def logoutPost(): Response \ {Session} = {
        Auth.logoutSession();
        Response.seeOther("/")
    }

}
