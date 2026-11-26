pub mod Weft.Res {
    use Weft.Cookie
    use Weft.Res
    use Weft.Response
    use Weft.Status

    ///
    /// Algebraic effect for ambiently attaching response headers, cookies, or a
    /// status override from anywhere within a handler's call stack.
    ///
    pub eff Res {
        def setHeader(name: String, value: String): Unit
        def addHeader(name: String, value: String): Unit
        def setCookie(cookie: Cookie): Unit
        def setStatus(status: Status): Unit
    }

    enum ResOp {
        case SetHeader(String, String)
        case AddHeader(String, String)
        case SetCookie(Cookie)
        case SetStatus(Status)
    }

    ///
    /// Convenience helper to delete a cookie by emitting an expired `Set-Cookie` header.
    ///
    pub def deleteCookie(name: String): Unit \ Res =
        Res.setCookie(Cookie.expired(name))

    ///
    /// Handles the `Res` effect purely using a local region, collecting all ambient
    /// header/cookie/status updates and applying them to the returned `Response`.
    ///
    pub def runCollecting(f: Unit -> Response \ ef): Response \ (ef - Res) =
        region rc {
            let ops: Ref[List[ResOp], rc] = Ref.fresh(rc, Nil);
            let res = run {
                f()
            } with handler Res {
                def setHeader(name, value, k) = {
                    Ref.transform(xs -> ResOp.SetHeader(name, value) :: xs, ops);
                    k()
                }
                def addHeader(name, value, k) = {
                    Ref.transform(xs -> ResOp.AddHeader(name, value) :: xs, ops);
                    k()
                }
                def setCookie(c, k) = {
                    Ref.transform(xs -> ResOp.SetCookie(c) :: xs, ops);
                    k()
                }
                def setStatus(st, k) = {
                    Ref.transform(xs -> ResOp.SetStatus(st) :: xs, ops);
                    k()
                }
            };
            let ordered = List.reverse(Ref.get(ops));
            List.foldLeft((acc, op) -> match op {
                case ResOp.SetHeader(k, v) => Response.withHeader(k, v, acc)
                case ResOp.AddHeader(k, v) => Response.addHeader(k, v, acc)
                case ResOp.SetCookie(c)    => Response.withCookie(c, acc)
                case ResOp.SetStatus(st)   => Response.withStatus(st, acc)
            }, res, ordered)
        }

}
