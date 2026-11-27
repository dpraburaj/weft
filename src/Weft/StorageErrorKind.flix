pub mod Weft.StorageErrorKind {
    use Weft.StorageErrorKind

    ///
    /// Structured categories of file storage failures.
    ///
    pub enum StorageErrorKind with Eq, ToString {
        case NotFound
        case InvalidPath
        case PermissionDenied
        case IoError
    }

}
