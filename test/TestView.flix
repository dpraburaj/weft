mod TestView {
    use Assert.assertEq
    use Assert.assertTrue
    use Weft.HtmlDoc
    use Weft.Middleware
    use Weft.Request
    use Weft.Response
    use Weft.Router
    use Weft.Status
    use Weft.TestClient
    use Weft.ValidationErrors
    use Weft.View
    use Weft.View.{
        a, action, attr, boolAttr, br, button, checked, cls, clsIf, data,
        disabled, div, each, form, frag, h1Text, hr, hxGet, hxSwap, hxTarget,
        img, input, li, link, main_, method, name, pText, raw, required,
        spanText, stylesheet, text, type_, ul, when, whenSome
    }

    @Test
    def testPureViewEscapingClassMergingAndVoidElements(): Unit \ Assert = {
        let v = form(Vector#{
            cls("card"),
            clsIf(true, "card-active"),
            clsIf(false, "card-hidden"),
            attr("class", "padded"),
            action("/submit"),
            method("post"),
            attr("data-msg", "a \"quoted\" & <tag>"),
            input(Vector#{
                type_("checkbox"),
                name("agree"),
                checked(),
                boolAttr("disabled", false),
                required()
            }),
            br(),
            hr(),
            pText("<script>alert('xss')</script> & \"friends\""),
            raw("<!-- trusted -->"),
            button(Vector#{ type_("submit"), disabled(), text("Save") })
        });

        assertEq(
            expected = "<form class=\"card card-active padded\" action=\"/submit\" method=\"post\" data-msg=\"a &quot;quoted&quot; &amp; &lt;tag&gt;\"><input type=\"checkbox\" name=\"agree\" checked required><br><hr><p>&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt; &amp; &quot;friends&quot;</p><!-- trusted --><button type=\"submit\" disabled>Save</button></form>",
            View.renderString(v)
        )
    }

    @Test
    def testPureViewControlFlowFragmentsAndNestedAttrs(): Unit \ Assert = {
        let items = "Alpha" :: "Beta" :: Nil;
        let banner: Option[String] = Some("Saved!");
        let emptyBanner: Option[String] = None;
        let sharedAttrs = frag(Vector#{ cls("btn"), attr("data-kind", "primary") });

        let v = main_(Vector#{
            whenSome(banner, msg -> div(Vector#{ cls("alert"), text(msg) })),
            whenSome(emptyBanner, msg -> div(Vector#{ text(msg) })),
            when(true, h1Text("Items")),
            when(false, h1Text("Hidden")),
            ul(Vector#{
                each(items, item ->
                    li(Vector#{
                        data("item", item),
                        link("/items/${item}", item)
                    })
                )
            }),
            button(Vector#{
                sharedAttrs,
                cls("btn-lg"),
                hxGet("/more"),
                hxTarget("#list"),
                hxSwap("beforeend"),
                text("Load more")
            })
        });

        assertEq(
            expected = "<main><div class=\"alert\">Saved!</div><h1>Items</h1><ul><li data-item=\"Alpha\"><a href=\"/items/Alpha\">Alpha</a></li><li data-item=\"Beta\"><a href=\"/items/Beta\">Beta</a></li></ul><button class=\"btn btn-lg\" data-kind=\"primary\" hx-get=\"/more\" hx-target=\"#list\" hx-swap=\"beforeend\">Load more</button></main>",
            View.renderString(v)
        )
    }

    @Test
    def testPureViewPageWithHeadIntoResponseAndValidationFieldError(): Unit \ Assert = {
        let doc = View.pageWithHead(
            "My <App>",
            stylesheet("/app.css"),
            frag(Vector#{
                h1Text("Hello"),
                img("/logo.png", "Weft Logo")
            })
        );
        assertEq(
            expected = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>My &lt;App&gt;</title><link rel=\"stylesheet\" href=\"/app.css\"></head><body><h1>Hello</h1><img src=\"/logo.png\" alt=\"Weft Logo\"></body></html>",
            HtmlDoc.toHtmlString(doc)
        );

        let errs = ValidationErrors.empty() |> ValidationErrors.add("email", "Invalid email");
        assertEq(
            expected = "<p class=\"field-error\" role=\"alert\">Invalid email</p>",
            View.renderString(ValidationErrors.fieldErrorView("email", errs))
        );
        assertEq(expected = "", View.renderString(ValidationErrors.fieldErrorView("name", errs)));

        // Direct `IntoResponse[View]` support in routes
        let app = Router.empty()
            |> Router.get("/hello", () -> div(Vector#{ cls("hi"), spanText("Pure View!") }))
            |> Router.toApp
            |> Middleware.errorHtml;
        let res = TestClient.get("/hello", app);
        assertEq(expected = Status.ok(), Response.status(res));
        assertEq(expected = Some("text/html; charset=utf-8"), Response.header("Content-Type", res));
        assertTrue(Response.body(res) == "<div class=\"hi\"><span>Pure View!</span></div>")
    }

}
