pub mod Weft.Job {
    use Weft.Job
    use Weft.JobStatus
    use Weft.Json

    ///
    /// Persisted/queued background job record.
    ///
    pub enum Job {
        case Job({
            id          = Int64,
            queue       = String,
            kind        = String,
            payload     = Json,
            status      = JobStatus,
            attempts    = Int32,
            maxAttempts = Int32,
            runAtMs     = Int64,
            lastError   = Option[String],
            uniqueKey   = Option[String],
            createdAtMs = Int64,
            updatedAtMs = Int64
        })
    }

    instance Eq[Job] {
        pub def eq(a: Job, b: Job): Bool =
            let Job.Job(x) = a;
            let Job.Job(y) = b;
            x#id == y#id and
            x#queue == y#queue and
            x#kind == y#kind and
            x#payload == y#payload and
            x#status == y#status and
            x#attempts == y#attempts and
            x#maxAttempts == y#maxAttempts and
            x#runAtMs == y#runAtMs and
            x#lastError == y#lastError and
            x#uniqueKey == y#uniqueKey and
            x#createdAtMs == y#createdAtMs and
            x#updatedAtMs == y#updatedAtMs
    }

    pub def id(j: Job): Int64                 = let Job.Job(r) = j; r#id
    pub def queue(j: Job): String             = let Job.Job(r) = j; r#queue
    pub def kind(j: Job): String              = let Job.Job(r) = j; r#kind
    pub def payload(j: Job): Json             = let Job.Job(r) = j; r#payload
    pub def status(j: Job): JobStatus         = let Job.Job(r) = j; r#status
    pub def attempts(j: Job): Int32           = let Job.Job(r) = j; r#attempts
    pub def maxAttempts(j: Job): Int32        = let Job.Job(r) = j; r#maxAttempts
    pub def runAtMs(j: Job): Int64            = let Job.Job(r) = j; r#runAtMs
    pub def lastError(j: Job): Option[String] = let Job.Job(r) = j; r#lastError
    pub def uniqueKey(j: Job): Option[String] = let Job.Job(r) = j; r#uniqueKey
    pub def createdAtMs(j: Job): Int64        = let Job.Job(r) = j; r#createdAtMs
    pub def updatedAtMs(j: Job): Int64        = let Job.Job(r) = j; r#updatedAtMs

    pub def toJson(j: Job): Json =
        let errJson = match lastError(j) {
            case Some(e) => Json.str(e)
            case None    => Json.nullValue()
        };
        let keyJson = match uniqueKey(j) {
            case Some(k) => Json.str(k)
            case None    => Json.nullValue()
        };
        Json.obj(
            ("id",          Json.int64(id(j))) ::
            ("queue",       Json.str(queue(j))) ::
            ("kind",        Json.str(kind(j))) ::
            ("payload",     payload(j)) ::
            ("status",      Json.str("${status(j)}")) ::
            ("attempts",    Json.int(attempts(j))) ::
            ("maxAttempts", Json.int(maxAttempts(j))) ::
            ("runAtMs",     Json.int64(runAtMs(j))) ::
            ("lastError",   errJson) ::
            ("uniqueKey",   keyJson) ::
            ("createdAtMs", Json.int64(createdAtMs(j))) ::
            ("updatedAtMs", Json.int64(updatedAtMs(j))) ::
            Nil
        )

}
