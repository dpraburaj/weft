pub mod Weft.JobSpec {
    use Weft.JobSpec
    use Weft.Json

    ///
    /// Specification for enqueueing a new background job.
    ///
    pub enum JobSpec {
        case JobSpec({
            queue       = String,
            kind        = String,
            payload     = Json,
            delayMs     = Int64,
            maxAttempts = Int32
        })
    }

    ///
    /// Creates a `JobSpec` on the `"default"` queue with 0ms delay and `maxAttempts = 3`.
    ///
    pub def make(kind: String, payload: Json): JobSpec =
        JobSpec.JobSpec({
            queue       = "default",
            kind        = kind,
            payload     = payload,
            delayMs     = 0i64,
            maxAttempts = 3
        })

    pub def withQueue(q: String, spec: JobSpec): JobSpec =
        let JobSpec.JobSpec(r) = spec;
        JobSpec.JobSpec({ queue = q | r })

    pub def withDelayMs(ms: Int64, spec: JobSpec): JobSpec =
        let JobSpec.JobSpec(r) = spec;
        JobSpec.JobSpec({ delayMs = Int64.max(0i64, ms) | r })

    pub def withMaxAttempts(n: Int32, spec: JobSpec): JobSpec =
        let JobSpec.JobSpec(r) = spec;
        JobSpec.JobSpec({ maxAttempts = Int32.max(1, n) | r })

    pub def queue(spec: JobSpec): String     = let JobSpec.JobSpec(r) = spec; r#queue
    pub def kind(spec: JobSpec): String      = let JobSpec.JobSpec(r) = spec; r#kind
    pub def payload(spec: JobSpec): Json     = let JobSpec.JobSpec(r) = spec; r#payload
    pub def delayMs(spec: JobSpec): Int64    = let JobSpec.JobSpec(r) = spec; r#delayMs
    pub def maxAttempts(spec: JobSpec): Int32 = let JobSpec.JobSpec(r) = spec; r#maxAttempts

}
