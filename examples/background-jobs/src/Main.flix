mod OrderJobsApp {
    use Time.Clock
    use weft::Weft.App
    use weft::Weft.HttpError
    use weft::Weft.Job
    use weft::Weft.JobError
    use weft::Weft.JobQueue
    use weft::Weft.JobRegistry
    use weft::Weft.JobSpec
    use weft::Weft.JobStatus
    use weft::Weft.JobStore
    use weft::Weft.Json
    use weft::Weft.Middleware
    use weft::Weft.Req
    use weft::Weft.Router
    use weft::Weft.Status
    use weft::Weft.WithStatus

    ///
    /// Domain effect representing outbound email delivery (handled via logging in dev,
    /// or collected purely in tests).
    ///
    pub eff Mailer {
        def sendEmail(to: String, subject: String): Unit
    }

    ///
    /// POST /orders  {"orderId": "ORD-42", "email": "ada@example.com"}
    ///
    /// Enqueues:
    /// 1. An immediate `"order.confirm"` job.
    /// 2. A delayed (5s) `"order.followup"` job.
    ///
    def createOrder(): WithStatus[Json] \ {Req, HttpError, JobQueue} = {
        let body = Req.jsonBody();
        let orderId = Json.requireNonEmptyString("orderId", body);
        let email = Json.requireNonEmptyString("email", body);
        let payload = Json.obj(
            ("orderId", Json.str(orderId)) ::
            ("email", Json.str(email)) ::
            Nil
        );
        let confirmJob = JobQueue.dispatch("order.confirm", payload);
        let followupJob = JobQueue.dispatchIn(5000i64, "order.followup", payload);
        WithStatus.WithStatus(
            Status.accepted(),
            Json.obj(
                ("orderId", Json.str(orderId)) ::
                ("confirmJobId", Json.int64(Job.id(confirmJob))) ::
                ("followupJobId", Json.int64(Job.id(followupJob))) ::
                Nil
            )
        )
    }

    ///
    /// POST /orders/:id/webhook — enqueues a flaky webhook job (max 3 attempts) to
    /// demonstrate exponential backoff retries.
    ///
    def triggerWebhook(): WithStatus[Json] \ {Req, HttpError, JobQueue} = {
        let orderId = Req.requireParam("id");
        let failFirst = Req.queryParam("failFirst") != Some("false");
        let payload = Json.obj(
            ("orderId", Json.str(orderId)) ::
            ("failFirst", Json.bool(failFirst)) ::
            Nil
        );
        let job = JobQueue.enqueue(
            JobSpec.make("order.webhook", payload) |> JobSpec.withMaxAttempts(3)
        );
        WithStatus.WithStatus(Status.accepted(), Job.toJson(job))
    }

    ///
    /// GET /jobs?status=pending|running|completed|dead
    ///
    def listJobs(): Json \ {Req, HttpError, JobStore} = {
        let statusOpt = match Req.queryParam("status") {
            case None              => None
            case Some("pending")   => Some(JobStatus.Pending)
            case Some("running")   => Some(JobStatus.Running)
            case Some("completed") => Some(JobStatus.Completed)
            case Some("dead")      => Some(JobStatus.Dead)
            case Some(other)       => HttpError.badRequest("Unknown status '${other}'")
        };
        let jobs = JobStore.listJobs(None, statusOpt);
        Json.obj(
            ("count", Json.int(List.length(jobs))) ::
            ("jobs", Json.arr(List.map(Job.toJson, jobs))) ::
            Nil
        )
    }

    ///
    /// Builds the HTTP app — requires `{JobQueue, JobStore, Logger, Clock}` (no `IO`!).
    ///
    pub def buildApp(): App[{JobQueue, JobStore, Logger, Clock}] =
        Router.empty()
            |> Router.get("/health", () -> Json.obj(("status", Json.str("ok")) :: Nil))
            |> Router.post("/orders", createOrder)
            |> Router.post("/orders/:id/webhook", triggerWebhook)
            |> Router.get("/jobs", listJobs)
            |> Router.toApp
            |> Middleware.errorJson
            |> Middleware.timingHeader
            |> Middleware.requestLogger

    ///
    /// Builds the effect-polymorphic job registry (`JobRegistry[{Mailer, JobError, Logger}]`).
    ///
    pub def buildRegistry(): JobRegistry[{Mailer, JobError, Logger}] =
        JobRegistry.empty()
            |> JobRegistry.register("order.confirm", job -> {
                let p = Job.payload(job);
                let orderId = Option.getWithDefault("?", Option.flatMap(Json.asString, Json.getField("orderId", p)));
                let email = Option.getWithDefault("?", Option.flatMap(Json.asString, Json.getField("email", p)));
                Mailer.sendEmail(email, "Order ${orderId} confirmed")
            })
            |> JobRegistry.register("order.followup", job -> {
                let p = Job.payload(job);
                let orderId = Option.getWithDefault("?", Option.flatMap(Json.asString, Json.getField("orderId", p)));
                let email = Option.getWithDefault("?", Option.flatMap(Json.asString, Json.getField("email", p)));
                Mailer.sendEmail(email, "How was order ${orderId}?")
            })
            |> JobRegistry.register("order.webhook", job -> {
                let p = Job.payload(job);
                let orderId = Option.getWithDefault("?", Option.flatMap(Json.asString, Json.getField("orderId", p)));
                let failFirst = Option.getWithDefault(true, Option.flatMap(Json.asBool, Json.getField("failFirst", p)));
                if (failFirst and Job.attempts(job) == 1)
                    JobError.fail("Webhook endpoint timed out for ${orderId}")
                else
                    Logger.info("Delivered webhook for ${orderId} on attempt ${Job.attempts(job)}")
            })

}

def main(): Unit \ IO = {
    use OrderJobsApp.Mailer;
    use Time.Clock;
    use weft::Weft.App;
    use weft::Weft.DbError;
    use weft::Weft.HttpError;
    use weft::Weft.JobBackend;
    use weft::Weft.JobWorker;
    use weft::Weft.Server;
    use weft::Weft.ServerConfig;
    use weft::Weft.WorkerConfig;
    use weft::Weft.WorkerHandle;

    // Swap `JobBackend.inMemory()` for `JobBackend.sqlite(db)` for persistent jobs!
    let backend = JobBackend.inMemory();
    let app = OrderJobsApp.buildApp();
    let registry = OrderJobsApp.buildRegistry();

    let workerCfg = WorkerConfig.default()
        |> WorkerConfig.withConcurrency(2)
        |> WorkerConfig.withPollIntervalMs(250i64)
        |> WorkerConfig.withRetryBackoffMs(1000i64);

    // Start 2 background Java 21 virtual-thread workers
    let workerHandle = JobWorker.startBackground(workerCfg, () -> {
        let stepRes = run {
            JobWorker.runNext(workerCfg, registry)
        } with handler Mailer {
              def sendEmail(to, subject, k) = {
                  Logger.info("[mail] To=${to} | Subject=${subject}");
                  k()
              }
          }
          with JobBackend.runStore(backend)
          with DbError.runToResult
          with Logger.runWithIO
          with Clock.runWithIO;
        match stepRes {
            case Ok(didWork) => didWork
            case Err(_)      => false
        }
    });

    let ioApp: App[IO] = req ->
        run {
            app(req)
        } with JobBackend.runQueue(backend)
          with DbError.runToHttpError
          with HttpError.runAsJson
          with Logger.runWithIO
          with Clock.runWithIO;

    println("Starting Weft Background Jobs server on http://127.0.0.1:8080");
    println("Try:");
    println("  curl -X POST http://127.0.0.1:8080/orders \\");
    println("       -H 'Content-Type: application/json' \\");
    println("       -d '{\"orderId\":\"ORD-42\",\"email\":\"ada@example.com\"}'");
    println("  curl -X POST http://127.0.0.1:8080/orders/ORD-42/webhook");
    println("  curl http://127.0.0.1:8080/jobs");

    match Server.serve(ServerConfig.local(8080), ioApp) {
        case Ok(())   => ()
        case Err(msg) => println("Server error: ${msg}")
    };
    WorkerHandle.stop(workerHandle)
}
