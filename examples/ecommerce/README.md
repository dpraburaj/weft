# Weft Roasters — Real-World E-Commerce Example

A complete server-rendered **Flix + Weft + SQLite (WAL pooled) + HTMX** e-commerce storefront, customer portal, admin dashboard, JSON/SSE catalog API, and scheduled maintenance worker demonstrating Weft `v0.10.0`, structured using **Vertical Slice Architecture** (Jimmy Bogard) + **Algebraic-Effect Persistence Stores** (Repository Pattern).

## Architecture (Vertical Slices + Algebraic-Effect Stores)

Each feature slice owns its domain types, its high-level **Store algebraic effect** (with SQLite `runWithDb` and pure test handlers), its slice-private HTML/HTMX views, its HTTP handlers & routes, and its background jobs.

Handlers and domain logic **never touch raw SQL, `Db`, or `DbError`** — they depend only on high-level domain store effects (`CatalogStore`, `CartStore`, `UserStore`, `OrderStore`), just like Weft's built-in `SessionStore`, `JobStore`, and `StaticStore`. SQLite is bound only at the composition edge ([`LiveServer.wire`](src/Main.flix)).

```text
examples/ecommerce/
├── src/
│   ├── App.flix                  # Composition root (merges feature routers + job registries; zero Db coupling)
│   ├── Main.flix                 # Edge wiring (binds all Store effects to SQLite, starts JobWorker + Server)
│   ├── Shared.flix               # Shared kernel namespace root
│   ├── Shared/                   # Shared kernel (domain types + cross-slice utilities)
│   │   ├── Domain.flix           # Shared cross-feature domain types (`Product`, `CartLine`, `User`, `Order`, etc.)
│   │   ├── Artwork.flix          # Bespoke SVG product packaging/hardware illustrations & crisp admin nav icons
│   │   ├── Schema.flix           # Versioned SQLite migrations + idempotent demo seeding
│   │   ├── Layout.flix           # Editorial storefront shell + calm light-neutral multi-page Admin shell
│   │   ├── CartContext.flix      # Shared cart ownership + CartStore badge count helpers
│   │   ├── Mailer.flix           # HTML + plain-text `Weft.Email` templates for `Weft.Mailer`
│   │   └── Money.flix            # Cents formatting, slugification, categories/statuses
│   ├── Features.flix             # Vertical slices namespace root
│   └── Features/                 # Cohesive vertical feature slices (views private to each slice)
│       ├── Catalog.flix          # Catalog slice namespace root
│       ├── Catalog/
│       │   ├── CatalogStore.flix # `eff CatalogStore` + `runWithDb` (SQLite) & `runPureReadOnly`
│       │   ├── CatalogViews.flix # Private SSR/HTMX storefront & detail views
│       │   └── CatalogFeature.flix
│       ├── Cart.flix             # Cart summary helpers (using `Shared.Domain.summarizeCart`)
│       ├── Cart/
│       │   ├── CartStore.flix    # `eff CartStore` + `runWithDb` (SQLite) & `runPureEmpty`
│       │   ├── CartViews.flix    # Private SSR/HTMX cart panel & OOB badge views
│       │   └── CartFeature.flix
│       ├── Auth.flix             # `UserStore`-backed principal loader
│       ├── Auth/
│       │   ├── UserStore.flix    # `eff UserStore` + `runWithDb` (SQLite)
│       │   ├── AuthViews.flix    # Private login & registration views
│       │   └── AuthFeature.flix
│       ├── Checkout.flix         # Checkout slice namespace root
│       ├── Checkout/
│       │   ├── OrderStore.flix   # `eff OrderStore` + `runWithDb` (ACID tx rollback + outbox)
│       │   ├── CheckoutViews.flix
│       │   ├── CheckoutJobs.flix # `order.confirmation_email` job handler (`Weft.Mailer`)
│       │   └── CheckoutFeature.flix
│       ├── Admin.flix            # Admin slice namespace root (reuses CatalogStore + OrderStore)
│       └── Admin/
│           ├── AdminViews.flix   # Multi-page Merchant Console (`/admin`, `/admin/orders`, `/admin/products`, `/admin/products/new`)
│           ├── AdminJobs.flix    # `order.status_email` job handler (`Weft.Mailer`)
│           └── AdminFeature.flix
├── test/                         # Feature-aligned E2E & pure store-handler test suites
│   ├── TestHarness.flix          # Shared in-memory SQLite, static fixtures, TestSession & job-drain helpers
│   └── Features/
│       ├── TestCatalog.flix      # Pure zero-DB store test, static assets, SSR, HTMX grid, JSON API
│       ├── TestCart.flix         # CSRF enforcement, HTMX add/qty/delete, OOB badge, promo codes
│       ├── TestAuth.flix         # Registration validation, PBKDF2 login, cookie rotation, cart merge, logout
│       ├── TestCheckout.flix     # Auth redirect, 422 validation, atomic checkout + rollback, ownership 403
│       └── TestAdmin.flix        # Admin RBAC 403, multipart PNG upload + BLOB serving, HTMX stock & status
└── public/
    ├── styles.css
    └── brand-mark.svg
```

## Features Demonstrated

* **High-Level Algebraic-Effect Stores (`CatalogStore`, `CartStore`, `UserStore`, `OrderStore`):**
  * Handlers express only domain persistence capabilities in their Flix effect rows (e.g., `{Req, HttpError, CatalogStore}`), completely hiding SQL, `SqlBuilder`, `Row` decoding, and `DbError` behind slice-owned repository handlers.
  * Pure in-memory handlers (`CatalogStore.runPureReadOnly`, `CartStore.runPureEmpty`) enable instant, zero-SQLite, zero-`IO` unit tests of HTTP handlers alongside full SQLite-backed `TestSession` E2E tests.
* **Catalog Slice (`src/Features/Catalog/`):**
  * Live HTMX search, category filtering, sorting, and pagination (`/products/grid`, powered by `Weft.SqlBuilder` + `Weft.Page`).
  * Binary product image serving at `/media/products/:id` (`Response.bytes` + `Cache-Control`).
  * `/api/products` cached with `Weft.Cache` (`Cache.rememberJson`, invalidated on admin product/stock mutations), `/api/products/:slug`, and `/api/events/catalog` Server-Sent Events (`Response.sseEvents` + `SseEvent.namedJson`).
  * Static assets at `/static/*` with `ETag`/`304`, `Accept-Ranges: bytes`, and `206 Partial Content` Range support.
* **Cart Slice (`src/Features/Cart/`):**
  * Live HTMX "Add to Cart" navbar badge updates, `+`/`−`/`Remove` cart controls with Out-of-Band (`hx-swap-oob="true"`) badge sync, and promo codes (`WELCOME10`, `FREESHIP`).
  * Automatic `X-CSRF-Token` propagation for HTMX requests via `<meta name="csrf-token">` plus hidden `_csrf` inputs for progressive enhancement.
* **Auth Slice (`src/Features/Auth/`):**
  * Signed cookie sessions backed by SQLite (`SessionStore.runWithDb`), flash messages, PBKDF2-HMAC-SHA256 password hashing (`Crypto.hashPassword`), anti-fixation session rotation (`Auth.loginSession`), brute-force rate limiting (`Weft.RateLimiter` + `Middleware.throttleRoute`, `10 req/min` -> `429`), and transactional guest-to-customer cart merging on login/registration.
* **Checkout & Admin Slices (`src/Features/Checkout/`, `src/Features/Admin/`):**
  * Multi-field checkout validation (`Weft.Validate` + `ValidationErrors.renderFieldError`, `422 Unprocessable Entity` with preserved inputs).
  * `OrderStore.placeOrderAtomic` atomically verifies and decrements inventory (`stock >= qty`), creates `orders` + `order_items`, clears the cart, and enqueues a deduplicated confirmation email job (`JobQueue.dispatchUnique` + `JobQueue.runWithDb`), returning typed `PlaceOrderError` on rollback.
  * Rich HTML + plain-text order emails delivered via Weft's built-in `Weft.Mailer` + `Weft.Email` (`Mailer.runLogging` in dev, `Mailer.runWithResend` when `RESEND_API_KEY` is set, `Mailer.runRecording` in tests).
  * RBAC-protected (`Middleware.requireRole("admin")`) dashboard with `multipart/form-data` binary image uploads stored as SQLite `BLOB`s (`SqlValue.blob`) and live HTMX stock/status updates.
* **Production Hardening & Concurrency (`src/Main.flix`, `src/App.flix`):**
  * **SQLite WAL Concurrent Reader Pool** (`SqliteConfig.file(dbPath) |> SqliteConfig.withReadPoolSize(4)`) + live `GET /health` endpoint reporting `Sqlite.ping` and `PoolStats.toJson`.
  * **Gzip/Deflate Compression** (`Middleware.compress`) + `Middleware.securityHeaders`.
  * **Periodic Maintenance Scheduler** (`Weft.Scheduler` + `ScheduleStore.runWithDb`) reclaiming stale jobs and pruning expired sessions, cache entries, and rate-limit buckets.
  * **Hardened Server & Coordinated Graceful Shutdown** (`ServerConfig.withReadTimeoutMs`, `withHandlerTimeoutMs`, `Server.serveWithShutdown` draining HTTP, `Scheduler`, `JobWorker`, and SQLite pools cleanly).

## Running

```bash
cd examples/ecommerce

# Run all 5 feature-slice test suites (pure store tests + zero-socket SQLite E2E)
flix test

# Start the server on http://127.0.0.1:8080
flix run
```

### Demo Accounts (Seeded Automatically)

* **Customer:** `ada@example.com` / `coffee123`
* **Admin:** `admin@weftroasters.com` / `admin123`
* **Promo Codes:** `WELCOME10` (10% off) · `FREESHIP` (free shipping)

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP server port |
| `DB_PATH` | `weft_roasters.db` | SQLite database file path |
| `DB_READ_POOL_SIZE` | `4` | Concurrent SQLite WAL read-only connection pool size |
| `SESSION_SECRET` | `dev-only-change-me-in-production` | HMAC cookie signing secret |
| `PUBLIC_DIR` | `public` | Static assets directory |
| `RESEND_API_KEY` | *(unset)* | Optional Resend API key (`Mailer.runWithResend`; falls back to `Mailer.runLogging`) |
