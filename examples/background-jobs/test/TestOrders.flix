mod TestOrders {
    use Assert.assertEq
    use Assert.assertTrue
    use OrderJobsApp.Mailer
    use weft::Weft.JobQueue
    use weft::Weft.JobStatus
    use weft::Weft.JobStore
    use weft::Weft.JobWorker
    use weft::Weft.Json
    use weft::Weft.Response
    use weft::Weft.Status
    use weft::Weft.TestClient
    use weft::Weft.TestEffects
    use weft::Weft.WorkerConfig

    ///
    /// 100% PURE end-to-end test of HTTP request -> JobQueue -> delayed execution ->
    /// exponential backoff retry! Zero IO, zero threads, zero sleeps!
    ///
    @Test
    def testOrderJobsDelayedAndRetryPurely(): Unit \ Assert = {
        region rc {
            let now = Ref.fresh(rc, 1000i64);
            let sentEmails = Ref.fresh(rc, Nil);
            let app = OrderJobsApp.buildApp();
            let reg = OrderJobsApp.buildRegistry();
            let cfg = WorkerConfig.default() |> WorkerConfig.withRetryBackoffMs(1000i64);

            run {
                // 1. POST /orders at t = 1000ms -> enqueues immediate confirm + 5000ms delayed followup
                let rOrder = TestClient.postJson(
                    "/orders",
                    Json.obj(("orderId", Json.str("ORD-42")) :: ("email", Json.str("ada@example.com")) :: Nil),
                    app
                );
                assertEq(expected = Status.accepted(), Response.status(rOrder));

                // 2. POST /orders/ORD-42/webhook -> fails attempt 1, succeeds on attempt 2 after 1000ms backoff
                let rHook = TestClient.postText("/orders/ORD-42/webhook", "", app);
                assertEq(expected = Status.accepted(), Response.status(rHook));

                // 3. Drain at t = 1000ms: confirm completes, webhook fails attempt 1 (rescheduled to t = 2000ms)
                let n1 = JobWorker.drain(cfg, reg);
                assertEq(expected = 2, n1);
                assertEq(expected = ("ada@example.com", "Order ORD-42 confirmed") :: Nil, Ref.get(sentEmails));

                // 4. Advance clock to t = 2000ms -> webhook retries and completes!
                Ref.put(2000i64, now);
                let n2 = JobWorker.drain(cfg, reg);
                assertEq(expected = 1, n2);

                // 5. Advance clock to t = 6000ms -> delayed followup runs!
                Ref.put(6000i64, now);
                let n3 = JobWorker.drain(cfg, reg);
                assertEq(expected = 1, n3);
                assertEq(
                    expected =
                        ("ada@example.com", "How was order ORD-42?") ::
                        ("ada@example.com", "Order ORD-42 confirmed") ::
                        Nil,
                    Ref.get(sentEmails)
                );

                // 6. Inspect GET /jobs?status=completed via HTTP
                let rJobs = TestClient.get("/jobs?status=completed", app);
                assertEq(expected = Status.ok(), Response.status(rJobs));
                assertTrue(String.contains({substr = "\"count\":3"}, Response.body(rJobs)));

                let completed = JobStore.listJobs(None, Some(JobStatus.Completed));
                assertEq(expected = 3, List.length(completed))
            } with handler Mailer {
                  def sendEmail(to, subject, k) = {
                      Ref.transform(xs -> (to, subject) :: xs, sentEmails);
                      k()
                  }
              }
              with JobQueue.runWithStore
              with JobStore.runPure
              with TestEffects.runManualClock(now)
              with TestEffects.runSilentLogger
        }
    }

}
