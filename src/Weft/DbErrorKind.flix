pub mod Weft.DbErrorKind {
    ///
    /// Categorized database error kinds.
    ///
    pub enum DbErrorKind with Eq, ToString {
        case ConnectionFailed
        case QueryFailed
        case ConstraintViolation
        case ColumnDecodeError
        case MigrationFailed
        case TransactionFailed
    }
}
