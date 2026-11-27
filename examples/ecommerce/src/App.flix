mod ShopApp {
    use Features.Admin.AdminFeature
    use Features.Admin.AdminJobs
    use Features.Auth.AuthFeature
    use Features.Auth.UserStore
    use Features.Cart.CartFeature
    use Features.Cart.CartStore
    use Features.Catalog.CatalogFeature
    use Features.Catalog.CatalogStore
    use Features.Checkout.CheckoutFeature
    use Features.Checkout.CheckoutJobs
    use Features.Checkout.OrderStore
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.Cache
    use weft::Weft.CsrfConfig
    use weft::Weft.HttpError
    use weft::Weft.JobError
    use weft::Weft.JobRegistry
    use weft::Weft.JobStore
    use weft::Weft.JobWorker
    use weft::Weft.Mailer
    use weft::Weft.Middleware
    use weft::Weft.OptionalAuth
    use weft::Weft.Random
    use weft::Weft.RateLimiter
    use weft::Weft.Req
    use weft::Weft.Router
    use weft::Weft.Schedule
    use weft::Weft.Scheduler
    use weft::Weft.Session
    use weft::Weft.SessionConfig
    use weft::Weft.SessionStore
    use weft::Weft.StaticConfig
    use weft::Weft.StaticFiles
    use weft::Weft.StaticStore

    ///
    /// Application-level capabilities: high-level domain stores + Weft infrastructure effects.
    /// Completely decoupled from SQLite, `Db`, `DbError`, and raw SQL.
    ///
    pub type alias ShopEffects = {
        CatalogStore, CartStore, UserStore, OrderStore,
        SessionStore, Cache, RateLimiter, Random, Clock, StaticStore, Logger
    }

    ///
    /// Composes all vertical-slice background job handlers into a single registry
    /// backed by Weft's built-in `Weft.Mailer` effect.
    ///
    pub def jobRegistry(): JobRegistry[{Mailer, JobError}] = {
        let reg1: JobRegistry[{Mailer, JobError}] =
            JobRegistry.empty() |> CheckoutJobs.register;
        reg1 |> AdminJobs.register
    }

    ///
    /// Periodic maintenance scheduler running on a Java 21 virtual thread via `Weft.Scheduler`:
    /// - Reclaims stale/crashed background jobs every 5 minutes
    /// - Prunes expired sessions, cache entries, and rate-limit buckets every 15 minutes
    ///
    pub def maintenanceScheduler(): Scheduler[{SessionStore, Cache, RateLimiter, JobStore, Clock}] =
        Scheduler.empty()
            |> Scheduler.task("reclaim_stale_jobs", Schedule.everyMinutes(5), () -> {
                let _ = JobWorker.reclaimStale(300000i64);
                ()
            })
            |> Scheduler.task("prune_expired_sessions", Schedule.everyMinutes(15), () -> {
                let _ = SessionStore.pruneExpired(Clock.now());
                ()
            })
            |> Scheduler.task("prune_expired_cache", Schedule.everyMinutes(15), () -> {
                let _ = Cache.pruneExpired(Clock.now());
                ()
            })
            |> Scheduler.task("prune_expired_rate_limits", Schedule.everyMinutes(15), () -> {
                let _ = RateLimiter.pruneExpired(Clock.now());
                ()
            })

    ///
    /// Composes the Weft Roasters e-commerce application from independent vertical feature slices:
    /// - `Features.Catalog`  (`/`, `/products/grid`, `/products/:slug`, `/media/products/:id`, `/api/products*`, `/api/events/catalog`)
    /// - `Features.Cart`     (`/cart`, `/cart/items*`, `/cart/promo`)
    /// - `Features.Auth`     (`/login`, `/register`, `/logout` — rate-limited via `Weft.RateLimiter`)
    /// - `Features.Checkout` (`/checkout`, `/orders`, `/orders/:id`)
    /// - `Features.Admin`    (`/admin/*`)
    /// - Static assets       (`/static/*` — with `ETag`, `304`, and `206` Range support)
    ///
    pub def build(sessionSecret: String, passwordIterations: Int32): App[ShopEffects] = {
        let sessionCfg = SessionConfig.default(sessionSecret)
            |> SessionConfig.withCookieName("weft_shop_session")
            |> SessionConfig.withTtlSeconds(86400 * 7);
        let csrfCfg = CsrfConfig.default();

        // 1. Public Storefront, Cart, and Auth read routes (`OptionalAuth`)
        let publicReadBase: Router[{Req, HttpError, OptionalAuth, Session, Random, CatalogStore, CartStore}] =
            Router.empty()
                |> Router.merge(CatalogFeature.publicReadRoutes())
                |> Router.merge(CartFeature.readRoutes())
                |> Router.merge(AuthFeature.readRoutes());
        let publicReadRouter: Router[{Req, HttpError, Session, Random, CatalogStore, CartStore, UserStore}] =
            publicReadBase |> Router.withMiddleware(Middleware.optionalSessionAuth(Features.Auth.loadPrincipalByIdStr));

        // 2. Public CSRF-protected mutations (Cart HTMX + Rate-limited Auth)
        let publicMutBase: Router[{Req, HttpError, OptionalAuth, Session, Random, RateLimiter, Clock, CatalogStore, CartStore, UserStore}] =
            Router.empty()
                |> Router.merge(CartFeature.mutationRoutes())
                |> Router.merge(AuthFeature.mutationRoutes(passwordIterations));
        let publicMutWithCsrf: Router[{Req, HttpError, OptionalAuth, Session, Random, RateLimiter, Clock, CatalogStore, CartStore, UserStore}] =
            publicMutBase |> Router.withMiddleware(Middleware.csrf(csrfCfg));
        let publicMutRouter: Router[{Req, HttpError, Session, Random, RateLimiter, Clock, CatalogStore, CartStore, UserStore}] =
            publicMutWithCsrf |> Router.withMiddleware(Middleware.optionalSessionAuth(Features.Auth.loadPrincipalByIdStr));

        // 3. Slice-owned authenticated routers & cached JSON / SSE API
        let checkoutRouter: Router[{Req, HttpError, Session, Random, OrderStore, CartStore, UserStore}] =
            CheckoutFeature.routes(csrfCfg);
        let adminRouter: Router[{Req, HttpError, Session, Random, Cache, CatalogStore, OrderStore, CartStore, UserStore}] =
            AdminFeature.routes(csrfCfg);
        let apiRouter: Router[{Req, CatalogStore, Cache, Clock}] =
            CatalogFeature.apiRoutes();

        // 4. Compose full application router
        let routed: App[{CatalogStore, CartStore, UserStore, OrderStore, Cache, RateLimiter, HttpError, Session, Random, Clock, StaticStore}] =
            Router.empty()
                |> Router.merge(StaticFiles.routes("/static", StaticConfig.default()))
                |> Router.merge(CatalogFeature.mediaRoutes())
                |> Router.merge(publicReadRouter)
                |> Router.merge(publicMutRouter)
                |> Router.merge(checkoutRouter)
                |> Router.scope("/admin", adminRouter)
                |> Router.scope("/api", apiRouter)
                |> Router.toApp;

        let withErr: App[{CatalogStore, CartStore, UserStore, OrderStore, Cache, RateLimiter, Session, Random, Clock, StaticStore}] =
            routed |> Middleware.errorNegotiated;
        let withSession: App[{CatalogStore, CartStore, UserStore, OrderStore, SessionStore, Cache, RateLimiter, Random, Clock, StaticStore}] =
            withErr |> Middleware.session(sessionCfg);
        withSession
            |> Middleware.compress
            |> Middleware.securityHeaders
            |> Middleware.timingHeader
            |> Middleware.requestLogger
    }

}
