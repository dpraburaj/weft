pub mod Weft.WithStatus {
    use Weft.Status

    ///
    /// Wrapper that pairs an HTTP `Status` with any `IntoResponse` payload.
    /// E.g., `WithStatus(Status.created(), todoJson)`.
    ///
    pub enum WithStatus[a] {
        case WithStatus(Status, a)
    }
}
