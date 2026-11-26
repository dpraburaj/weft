mod TestHtml {
    use Assert.assertEq
    use Assert.assertTrue
    use Weft.Auth
    use Weft.Html
    use Weft.Html.{
        a, attr, attrIf, boolAttr, br, button, checked, cls, clsIf, data,
        disabled, div, each, form, h1, h1Text, href, hr, hxGet, hxSwap,
        hxTarget, id, img, input, li, link, main_, method, name, p, pText,
        placeholder, raw, required, span, spanText, stylesheet, text, type_,
        ul, when, whenSome, action
    }
    use Weft.HtmlDoc
    use Weft.HttpError
    use Weft.Middleware
    use Weft.Principal
    use Weft.Req
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Status
    use Weft.TestClient
    use Weft.WithStatus

    @Test
    def testEscapingAndRawHtml(): Unit \ Assert = {
        let rendered = Html.renderString(() ->
            div(() -> {
                attr("data-msg", "a \"quoted\" & <tag>");
                pText("<script>alert('xss')</script> & \"friends\"");
                raw("<!-- trusted -->")
            })
        );
        assertEq(
            expected = "<div data-msg=\"a &quot;quoted&quot; &amp; &lt;tag&gt;\"><p>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; &amp; &quot;friends&quot;</p><!-- trusted --></div>",
            rendered
        )
    }

    @Test
    def testClassMergingBooleanAttrsAndVoidElements(): Unit \ Assert = {
        let rendered = Html.renderString(() ->
            form(() -> {
                cls("card");
                clsIf(true, "card-active");
                clsIf(false, "card-hidden");
                attr("class", "padded");
                action("/submit");
                method("post");
                input(() -> {
                    type_("checkbox");
                    name("agree");
                    checked();
                    boolAttr("disabled", false);
                    required()
                });
                br();
                hr();
                button(() -> {
                    type_("submit");
                    disabled();
                    text("Save")
                })
            })
        );
        assertEq(
            expected = "<form class=\"card card-active padded\" action=\"/submit\" method=\"post\"><input type=\"checkbox\" name=\"agree\" checked required><br><hr><button type=\"submit\" disabled>Save</button></form>",
            rendered
        )
    }

    @Test
    def testControlFlowHelpersAndHtmxAttributes(): Unit \ Assert = {
        let items = "Alpha" :: "Beta" :: Nil;
        let banner: Option[String] = Some("Saved!");
        let emptyBanner: Option[String] = None;

        let rendered = Html.renderString(() ->
            main_(() -> {
                whenSome(banner, msg -> div(() -> { cls("alert"); text(msg) }));
                whenSome(emptyBanner, msg -> div(() -> text(msg)));
                when(true, () -> h1Text("Items"));
                when(false, () -> h1Text("Hidden"));
                ul(() ->
                    each(items, item ->
                        li(() -> {
                            data("item", item);
                            link("/items/${item}", item)
                        })
                    )
                );
                button(() -> {
                    hxGet("/more");
                    hxTarget("#list");
                    hxSwap("beforeend");
                    text("Load more")
                })
            })
        );
        assertEq(
            expected = "<main><div class=\"alert\">Saved!</div><h1>Items</h1><ul><li data-item=\"Alpha\"><a href=\"/items/Alpha\">Alpha</a></li><li data-item=\"Beta\"><a href=\"/items/Beta\">Beta</a></li></ul><button hx-get=\"/more\" hx-target=\"#list\" hx-swap=\"beforeend\">Load more</button></main>",
            rendered
        )
    }

    @Test
    def testPageShellWithHeadAndMediaShorthands(): Unit \ Assert = {
        let doc = Html.pageWithHead(
            "My <App>",
            () -> stylesheet("/app.css"),
            () -> {
                h1Text("Hello");
                img("/logo.png", "Weft Logo")
            }
        );
        assertEq(
            expected = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>My &lt;App&gt;</title><link rel=\"stylesheet\" href=\"/app.css\"></head><body><h1>Hello</h1><img src=\"/logo.png\" alt=\"Weft Logo\"></body></html>",
            HtmlDoc.toHtmlString(doc)
        )
    }

    @Test
    def testEffectPolymorphismIntoResponseAndErrorHtml(): Unit \ Assert = {
        // Component that directly uses BOTH `Html` AND `Auth` effects!
        def userBadge(): Unit \ {Html, Auth} =
            span(() -> {
                cls("user-badge");
                text("Signed in as ${Auth.userName()}")
            });

        let verify = tok -> if (tok == "tok") Some(Principal.make("1", "Ada <Lovelace>", Nil)) else None;

        let protectedRoutes = Router.empty()
            |> Router.get("/profile/:tab", () -> {
                let tab = Req.requireParam("tab");
                Html.page("Profile", () -> {
                    userBadge();
                    pText("Tab: ${tab}")
                })
            })
            |> Router.withMiddleware(Middleware.bearerAuth(verify));

        let app = Router.empty()
            |> Router.get("/created", () -> WithStatus.WithStatus(Status.created(), Html.render(() -> spanText("created"))))
            |> Router.merge(protectedRoutes)
            |> Router.toApp
            |> Middleware.errorHtml;

        let okRes = TestClient.send(Request.get("/profile/settings") |> Request.withBearer("tok"), app);
        assertEq(expected = Status.ok(), Response.status(okRes));
        assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", okRes));
        assertTrue(String.contains({substr = "Signed in as Ada &lt;Lovelace&gt;"}, Response.body(okRes)));
        assertTrue(String.contains({substr = "<p>Tab: settings</p>"}, Response.body(okRes)));

        // WithStatus[HtmlDoc] works seamlessly via IntoResponse
        let createdRes = TestClient.get("/created", app);
        assertEq(expected = Status.created(), Response.status(createdRes));
        assertEq(expected = "<span>created</span>", Response.body(createdRes));

        // 404 renders as escaped HTML via Middleware.errorHtml
        let r404 = TestClient.get("/missing/<bad>", app);
        assertEq(expected = Status.notFound(), Response.status(r404));
        assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", r404));
        assertTrue(String.contains({substr = "<h1>404 Not Found</h1>"}, Response.body(r404)));
        assertTrue(String.contains({substr = "&lt;bad&gt;"}, Response.body(r404)))
    }

}
