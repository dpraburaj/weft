pub mod Weft.StorageError {
    use Weft.HttpError
    use Weft.StorageError
    use Weft.StorageErrorKind

    ///
    /// Zero-shot algebraic effect for structured file storage errors.
    ///
    pub eff StorageError {
        def raise(kind: StorageErrorKind, message: String): Void
    }

    pub def notFound(msg: String): a \ StorageError =
        StorageError.raise(StorageErrorKind.NotFound, msg)

    pub def invalidPath(msg: String): a \ StorageError =
        StorageError.raise(StorageErrorKind.InvalidPath, msg)

    pub def permissionDenied(msg: String): a \ StorageError =
        StorageError.raise(StorageErrorKind.PermissionDenied, msg)

    pub def ioError(msg: String): a \ StorageError =
        StorageError.raise(StorageErrorKind.IoError, msg)

    ///
    /// Discharges `StorageError` into `Result[(StorageErrorKind, String), a]`.
    ///
    pub def runToResult(f: Unit -> a \ ef): Result[(StorageErrorKind, String), a] \ (ef - StorageError) =
        run {
            Ok(f())
        } with handler StorageError {
            def raise(kind, msg, _k) = Err((kind, msg))
        }

    ///
    /// Translates `StorageError` into appropriate `HttpError` status codes:
    /// - `NotFound` -> `404 Not Found`
    /// - `InvalidPath` -> `400 Bad Request`
    /// - `PermissionDenied` -> `403 Forbidden`
    /// - `IoError` -> `500 Internal Server Error`
    ///
    pub def runToHttpError(f: Unit -> a \ ef): a \ (ef - StorageError) + HttpError =
        run {
            f()
        } with handler StorageError {
            def raise(kind, msg, _k) = match kind {
                case StorageErrorKind.NotFound         => HttpError.notFound(msg)
                case StorageErrorKind.InvalidPath      => HttpError.badRequest(msg)
                case StorageErrorKind.PermissionDenied => HttpError.forbidden(msg)
                case StorageErrorKind.IoError          => HttpError.internalError(msg)
            }
        }

}
