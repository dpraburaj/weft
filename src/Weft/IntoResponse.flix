pub mod Weft.IntoResponse {
    use Weft.IntoResponse
    use Weft.Response
    use Weft.WithStatus

    ///
    /// Trait for values that can be converted directly into an HTTP `Response`.
    ///
    pub trait IntoResponse[a] {
        pub def intoResponse(x: a): Response
    }

    instance IntoResponse[Response] {
        pub def intoResponse(r: Response): Response = r
    }

    instance IntoResponse[String] {
        pub def intoResponse(s: String): Response = Response.text(s)
    }

    instance IntoResponse[Unit] {
        pub def intoResponse(_: Unit): Response = Response.noContent()
    }

    instance IntoResponse[WithStatus[a]] with IntoResponse[a] {
        pub def intoResponse(ws: WithStatus[a]): Response =
            let WithStatus.WithStatus(st, payload) = ws;
            Response.withStatus(st, IntoResponse.intoResponse(payload))
    }
}
