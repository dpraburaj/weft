pub mod Weft.ValidationError {
    use Weft.Response
    use Weft.ValidationError
    use Weft.ValidationErrors

    ///
    /// Zero-shot algebraic effect for short-circuiting with structured multi-field
    /// `ValidationErrors` (typically rendered as a `422 Unprocessable Entity` response).
    ///
    pub eff ValidationError {
        def fail(errors: ValidationErrors): Void
    }

    ///
    /// Discharges `ValidationError` by rendering structured `422` JSON error payloads
    /// containing the full `"errors": { "<field>": [...] }` map.
    ///
    pub def runAsJson(f: Unit -> Response \ ef): Response \ (ef - ValidationError) =
        run {
            f()
        } with handler ValidationError {
            def fail(errs, _k) = ValidationErrors.toJsonResponse(errs)
        }

    ///
    /// Discharges `ValidationError` using a custom `ValidationErrors -> Response` renderer.
    ///
    pub def runWith(
        render: ValidationErrors -> Response \ ef2,
        f: Unit -> Response \ ef1
    ): Response \ (ef1 - ValidationError) + ef2 =
        run {
            f()
        } with handler ValidationError {
            def fail(errs, _k) = render(errs)
        }

}
