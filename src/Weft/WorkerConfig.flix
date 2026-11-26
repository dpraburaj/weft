pub mod Weft.WorkerConfig {
    use Weft.WorkerConfig

    ///
    /// Configuration for a job worker / background runner.
    ///
    pub enum WorkerConfig {
        case WorkerConfig({
            queue          = String,
            concurrency    = Int32,
            pollIntervalMs = Int64,
            retryBackoffMs = Int64
        })
    }

    pub def default(): WorkerConfig =
        WorkerConfig.WorkerConfig({
            queue          = "default",
            concurrency    = 2,
            pollIntervalMs = 200i64,
            retryBackoffMs = 1000i64
        })

    pub def withQueue(q: String, cfg: WorkerConfig): WorkerConfig =
        let WorkerConfig.WorkerConfig(r) = cfg;
        WorkerConfig.WorkerConfig({ queue = q | r })

    pub def withConcurrency(n: Int32, cfg: WorkerConfig): WorkerConfig =
        let WorkerConfig.WorkerConfig(r) = cfg;
        WorkerConfig.WorkerConfig({ concurrency = Int32.max(1, n) | r })

    pub def withPollIntervalMs(ms: Int64, cfg: WorkerConfig): WorkerConfig =
        let WorkerConfig.WorkerConfig(r) = cfg;
        WorkerConfig.WorkerConfig({ pollIntervalMs = Int64.max(10i64, ms) | r })

    pub def withRetryBackoffMs(ms: Int64, cfg: WorkerConfig): WorkerConfig =
        let WorkerConfig.WorkerConfig(r) = cfg;
        WorkerConfig.WorkerConfig({ retryBackoffMs = Int64.max(0i64, ms) | r })

    pub def queue(cfg: WorkerConfig): String        = let WorkerConfig.WorkerConfig(r) = cfg; r#queue
    pub def concurrency(cfg: WorkerConfig): Int32   = let WorkerConfig.WorkerConfig(r) = cfg; r#concurrency
    pub def pollIntervalMs(cfg: WorkerConfig): Int64 = let WorkerConfig.WorkerConfig(r) = cfg; r#pollIntervalMs
    pub def retryBackoffMs(cfg: WorkerConfig): Int64 = let WorkerConfig.WorkerConfig(r) = cfg; r#retryBackoffMs

}
