pub mod Weft.DbError {
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.HttpError

    ///
    /// Zero-shot algebraic effect for database errors.
    ///
    pub eff DbError {
        def raise(kind: DbErrorKind, message: String): Void
    }

    pub def queryFailed(msg: String): a \ DbError =
        DbError.raise(DbErrorKind.QueryFailed, msg)

    pub def constraintViolation(msg: String): a \ DbError =
        DbError.raise(DbErrorKind.ConstraintViolation, msg)

    pub def columnDecode(msg: String): a \ DbError =
        DbError.raise(DbErrorKind.ColumnDecodeError, msg)

    pub def migrationFailed(msg: String): a \ DbError =
        DbError.raise(DbErrorKind.MigrationFailed, msg)

    ///
    /// Handles `DbError` by returning `Result[(DbErrorKind, String), a]`.
    ///
    pub def runToResult(f: Unit -> a \ ef): Result[(DbErrorKind, String), a] \ (ef - DbError) =
        run {
            Ok(f())
        } with handler DbError {
            def raise(kind, msg, _k) = Err((kind, msg))
        }

    ///
    /// Translates `DbError` into `HttpError`:
    /// - `ConstraintViolation` -> `409 Conflict`
    /// - all other kinds -> `500 Internal Server Error`
    ///
    pub def runToHttpError(f: Unit -> a \ ef): a \ (ef - DbError) + HttpError =
        run {
            f()
        } with handler DbError {
            def raise(kind, msg, _k) = match kind {
                case DbErrorKind.ConstraintViolation => HttpError.conflict(msg)
                case _                               => HttpError.internalError("Database error (${kind}): ${msg}")
            }
        }

}
