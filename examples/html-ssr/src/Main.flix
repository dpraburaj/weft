mod HtmlSsrApp {
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Html
    use weft::Weft.Html.{
        a, action, body, button, cls, clsIf, div, each, form, h1Text, header,
        href, id, inlineStyle, input, li, link, main_, method, name, nav, p,
        pText, placeholder, required, section, span, spanText, text, type_,
        ul, when, whenSome
    }
    use weft::Weft.HtmlDoc
    use weft::Weft.HttpError
    use weft::Weft.Middleware
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Status
    use weft::Weft.Url

    pub type alias Task = {
        id = Int32,
        title = String,
        done = Bool
    }

    pub eff TaskStore {
        def listTasks(): List[Task]
        def addTask(title: String): Task
        def toggleTask(id: Int32): Bool
    }

    ///
    /// Shared page layout component — notice how `bodyContent` is effect-polymorphic,
    /// so pages can call `TaskStore`, `Req`, etc. directly inside the layout!
    ///
    def layout(pageTitle: String, bodyContent: Unit -> Unit \ ef): HtmlDoc \ (ef - Html) =
        Html.pageWithHead(
            pageTitle,
            () -> inlineStyle(
                "body{font-family:system-ui,sans-serif;max-width:680px;margin:2rem auto;padding:0 1rem;color:#1f2937}" +
                ".card{border:1px solid #e5e7eb;border-radius:10px;padding:1.25rem;margin-top:1rem}" +
                ".done{text-decoration:line-through;color:#6b7280}" +
                ".row{display:flex;align-items:center;justify-content:space-between;padding:.5rem 0;border-bottom:1px solid #f3f4f6}" +
                "form.add{display:flex;gap:.5rem;margin-top:1rem} input{flex:1;padding:.5rem}" +
                ".alert{background:#ecfdf5;border:1px solid #10b981;padding:.5rem .75rem;border-radius:6px;margin-top:1rem}"
            ),
            () -> {
                header(() -> {
                    h1Text("Weft HTML Builder");
                    nav(() -> link("/", "Tasks"))
                });
                main_(bodyContent)
            }
        )

    def taskRow(task: Task): Unit \ Html =
        li(() -> {
            cls("row");
            id("task-${task#id}");
            span(() -> {
                clsIf(task#done, "done");
                text(task#title)
            });
            form(() -> {
                action("/tasks/${task#id}/toggle");
                method("post");
                button(() -> {
                    type_("submit");
                    text(if (task#done) "Undo" else "Done")
                })
            })
        })

    ///
    /// GET /?flash=... — server-rendered HTML task list.
    ///
    def homePage(): HtmlDoc \ {Req, TaskStore} = {
        let tasks = TaskStore.listTasks();
        let flash = Req.queryParam("flash");
        let remaining = List.count(t -> not t#done, tasks);

        layout("Tasks · Weft", () -> {
            whenSome(flash, msg ->
                div(() -> { cls("alert"); text(msg) })
            );
            section(() -> {
                cls("card");
                pText("${remaining} remaining of ${List.length(tasks)} tasks");
                if (List.isEmpty(tasks))
                    p(() -> text("No tasks yet — add one below!"))
                else
                    ul(() -> each(tasks, taskRow));

                form(() -> {
                    cls("add");
                    action("/tasks");
                    method("post");
                    input(() -> {
                        type_("text");
                        name("title");
                        placeholder("Add a new task...");
                        required()
                    });
                    button(() -> {
                        type_("submit");
                        text("Add")
                    })
                })
            })
        })
    }

    ///
    /// POST /tasks — accepts standard `application/x-www-form-urlencoded` form submission.
    ///
    def createTask(): Response \ {Req, HttpError, TaskStore} = {
        let formFields = Url.parseQuery(Req.body());
        let rawTitle = Map.get("title", formFields)
            |> HttpError.orBadRequest("Missing 'title' form field");
        let title = String.trim(rawTitle);
        HttpError.ensure(not String.isEmpty(title), Status.badRequest(), "Task title cannot be empty");
        let _ = TaskStore.addTask(title);
        Response.redirect("/?flash=Added")
    }

    ///
    /// POST /tasks/:id/toggle
    ///
    def toggleTaskHandler(): Response \ {Req, HttpError, TaskStore} = {
        let taskId = Req.requireIntParam("id");
        let found = TaskStore.toggleTask(taskId);
        HttpError.ensure(found, Status.notFound(), "Task #${taskId} not found");
        Response.redirect("/")
    }

    pub def buildApp(): App[{TaskStore, Logger, Clock}] =
        Router.empty()
            |> Router.get("/", homePage)
            |> Router.post("/tasks", createTask)
            |> Router.post("/tasks/:id/toggle", toggleTaskHandler)
            |> Router.toApp
            |> Middleware.errorHtml
            |> Middleware.timingHeader
            |> Middleware.requestLogger

    ///
    /// Pure region-scoped `TaskStore` handler for zero-IO tests.
    ///
    pub def runStorePure(seed: List[Task], f: Unit -> a \ ef): a \ (ef - TaskStore) = region rc {
        let initialNextId = List.foldLeft((acc, t) -> Int32.max(acc, t#id), 0, seed) + 1;
        let tasksRef = Ref.fresh(rc, seed);
        let nextIdRef = Ref.fresh(rc, initialNextId);
        run {
            f()
        } with handler TaskStore {
            def listTasks(k) =
                k(Ref.get(tasksRef))
            def addTask(title, k) = {
                let id = Ref.get(nextIdRef);
                Ref.put(id + 1, nextIdRef);
                let task = { id = id, title = title, done = false };
                Ref.transform(xs -> List.append(xs, task :: Nil), tasksRef);
                k(task)
            }
            def toggleTask(id, k) = {
                let current = Ref.get(tasksRef);
                let found = List.exists(t -> t#id == id, current);
                if (found)
                    Ref.put(List.map(t -> if (t#id == id) { done = not t#done | t } else t, current), tasksRef)
                else ();
                k(found)
            }
        }
    }

}

mod LiveTaskStore {
    use HtmlSsrApp.Task
    use HtmlSsrApp.TaskStore

    import java.lang.Exception
    import java.util.concurrent.locks.ReentrantLock

    pub enum State {
        case State(ReentrantLock, Ref[List[Task], Static], Ref[Int32, Static])
    }

    pub def init(): State \ IO = {
        let seed =
            { id = 1, title = "Explore Weft algebraic effects", done = true } ::
            { id = 2, title = "Build an HTML page with Weft.Html", done = false } ::
            Nil;
        State.State(new ReentrantLock(), Ref.fresh(Static, seed), Ref.fresh(Static, 3))
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

    pub def runWithIO(state: State, f: Unit -> a \ ef): a \ (ef - TaskStore) + IO = {
        let State.State(lock, tasksRef, nextIdRef) = state;
        run {
            f()
        } with handler TaskStore {
            def listTasks(k) =
                k(withLock(lock, () -> Ref.get(tasksRef)))
            def addTask(title, k) = {
                let task = withLock(lock, () -> {
                    let id = Ref.get(nextIdRef);
                    Ref.put(id + 1, nextIdRef);
                    let t = { id = id, title = title, done = false };
                    Ref.transform(xs -> List.append(xs, t :: Nil), tasksRef);
                    t
                });
                k(task)
            }
            def toggleTask(id, k) = {
                let found = withLock(lock, () -> {
                    let current = Ref.get(tasksRef);
                    let exists = List.exists(t -> t#id == id, current);
                    if (exists)
                        Ref.put(List.map(t -> if (t#id == id) { done = not t#done | t } else t, current), tasksRef)
                    else ();
                    exists
                });
                k(found)
            }
        }
    }

}

def main(): Unit \ IO = {
    use Time.Clock;
    use weft::Weft.App;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;

    let storeState = LiveTaskStore.init();
    let app = HtmlSsrApp.buildApp();

    let ioApp: App[IO] = req ->
        run {
            app(req)
        } with LiveTaskStore.runWithIO(storeState)
          with Logger.runWithIO
          with Clock.runWithIO;

    println("Starting Weft HTML SSR server on http://127.0.0.1:8080");
    println("Open http://127.0.0.1:8080 in your browser!");

    match Server.serve(ServerConfig.local(8080), ioApp) {
        case Ok(())   => ()
        case Err(msg) => println("Server error: ${msg}")
    }
}
