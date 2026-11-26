pub mod Weft.JobError {
    use Weft.JobError

    ///
    /// Zero-shot effect for failing a job from inside a job handler.
    ///
    pub eff JobError {
        def fail(reason: String): Void
    }

    pub def unwrapOr(msg: String, opt: Option[a]): a \ JobError = match opt {
        case Some(v) => v
        case None    => JobError.fail(msg)
    }

    pub def fromResult(res: Result[String, a]): a \ JobError = match res {
        case Ok(v)    => v
        case Err(msg) => JobError.fail(msg)
    }

    pub def ensure(cond: Bool, msg: String): Unit \ JobError =
        if (cond) () else JobError.fail(msg)

    pub def runToResult(f: Unit -> a \ ef): Result[String, a] \ (ef - JobError) =
        run {
            Ok(f())
        } with handler JobError {
            def fail(reason, _k) = Err(reason)
        }

}
