# Weft

> [!WARNING]
> **Early Alpha / Experimental Playground:** Weft is an alpha play framework for exploring web development with algebraic effects in Flix. APIs will break without notice, edge cases are still being ironed out, and it is **not intended for production use**.

An idiomatic, lightweight web framework for **Flix (0.80.0)** built from the ground up around **algebraic effects**, **effect polymorphism**, and **Java 21 virtual threads**.

## Installation

Add **Weft** to your Flix project:

```bash
flix install dpraburaj/weft
```

Or add it directly to your `flix.toml`:

```toml
[dependencies]
"github:dpraburaj/weft" = { version = "0.10.0", mount = "weft", security = "unrestricted" }
```

> `security = "unrestricted"` is required by Flix because Weft uses Java interop (`HttpServer`, virtual threads) and bundles `org.xerial:sqlite-jdbc` + `org.postgresql:postgresql`.

Requires **Flix 0.80.0+** and **JDK 21+**.

## Quick Start

```flix
use weft::Weft.App
use weft::Weft.HttpError
use weft::Weft.Json
use weft::Weft.Middleware
use weft::Weft.Req
use weft::Weft.Router
use weft::Weft.Server
use weft::Weft.ServerConfig
use Time.Clock

def greet(): Json \ {Req, HttpError} = {
    let name = Req.requireParam("name");
    Json.obj(("message", Json.str("Hello, ${name}!")) :: Nil)
}

def main(): Unit \ IO = {
    let app = Router.empty()
        |> Router.get("/health", () -> "ok")
        |> Router.get("/hello/:name", greet)
        |> Router.toApp
        |> Middleware.errorJson
        |> Middleware.timingHeader
        |> Middleware.requestLogger;

    let ioApp: App[IO] = req ->
        run { app(req) }
            with Logger.runWithIO
            with Clock.runWithIO;

    match Server.serve(ServerConfig.local(8080), ioApp) {
        case Ok(())   => ()
        case Err(msg) => println("Server error: ${msg}")
    }
}
```

## Why Algebraic Effects for Web Development?

Instead of threading a mutable `Context` god-object or nesting monad-transformer stacks, **Weft** models HTTP and infrastructure capabilities as first-class Flix algebraic effects:

| Effect | Role | How It's Handled |
|---|---|---|
| `Weft.Req` | Ambient read access to the current HTTP request (path params, query params, headers, cookies, body) | Handled automatically by `Router.toApp` |
| `Weft.Res` | Ambient response headers, cookies, and status overrides from anywhere in the call stack | Handled purely via local `region` by `Router.toApp` |
| `Weft.Html` | Ergonomic, XSS-safe, effect-polymorphic HTML builder (`Html.page`, `Html.render`, automatic `cls` merging, `each`/`when`/`whenSome`) | Handled purely via local `region` by `Html.render` / `Html.page`, producing `HtmlDoc` (`IntoResponse`) |
| `Weft.HttpError` & `ValidationError` | Zero-shot HTTP errors (`400`–`500`) and structured multi-field `422` validation errors (`Weft.Validate` accumulating effect) | Discharged by `Middleware.errorJson`, `errorHtml`, `errorNegotiated`, `routeErrorJson`/`Html`, and `validationErrorJson` |
| `Weft.Auth` & `Weft.OptionalAuth` | Capability effects representing a required or optional authenticated `Principal` (`Auth.userName()`, `Auth.requireRole(...)`, `OptionalAuth.isAuthenticated()`) | Discharged per-route or per-subrouter via `Middleware.bearerAuth`, `Middleware.sessionAuth`, `Middleware.sessionAuthOrRedirect`, `Middleware.optionalSessionAuth`, or `Middleware.optionalBearerAuth` |
| `Weft.Session`, `SessionStore` & `Random` | Signed cookie-backed sessions with flash messages, anti-fixation ID rotation, CSRF tokens, and deterministic/CSPRNG randomness | Handled purely via `SessionStore.runPure` + `Random.runDeterministic` in tests, or `SessionStore.runInMemory` / `SessionStore.runWithDb` + `Random.runWithSecureRandom` in production |
| `Weft.Db` & `Weft.DbError` | Driver-agnostic relational SQL effect (parameterized queries, transactions, migrations) & structured DB error effect | Handled by `Sqlite.runWith(db)` (with WAL concurrent reader pool), `Postgres.runWith(db)` (pooled JDBC), or pure `Db.runMock`; `Middleware.dbErrorToHttp` maps `ConstraintViolation` -> `409 Conflict` |
| `Weft.JobQueue`, `JobStore` & `JobError` | Algebraic-effect background job producer, pluggable storage backend, and retry/dead-letter failure effect | Handled purely via `JobStore.runPure` in tests, or switched between `JobBackend.inMemory()` and `JobBackend.sqlite(db)` in production |
| `Weft.StaticStore` | Algebraic-effect static asset store powering `StaticFiles.routes` (MIME detection, `ETag`/`304`, traversal & dotfile protection) | Handled purely via `StaticStore.runPure` in tests, or `StaticStore.runFromDir(dir)` in production |
| `Weft.RateLimiter` | Fixed-window rate limiting & throttling effect (`check`, `attempt`, `enforce`, `Middleware.throttle` / `throttleBy` / `throttleRoute`) | Handled purely via `RateLimiter.runPure` in tests, or `RateLimiter.runInMemory` / `RateLimiter.runWithDb` in production |
| `Weft.Cache` | Key-value caching with TTLs (`remember`, `rememberJson`, `pull`) and atomic locks (`tryLock`, `withLock`) | Handled purely via `Cache.runPure` in tests, or `Cache.runInMemory` / `Cache.runWithDb` in production |
| `Weft.Scheduler` & `ScheduleStore` | Effect-polymorphic recurring task scheduler (fixed intervals & 5-field UTC cron, `taskWithoutOverlapping`, `dispatchJob`, virtual-thread loop) | Handled purely via `ScheduleStore.runPure` + `Scheduler.tick` in tests, or `ScheduleStore.runInMemory` / `runWithDb` + `Scheduler.startBackground` in production |
| `Weft.Storage` & `StorageError` | Writable object/file storage (`put`, `putUploaded`, `get`, `delete`, `list`, `Storage.runStaticStore` bridge) with traversal protection | Handled purely via `Storage.runPure` / `runPureRecording` in tests, or `Storage.runInMemory` / `Storage.runLocalDir` in production |
| `Weft.Mailer` & `MailError` | Transactional email effect with `Weft.Html` templates, queued delivery (`Mailer.queue` + `registerJobHandler`), and HTTP API drivers | Handled purely via `Mailer.runRecording` / `runPure` in tests, `Mailer.runLogging` in dev, or `Mailer.runWithResend` / `runWithHttpApi` (`HttpClient`) in production |
| `Weft.HttpClient` & `Env` | Outbound HTTP client effect (Stripe, email, webhooks) and typed environment/config effect (`.env` parsing + `Validate` startup checks) | Handled purely via `HttpClient.runMock`/`runRecording` & `Env.runWithMap` in tests, or `HttpClient.runWithJdk` & `Env.runWithSystem` in production |
| `Logger`, `Clock`, `Abort` | Standard Flix library effects used natively by middleware (`requestLogger`, `timingHeader`, `recoverAbort`) | Swapped seamlessly between `IO` in production and 100% pure deterministic handlers in tests |
| Your domain effects | e.g., `UserRepo`, `Mailer`, `PaymentGateway` | Compile-time verified: `Server.serve` won't compile until every custom effect is handled |

### Effect-Accumulating Router

`Router[ef]` tracks the Boolean union of every route handler's effects:

```flix
let protectedApi = Router.empty()
    |> Router.post("/items", createItem)         // requires {Req, HttpError, Auth, ItemStore}
    |> Router.delete("/items/:id", deleteItem)
    |> Router.withMiddleware(Middleware.bearerAuth(verifyToken)); // discharges Auth!

let app: App[{ItemStore, Logger, Clock}] =
    Router.empty()
        |> Router.get("/health", () -> "ok")
        |> Router.scope("/api", protectedApi)
        |> Router.toApp                          // discharges Req & Res, adds HttpError
        |> Middleware.errorJson                  // discharges HttpError
        |> Middleware.recoverAbort               // discharges Abort
        |> Middleware.cors(CorsConfig.permissive())
        |> Middleware.securityHeaders
        |> Middleware.timingHeader               // adds Clock
        |> Middleware.requestLogger;             // adds Logger & Clock
```

### Pure, Zero-IO Testing

Because `app` has type `App[{ItemStore, Logger, Clock}]` (no `IO`, no sockets), you can test your entire HTTP stack — routing, middleware, JSON parsing, auth, logging, and response timing — **100% purely**:

```flix
let (res, logs) = run {
    TestClient.get("/api/items", app)
} with TestEffects.runCollectingLogger
  with TestEffects.runSteppingClock(1000i64, 5i64)
  with ItemStore.runPure(seedItems);
```

### Database & SQLite Support

`Weft.Db` exposes a driver-agnostic `Db` effect (`queryRows`, `queryOne`, `queryMap`, `execute`, `insertAndGetId`, `transaction`, `transactionHttp`) paired with `DbError` and forward-only `Migration.runAll`, bundled with a thread-safe embedded **SQLite** backend (`org.xerial:sqlite-jdbc`):

```flix
let Ok(db) = Sqlite.open(SqliteConfig.file("app.db"));

// Automatic rollback if DbError OR HttpError is raised mid-transaction
Db.transactionHttp(() -> {
    let id = Db.insertAndGetId(
        "INSERT INTO items (title, created_by) VALUES (?, ?)",
        SqlValue.text(title) :: SqlValue.text(Auth.userName()) :: Nil
    );
    ...
})
```

### Background Job Runner

`Weft.JobQueue`, `Weft.JobStore`, `Weft.JobRegistry`, and `Weft.JobWorker` provide an effect-polymorphic background job runner with pluggable backends (pure `region` for tests, thread-safe `InMemory`, or persistent `Sqlite`), delayed execution, exponential backoff retries, dead-lettering, and Java 21 virtual-thread worker pools:

```flix
// 1. Enqueue from any handler via JobQueue
let _ = JobQueue.dispatch("item.created", payload);
let _ = JobQueue.dispatchIn(5000i64, "email.reminder", payload);

// 2. Register effect-polymorphic job handlers (JobRegistry[ef])
let reg = JobRegistry.empty()
    |> JobRegistry.register("item.created", job ->
        Logger.info("Processed job #${Job.id(job)}")
    )
    |> JobRegistry.register("email.reminder", job ->
        if (failed) JobError.fail("SMTP timeout") else () // retried with exponential backoff
    );

// 3. Pick a backend
let backend = JobBackend.inMemory(); // or: let Ok(backend) = JobBackend.sqlite(db);

// 4. Drain synchronously in tests (JobWorker.drain) or run on virtual threads in production
let handle = JobWorker.startBackground(WorkerConfig.default(), () -> ...);
```

### Virtual-Thread Embedded HTTP Server

`Weft.Server` runs on JDK 21's built-in `com.sun.net.httpserver.HttpServer` backed by **Java 21 virtual threads** (`Executors.newVirtualThreadPerTaskExecutor()`), requiring no external servlet container or Netty stack. Because `Server.serve` requires `App[IO]`, the Flix compiler statically verifies that no custom effect was left unhandled.

## Modules

- `Weft` — Core type aliases (`Handler[ef]`, `App[ef]`, `JobHandler[ef]`)
- `Weft.{Body,Method,Status,Headers,SameSite,Cookie,Request,Response,StreamWriter,SseEvent,WithStatus,IntoResponse}` — HTTP value types (text, binary `Vector[Int8]`, and chunked `Body.Stream` / SSE), plus `IntoResponse` trait
- `Weft.Url` — UTF-8 percent-encoding/decoding, single & multi-value query/form parsing (`parseQuery`, `parseQueryAll`, `encodeQuery`), path normalization
- `Weft.{Multipart,MultipartForm,UploadedFile}` — Pure binary RFC 7578 `multipart/form-data` parser & encoder preserving raw uploaded file bytes
- `Weft.{Mime,ByteRange,StaticFile,StaticConfig,StaticStore,StaticFiles}` — Effect-polymorphic static file serving with MIME detection, `ETag`/`304 Not Modified`, HTTP `Range` (`206 Partial Content` / `416`), `Cache-Control`, and path-traversal/dotfile protection
- `Weft.{Accept,Compression,CompressionConfig}` — RFC 9110 `Accept` content negotiation (`negotiate`, `prefersHtml`, `prefersJson`) and `gzip`/`deflate` compression (`Middleware.compress` / `compressWith`)
- `Weft.{Validate,ValidationErrors,ValidationError}` — Accumulating multi-field form & JSON validation effect with `422` JSON rendering and inline `Weft.Html` field error helpers
- `Weft.Json` — Pure Flix RFC 8259 JSON AST, encoder, parser, and `HttpError`-integrated extractors (`requireInt64`, `requireFloat`, `requireArray`, `requireObject`, `optional*`)
- `Weft.{Html,HtmlDoc}` — Ergonomic, XSS-safe algebraic-effect HTML builder (`IntoResponse`, class merging, control-flow & HTMX helpers)
- `Weft.{HttpError,Req,Res,Principal,Auth,OptionalAuth}` — Core HTTP & auth algebraic effects (JSON, URL-encoded form, signed cookie, and multipart extractors; Bearer + session auth)
- `Weft.{Random,Crypto,CsrfConfig,Csrf}` — CSPRNG/deterministic `Random` effect, SHA-256, HMAC-SHA256 webhook & cookie signing, PBKDF2-HMAC-SHA256 password hashing, constant-time comparisons, and CSRF protection (`Csrf.hiddenInput`, `Csrf.metaTag`, `Middleware.csrf`)
- `Weft.{Session,SessionConfig,SessionData,SessionStore,InMemorySessionStore}` — Signed cookie sessions with flash messages, session rotation (`Auth.loginSession`), and Pure / InMemory / SQLite storage backends
- `Weft.Router` — Effect-polymorphic `Router[ef]` (`:param`, `*wildcard`, `scope`, `merge`, `withMiddleware`, `HEAD` fallback, `405` + `Allow`)
- `Weft.{CorsConfig,Middleware}` — `errorJson`, `errorText`, `errorHtml`, `errorWith`, `errorNegotiated`, `errorNegotiatedWith`, `routeErrorJson`, `routeErrorHtml`, `validationErrorJson`, `dbErrorToHttp`, `dbErrorToHttpSafe`, `storageErrorToHttp`, `mailErrorToHttp`, `recoverAbort`, `recoverAbortNegotiated`, `session`, `bearerAuth`, `sessionAuth`, `sessionAuthOrRedirect`, `optionalSessionAuth`, `optionalBearerAuth`, `requireRole`, `csrf`, `csrfApp`, `maxBodySize`, `limitBodySize`, `throttle`, `throttleBy`, `throttleRoute`, `compress`, `compressWith`, `requestLogger`, `timingHeader`, `cors`, `securityHeaders`
- `Weft.{Db,DbError,DbErrorKind,SqlValue,Row,Migration,SqlBuilder,Page}` & `Weft.Db.{ConnectionPool,PoolConfig,PoolStats,Jdbc,Sqlite,SqliteConfig,SqliteDb,Postgres,PostgresConfig,PostgresDb}` — Driver-agnostic SQL effects, bounded virtual-thread JDBC connection pooling, nested savepoints, trigger-safe migrations, dynamic `SqlBuilder` (`IN`, `WHERE`, pagination), SQLite WAL concurrent reader pool, and pooled PostgreSQL backend
- `Weft.{Job,JobSpec,JobStatus,JobError,JobQueue,JobStore,JobBackend,JobRegistry,JobWorker,WorkerConfig,WorkerHandle,InMemoryJobStore}` — Background job runner with `uniqueKey` deduplication, stale-job recovery (`reclaimStale`), and transactional outbox (`JobQueue.runWithDb`)
- `Weft.{RateLimiter,RateLimitConfig,RateLimitDecision,InMemoryRateLimiter}` — Fixed-window rate limiter effect (Pure / InMemory / SQLite) and `Middleware.throttle` / `throttleBy` / `throttleRoute`
- `Weft.{Cache,InMemoryCache}` — TTL key-value cache (`remember`, `rememberJson`, `pull`) and atomic locks (`tryLock`, `withLock`) across Pure / InMemory / SQLite backends
- `Weft.{Schedule,ScheduledTask,ScheduleStore,InMemoryScheduleStore,Scheduler}` — Effect-polymorphic recurring task scheduler supporting intervals, 5-field UTC cron expressions, overlap locking, `JobQueue` dispatch, and virtual-thread background execution
- `Weft.{Storage,StoredFile,StorageError,StorageErrorKind,InMemoryStorage}` — Path-traversal-safe writable file storage (Pure / InMemory / LocalDir) with `UploadedFile` and `StaticStore` bridges
- `Weft.{Mailer,Email,MailError}` — Transactional email effect with `HtmlDoc` bodies, `Mailer.runRecording` (`Mail::fake()`), `runLogging`, `runWithResend`/`runWithHttpApi`, and `JobQueue` async delivery
- `Weft.{HttpClient,ClientRequest,ClientResponse,Env}` — Outbound JDK 21 `HttpClient` effect (with pure `runMock`/`runRecording`) and typed `Env` / `.env` config effect
- `Weft.{Server,ServerConfig,ServerHandle,TlsConfig}` — JDK 21 virtual-thread HTTP/HTTPS server with TLS (`HttpsServer`), read/handler timeouts (`408`/`504`), chunked streaming & SSE, configurable `maxBodyBytes` (`413`), and coordinated graceful shutdown (`serveWithShutdown`)
- `Weft.{TestClient,TestSession,TestEffects}` — Stateless `TestClient` (`get`, `postJson`, `postForm`, `postBytes`, `postMultipart`, `extractCsrfToken`), pure stateful `TestSession` (cookie jar + automatic redirect following for multi-step journeys), and deterministic pure `TestEffects` (`Logger`, `Time.Clock`)

## Examples

Complete, runnable Flix projects live in [`examples/`](examples/README.md):

- [`examples/hello-world`](examples/hello-world/) — Routing, JSON validation, ambient `Res` cookies/headers, middleware, and pure `TestClient` tests
- [`examples/custom-effects`](examples/custom-effects/) — Custom domain effects (`BookmarkStore`, `Notifier`), Bearer auth + RBAC, and zero-IO pure HTTP tests
- [`examples/sqlite-notes`](examples/sqlite-notes/) — Persistent SQLite REST API, migrations, `Db.transactionHttp` atomic batch rollback, and `409 Conflict` mapping
- [`examples/background-jobs`](examples/background-jobs/) — HTTP API + Java 21 virtual-thread `JobWorker`, delayed jobs, exponential backoff retries, and deterministic clock-driven tests
- [`examples/html-ssr`](examples/html-ssr/) — Server-rendered HTML with the `Weft.Html` algebraic-effect builder, form handling, `Middleware.errorHtml`, and pure SSR tests
- [`examples/ecommerce`](examples/ecommerce/) — Full real-world **Weft Roasters** e-commerce store: SSR HTML + HTMX live catalog/cart/admin, SQLite sessions/CSRF/PBKDF2 auth + guest cart merge, multipart binary image uploads, atomic checkout outbox `JobWorker`, static assets, JSON API, and `TestSession` E2E tests

```bash
cd examples/hello-world
flix test   # run tests
flix run    # start server on http://127.0.0.1:8080
```

## Development

```bash
# Typecheck
flix check

# Run full test suite (pure effect tests, SQLite, jobs, and live loopback HTTP server)
flix test

# Generate API documentation
flix doc

# Build distributable .fpkg
flix build-pkg
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE.md).
