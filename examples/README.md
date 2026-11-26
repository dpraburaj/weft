# Weft Examples

Each directory below is a standalone Flix project demonstrating a different slice of **Weft**. Every example includes both a runnable virtual-thread HTTP server (`flix run`) and a test suite (`flix test`).

## Index

| Example | Highlights |
|---|---|
| [`hello-world`](hello-world/) | Routing (`:param`, query params), JSON decoding/validation, ambient cookies/headers via `Res`, `timingHeader` + `requestLogger`, and 100% pure tests with `TestClient` & `TestEffects`. |
| [`custom-effects`](custom-effects/) | Defining your own domain algebraic effects (`BookmarkStore`, `Notifier`), Bearer auth & role checks on a protected sub-router, thread-safe live IO handlers, and **zero-IO pure end-to-end HTTP tests**. |
| [`sqlite-notes`](sqlite-notes/) | Persistent REST API backed by embedded SQLite, forward-only `Migration.runAll`, `Db.transactionHttp` atomic batch rollback on `HttpError`/`DbError`, `Middleware.dbErrorToHttp` (`409 Conflict`), CORS, security headers, and RBAC. |
| [`background-jobs`](background-jobs/) | HTTP API dispatching immediate & delayed jobs via `JobQueue`, Java 21 virtual-thread `JobWorker` pool, exponential backoff retries via `JobError`, and deterministic zero-sleep pure worker tests with `JobStore.runPure` & `TestEffects.runManualClock`. |

## Running Any Example

```bash
cd examples/hello-world

# Run tests
flix test

# Start the HTTP server on http://127.0.0.1:8080
flix run
```

## Quick `curl` Recipes

### `hello-world`

```bash
curl http://127.0.0.1:8080/health
curl 'http://127.0.0.1:8080/hello/Flix?loud=true'
curl -X POST http://127.0.0.1:8080/echo \
  -H 'Content-Type: application/json' \
  -d '{"text":"hi weft"}'
curl -i http://127.0.0.1:8080/theme/dark
```

### `custom-effects`

```bash
curl http://127.0.0.1:8080/bookmarks
curl -X POST http://127.0.0.1:8080/bookmarks \
  -H 'Authorization: Bearer editor-token' \
  -H 'Content-Type: application/json' \
  -d '{"title":"Weft","url":"https://github.com/dpraburaj/weft"}'
```

### `sqlite-notes`

```bash
curl -X POST http://127.0.0.1:8080/api/notes \
  -H 'Authorization: Bearer writer-token' \
  -H 'Content-Type: application/json' \
  -d '{"slug":"welcome","title":"Welcome","body":"Hello SQLite!"}'

curl http://127.0.0.1:8080/api/notes
```

### `background-jobs`

```bash
curl -X POST http://127.0.0.1:8080/orders \
  -H 'Content-Type: application/json' \
  -d '{"orderId":"ORD-42","email":"ada@example.com"}'

curl -X POST http://127.0.0.1:8080/orders/ORD-42/webhook
curl http://127.0.0.1:8080/jobs
```
