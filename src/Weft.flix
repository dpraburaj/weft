pub mod Weft {
    use Weft.Job
    use Weft.Request
    use Weft.Response

    ///
    /// A route handler is an effectful thunk producing a `Response`.
    /// All capabilities it requires (`Req`, `Res`, `HttpError`, `Auth`, `Logger`,
    /// custom domain effects, etc.) live directly in its effect row `ef`.
    ///
    pub type alias Handler[ef: Eff] = Unit -> Response \ ef

    ///
    /// An HTTP application maps an incoming `Request` to a `Response` with effect `ef`.
    ///
    pub type alias App[ef: Eff] = Request -> Response \ ef

    ///
    /// A job handler consumes a `Job` with effect row `ef`.
    ///
    pub type alias JobHandler[ef: Eff] = Job -> Unit \ ef

}
