pub mod Weft.MailError {
    use Weft.HttpError
    use Weft.JobError
    use Weft.MailError
    use Weft.Status

    ///
    /// Zero-shot algebraic effect for email delivery failures.
    ///
    pub eff MailError {
        def fail(message: String): Void
    }

    ///
    /// Discharges `MailError` into `Result[String, a]`.
    ///
    pub def runToResult(f: Unit -> a \ ef): Result[String, a] \ (ef - MailError) =
        run {
            Ok(f())
        } with handler MailError {
            def fail(msg, _k) = Err(msg)
        }

    ///
    /// Translates `MailError` into `502 Bad Gateway` via `HttpError`.
    ///
    pub def runToHttpError(f: Unit -> a \ ef): a \ (ef - MailError) + HttpError =
        run {
            f()
        } with handler MailError {
            def fail(msg, _k) = HttpError.raise(Status.badGateway(), "Mail delivery failed: ${msg}")
        }

    ///
    /// Translates `MailError` into `JobError` so queued email jobs retry with exponential backoff.
    ///
    pub def runToJobError(f: Unit -> a \ ef): a \ (ef - MailError) + JobError =
        run {
            f()
        } with handler MailError {
            def fail(msg, _k) = JobError.fail(msg)
        }

}
