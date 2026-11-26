mod BookmarkDomain {
    use weft::Weft.Json

    pub type alias Bookmark = {
        id = Int32,
        title = String,
        url = String,
        createdBy = String
    }

    ///
    /// Custom domain effect for bookmark persistence.
    /// Route handlers depend ONLY on this effect — never on a concrete database or `IO`.
    ///
    pub eff BookmarkStore {
        def listAll(): List[Bookmark]
        def findById(id: Int32): Option[Bookmark]
        def create(title: String, url: String, createdBy: String): Bookmark
        def remove(id: Int32): Bool
    }

    ///
    /// Custom domain effect for emitting notifications when bookmarks change.
    ///
    pub eff Notifier {
        def notify(event: String, detail: String): Unit
    }

    pub def bookmarkToJson(b: Bookmark): Json =
        Json.obj(
            ("id", Json.int(b#id)) ::
            ("title", Json.str(b#title)) ::
            ("url", Json.str(b#url)) ::
            ("createdBy", Json.str(b#createdBy)) ::
            Nil
        )

    ///
    /// 100% PURE in-memory handler for `BookmarkStore` scoped to a Flix `region`.
    /// Ideal for deterministic, zero-IO unit tests!
    ///
    pub def runStorePure(
        seed: List[Bookmark],
        f: Unit -> a \ ef
    ): a \ (ef - BookmarkStore) = region rc {
        let initialNextId = List.foldLeft((acc, b) -> Int32.max(acc, b#id), 0, seed) + 1;
        let itemsRef = Ref.fresh(rc, seed);
        let nextIdRef = Ref.fresh(rc, initialNextId);
        run {
            f()
        } with handler BookmarkStore {
            def listAll(k) =
                k(List.reverse(Ref.get(itemsRef)))
            def findById(id, k) =
                k(List.find(b -> b#id == id, Ref.get(itemsRef)))
            def create(title, url, createdBy, k) = {
                let id = Ref.get(nextIdRef);
                Ref.put(id + 1, nextIdRef);
                let item = { id = id, title = title, url = url, createdBy = createdBy };
                Ref.transform(xs -> item :: xs, itemsRef);
                k(item)
            }
            def remove(id, k) = {
                let current = Ref.get(itemsRef);
                let existed = List.exists(b -> b#id == id, current);
                if (existed) Ref.put(List.filter(b -> b#id != id, current), itemsRef) else ();
                k(existed)
            }
        }
    }

    ///
    /// 100% PURE collecting handler for `Notifier` returning `(result, events)`.
    ///
    pub def runNotifierCollecting(f: Unit -> a \ ef): (a, List[(String, String)]) \ (ef - Notifier) =
        region rc {
            let events = Ref.fresh(rc, Nil);
            let result = run {
                f()
            } with handler Notifier {
                def notify(event, detail, k) = {
                    Ref.transform(xs -> (event, detail) :: xs, events);
                    k()
                }
            };
            (result, List.reverse(Ref.get(events)))
        }

}

mod BookmarkApp {
    use BookmarkDomain.BookmarkStore
    use BookmarkDomain.Notifier
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Auth
    use weft::Weft.CorsConfig
    use weft::Weft.HttpError
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.Principal
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Status
    use weft::Weft.WithStatus

    ///
    /// Simple token verifier for demo purposes.
    ///
    pub def verifyToken(token: String): Option[Principal] = match token {
        case "editor-token" => Some(Principal.make("u-1", "ada", "editor" :: Nil))
        case "viewer-token" => Some(Principal.make("u-2", "bob", "viewer" :: Nil))
        case _              => None
    }

    def listBookmarks(): Json \ BookmarkStore = {
        let items = BookmarkStore.listAll();
        Json.obj(
            ("count", Json.int(List.length(items))) ::
            ("bookmarks", Json.arr(List.map(BookmarkDomain.bookmarkToJson, items))) ::
            Nil
        )
    }

    def getBookmark(): Json \ {Req, HttpError, BookmarkStore} = {
        let id = Req.requireIntParam("id");
        let item = BookmarkStore.findById(id)
            |> HttpError.orNotFound("Bookmark #${id} not found");
        BookmarkDomain.bookmarkToJson(item)
    }

    def createBookmark(): WithStatus[Json] \ {Req, HttpError, Auth, BookmarkStore, Notifier} = {
        Auth.requireRole("editor");
        let body = Req.jsonBody();
        let title = Json.requireNonEmptyString("title", body);
        let url = Json.requireNonEmptyString("url", body);
        HttpError.ensure(
            String.startsWith({prefix = "http://"}, url) or String.startsWith({prefix = "https://"}, url),
            Status.badRequest(),
            "Field 'url' must start with http:// or https://"
        );
        let created = BookmarkStore.create(title, url, Auth.userName());
        Notifier.notify("bookmark.created", "${Auth.userName()} added '${title}'");
        WithStatus.WithStatus(Status.created(), BookmarkDomain.bookmarkToJson(created))
    }

    def deleteBookmark(): Response \ {Req, HttpError, Auth, BookmarkStore, Notifier} = {
        Auth.requireRole("editor");
        let id = Req.requireIntParam("id");
        let removed = BookmarkStore.remove(id);
        HttpError.ensure(removed, Status.notFound(), "Bookmark #${id} not found");
        Notifier.notify("bookmark.deleted", "${Auth.userName()} deleted #${id}");
        Response.noContent()
    }

    ///
    /// Notice the inferred/declared effect row:
    /// `App[{BookmarkStore, Notifier, Logger, Clock}]`
    ///
    /// `Req`, `Res`, `Auth`, and `HttpError` have all been discharged by the router &
    /// middleware — leaving ONLY your domain and observability effects!
    ///
    pub def buildApp(): App[{BookmarkStore, Notifier, Logger, Clock}] = {
        let writeRoutes = Router.empty()
            |> Router.post("/bookmarks", createBookmark)
            |> Router.delete("/bookmarks/:id", deleteBookmark)
            |> Router.withMiddleware(Middleware.bearerAuth(verifyToken));

        Router.empty()
            |> Router.get("/bookmarks", listBookmarks)
            |> Router.get("/bookmarks/:id", getBookmark)
            |> Router.merge(writeRoutes)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.cors(CorsConfig.permissive())
            |> Middleware.timingHeader
            |> Middleware.requestLogger
    }

}

///
/// Thread-safe IO handler for `BookmarkStore` used when serving live traffic on
/// Java 21 virtual threads.
///
mod LiveBookmarkStore {
    use BookmarkDomain.Bookmark
    use BookmarkDomain.BookmarkStore

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    pub enum State {
        case State(ReentrantLock, Ref[Map[Int32, Bookmark], Static], Ref[Int32, Static])
    }

    pub def init(): State \ IO = {
        let first = { id = 1, title = "Flix Language", url = "https://flix.dev", createdBy = "system" };
        State.State(
            new ReentrantLock(),
            Ref.fresh(Static, Map.singleton(1, first)),
            Ref.fresh(Static, 2)
        )
    }

    def withLock(lock: ReentrantLock, action: Unit -> b \ IO): b \ IO = {
        lock.lock();
        try {
            let res = action();
            lock.unlock();
            res
        } catch {
            case ex: Exception =>
                lock.unlock();
                throw ex
        }
    }

    pub def runWithIO(state: State, f: Unit -> a \ ef): a \ (ef - BookmarkStore) + IO = {
        let State.State(lock, itemsRef, nextIdRef) = state;
        run {
            f()
        } with handler BookmarkStore {
            def listAll(k) = {
                let items = withLock(lock, () ->
                    Map.valuesOf(Ref.get(itemsRef)) |> List.sortBy(b -> b#id)
                );
                k(items)
            }
            def findById(id, k) = {
                let found = withLock(lock, () -> Map.get(id, Ref.get(itemsRef)));
                k(found)
            }
            def create(title, url, createdBy, k) = {
                let item = withLock(lock, () -> {
                    let id = Ref.get(nextIdRef);
                    Ref.put(id + 1, nextIdRef);
                    let b = { id = id, title = title, url = url, createdBy = createdBy };
                    Ref.transform(m -> Map.insert(id, b, m), itemsRef);
                    b
                });
                k(item)
            }
            def remove(id, k) = {
                let existed = withLock(lock, () -> {
                    let m = Ref.get(itemsRef);
                    if (Map.memberOf(id, m)) {
                        Ref.put(Map.remove(id, m), itemsRef);
                        true
                    } else {
                        false
                    }
                });
                k(existed)
            }
        }
    }

}

def main(): Unit \ IO = {
    use BookmarkDomain.Notifier;
    use Time.Clock;
    use weft::Weft.App;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;

    let storeState = LiveBookmarkStore.init();
    let app = BookmarkApp.buildApp();

    // The compiler statically verifies that EVERY custom effect (`BookmarkStore`,
    // `Notifier`, `Logger`, `Clock`) is handled before `Server.serve` will compile!
    let ioApp: App[IO] = req ->
        run {
            app(req)
        } with LiveBookmarkStore.runWithIO(storeState)
          with handler Notifier {
              def notify(event, detail, k) = {
                  Logger.info("[notify:${event}] ${detail}");
                  k()
              }
          }
          with Logger.runWithIO
          with Clock.runWithIO;

    println("Starting Weft Custom Effects (Bookmarks) server on http://127.0.0.1:8080");
    println("Try:");
    println("  curl http://127.0.0.1:8080/bookmarks");
    println("  curl -X POST http://127.0.0.1:8080/bookmarks \\");
    println("       -H 'Authorization: Bearer editor-token' \\");
    println("       -H 'Content-Type: application/json' \\");
    println("       -d '{\"title\":\"Weft\",\"url\":\"https://github.com/dpraburaj/weft\"}'");

    match Server.serve(ServerConfig.local(8080), ioApp) {
        case Ok(())   => ()
        case Err(msg) => println("Server error: ${msg}")
    }
}
