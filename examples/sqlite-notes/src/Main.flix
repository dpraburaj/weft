mod NotesApp {
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Auth
    use weft::Weft.CorsConfig
    use weft::Weft.Db
    use weft::Weft.DbError
    use weft::Weft.HttpError
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.Migration
    use weft::Weft.Principal
    use weft::Weft.Req
    use weft::Weft.Response
    use weft::Weft.Router
    use weft::Weft.Row
    use weft::Weft.SqlValue
    use weft::Weft.Status
    use weft::Weft.WithStatus

    ///
    /// Versioned, idempotent SQLite schema migrations.
    ///
    pub def migrations(): List[Migration] =
        Migration.make(
            1,
            "create_notes",
            "CREATE TABLE notes (" +
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," +
            "  slug TEXT NOT NULL UNIQUE," +
            "  title TEXT NOT NULL," +
            "  body TEXT NOT NULL," +
            "  author TEXT NOT NULL," +
            "  archived INTEGER NOT NULL DEFAULT 0" +
            ")"
        ) ::
        Migration.make(
            2,
            "add_notes_author_index",
            "CREATE INDEX idx_notes_author ON notes(author)"
        ) ::
        Nil

    pub def verifyToken(token: String): Option[Principal] = match token {
        case "admin-token"  => Some(Principal.make("u-1", "alice", "admin" :: "writer" :: Nil))
        case "writer-token" => Some(Principal.make("u-2", "bob", "writer" :: Nil))
        case _              => None
    }

    def rowToNoteJson(row: Row): Json \ DbError =
        Json.obj(
            ("id",       Json.int64(Row.requireInt64("id", row))) ::
            ("slug",     Json.str(Row.requireString("slug", row))) ::
            ("title",    Json.str(Row.requireString("title", row))) ::
            ("body",     Json.str(Row.requireString("body", row))) ::
            ("author",   Json.str(Row.requireString("author", row))) ::
            ("archived", Json.bool(Row.requireBool("archived", row))) ::
            Nil
        )

    def listNotes(): Json \ {Req, Db, DbError} = {
        let includeArchived = Req.queryParam("archived") == Some("true");
        let rows = if (includeArchived)
            Db.queryMap("SELECT id, slug, title, body, author, archived FROM notes ORDER BY id", Nil, rowToNoteJson)
        else
            Db.queryMap("SELECT id, slug, title, body, author, archived FROM notes WHERE archived = 0 ORDER BY id", Nil, rowToNoteJson);
        Json.obj(
            ("count", Json.int(List.length(rows))) ::
            ("notes", Json.arr(rows)) ::
            Nil
        )
    }

    def getNote(): Json \ {Req, HttpError, Db, DbError} = {
        let id = Req.requireIntParam("id");
        let note = Db.queryOneMap(
            "SELECT id, slug, title, body, author, archived FROM notes WHERE id = ?",
            SqlValue.int(id) :: Nil,
            rowToNoteJson
        ) |> HttpError.orNotFound("Note #${id} not found");
        note
    }

    def createNote(): WithStatus[Json] \ {Req, HttpError, Auth, Db, DbError} = {
        Auth.requireRole("writer");
        let body = Req.jsonBody();
        let slug = Json.requireNonEmptyString("slug", body);
        let title = Json.requireNonEmptyString("title", body);
        let content = Json.requireNonEmptyString("body", body);
        let id = Db.insertAndGetId(
            "INSERT INTO notes (slug, title, body, author) VALUES (?, ?, ?, ?)",
            SqlValue.text(slug) :: SqlValue.text(title) :: SqlValue.text(content) :: SqlValue.text(Auth.userName()) :: Nil
        );
        let created = Db.queryOneMap(
            "SELECT id, slug, title, body, author, archived FROM notes WHERE id = ?",
            SqlValue.int64(id) :: Nil,
            rowToNoteJson
        ) |> HttpError.orNotFound("Created note missing");
        WithStatus.WithStatus(Status.created(), created)
    }

    ///
    /// POST /api/notes/batch — inserts multiple notes inside `Db.transactionHttp`.
    /// If ANY item fails JSON validation (`HttpError`) or hits a `UNIQUE` slug conflict
    /// (`DbError`), the ENTIRE batch rolls back atomically!
    ///
    def batchCreateNotes(): WithStatus[Json] \ {Req, HttpError, Auth, Db, DbError} = {
        Auth.requireRole("writer");
        let body = Req.jsonBody();
        let items = Json.getField("notes", body)
            |> Option.flatMap(Json.asArray)
            |> HttpError.orBadRequest("Field 'notes' must be a JSON array");
        HttpError.ensure(not List.isEmpty(items), Status.badRequest(), "Field 'notes' must not be empty");

        let insertedIds = Db.transactionHttp(() ->
            List.map(item -> {
                let slug = Json.requireNonEmptyString("slug", item);
                let title = Json.requireNonEmptyString("title", item);
                let content = Json.requireNonEmptyString("body", item);
                let id = Db.insertAndGetId(
                    "INSERT INTO notes (slug, title, body, author) VALUES (?, ?, ?, ?)",
                    SqlValue.text(slug) :: SqlValue.text(title) :: SqlValue.text(content) :: SqlValue.text(Auth.userName()) :: Nil
                );
                Json.int64(id)
            }, items)
        );
        WithStatus.WithStatus(
            Status.created(),
            Json.obj(("insertedIds", Json.arr(insertedIds)) :: Nil)
        )
    }

    def archiveNote(): Json \ {Req, HttpError, Auth, Db, DbError} = {
        Auth.requireRole("writer");
        let id = Req.requireIntParam("id");
        let updated = Db.execute(
            "UPDATE notes SET archived = 1 WHERE id = ?",
            SqlValue.int(id) :: Nil
        );
        HttpError.ensure(updated > 0, Status.notFound(), "Note #${id} not found");
        Db.queryOneMap(
            "SELECT id, slug, title, body, author, archived FROM notes WHERE id = ?",
            SqlValue.int(id) :: Nil,
            rowToNoteJson
        ) |> HttpError.orNotFound("Note #${id} not found")
    }

    def deleteNote(): Response \ {Req, HttpError, Auth, Db, DbError} = {
        Auth.requireRole("admin");
        let id = Req.requireIntParam("id");
        let deleted = Db.execute("DELETE FROM notes WHERE id = ?", SqlValue.int(id) :: Nil);
        HttpError.ensure(deleted > 0, Status.notFound(), "Note #${id} not found");
        Response.noContent()
    }

    ///
    /// Notice: `Middleware.dbErrorToHttp` translates SQLite `ConstraintViolation`
    /// (e.g., duplicate `slug`) directly into a `409 Conflict` JSON error!
    ///
    pub def buildApp(): App[{Db, Logger, Clock}] = {
        let protectedApi = Router.empty()
            |> Router.post("/notes", createNote)
            |> Router.post("/notes/batch", batchCreateNotes)
            |> Router.patch("/notes/:id/archive", archiveNote)
            |> Router.delete("/notes/:id", deleteNote)
            |> Router.withMiddleware(Middleware.bearerAuth(verifyToken));

        let publicApi = Router.empty()
            |> Router.get("/notes", listNotes)
            |> Router.get("/notes/:id", getNote)
            |> Router.merge(protectedApi);

        Router.empty()
            |> Router.get("/health", () -> Json.obj(("status", Json.str("ok")) :: Nil))
            |> Router.scope("/api", publicApi)
            |> Router.toApp
            |> Middleware.dbErrorToHttp
            |> Middleware.errorJson
            |> Middleware.cors(CorsConfig.permissive())
            |> Middleware.securityHeaders
            |> Middleware.timingHeader
            |> Middleware.requestLogger
    }

}

def main(): Unit \ IO = {
    use Time.Clock;
    use weft::Weft.App;
    use weft::Weft.Db.Sqlite;
    use weft::Weft.Db.SqliteConfig;
    use weft::Weft.DbError;
    use weft::Weft.HttpError;
    use weft::Weft.Migration;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;

    match Sqlite.open(SqliteConfig.file("notes.db")) {
        case Err(msg) =>
            println("Failed to open SQLite database: ${msg}")
        case Ok(db) =>
            let migRes = run {
                Migration.runAll(NotesApp.migrations())
            } with Sqlite.runWith(db)
              with DbError.runToResult;

            match migRes {
                case Err((kind, msg)) =>
                    println("Migration failed (${kind}): ${msg}");
                    Sqlite.close(db)
                case Ok(applied) =>
                    println("Applied migrations: ${applied}");
                    let app = NotesApp.buildApp();
                    let ioApp: App[IO] = req ->
                        run {
                            app(req)
                        } with Sqlite.runWith(db)
                          with DbError.runToHttpError
                          with HttpError.runAsJson
                          with Logger.runWithIO
                          with Clock.runWithIO;

                    println("Starting Weft SQLite Notes server on http://127.0.0.1:8080 (db: notes.db)");
                    println("Try:");
                    println("  curl -X POST http://127.0.0.1:8080/api/notes \\");
                    println("       -H 'Authorization: Bearer writer-token' \\");
                    println("       -H 'Content-Type: application/json' \\");
                    println("       -d '{\"slug\":\"welcome\",\"title\":\"Welcome\",\"body\":\"Hello SQLite!\"}'");
                    println("  curl http://127.0.0.1:8080/api/notes");

                    match Server.serve(ServerConfig.local(8080), ioApp) {
                        case Ok(())   => ()
                        case Err(msg) => println("Server error: ${msg}")
                    };
                    Sqlite.close(db)
            }
    }
}
