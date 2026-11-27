pub mod Weft.ValidationErrors {
    use Weft.Html
    use Weft.Json
    use Weft.Response
    use Weft.Status
    use Weft.ValidationErrors
    use Weft.View

    ///
    /// Immutable collection of field-keyed validation errors (`field -> List[message]`).
    ///
    pub enum ValidationErrors {
        case ValidationErrors(Map[String, List[String]])
    }

    instance Eq[ValidationErrors] {
        pub def eq(a: ValidationErrors, b: ValidationErrors): Bool =
            let ValidationErrors.ValidationErrors(x) = a;
            let ValidationErrors.ValidationErrors(y) = b;
            x == y
    }

    instance ToString[ValidationErrors] {
        pub def toString(e: ValidationErrors): String =
            Json.encode(toJson(e))
    }

    pub def empty(): ValidationErrors =
        ValidationErrors.ValidationErrors(Map.empty())

    pub def fromMap(m: Map[String, List[String]]): ValidationErrors =
        ValidationErrors.ValidationErrors(Map.filter(xs -> not List.isEmpty(xs), m))

    pub def toMap(e: ValidationErrors): Map[String, List[String]] =
        let ValidationErrors.ValidationErrors(m) = e;
        m

    pub def isEmpty(e: ValidationErrors): Bool =
        Map.isEmpty(toMap(e))

    pub def nonEmpty(e: ValidationErrors): Bool =
        not isEmpty(e)

    ///
    /// Total number of error messages across all fields.
    ///
    pub def count(e: ValidationErrors): Int32 =
        Map.foldLeft((acc, xs) -> acc + List.length(xs), 0, toMap(e))

    ///
    /// Appends an error message for `field`.
    ///
    pub def add(field: String, message: String, e: ValidationErrors): ValidationErrors = {
        let m = toMap(e);
        let existing = Map.getWithDefault(field, Nil, m);
        ValidationErrors.ValidationErrors(Map.insert(field, List.append(existing, message :: Nil), m))
    }

    ///
    /// Merges two `ValidationErrors` collections, preserving all error messages per field.
    ///
    pub def merge(a: ValidationErrors, b: ValidationErrors): ValidationErrors =
        ValidationErrors.ValidationErrors(Map.unionWith(List.append, toMap(a), toMap(b)))

    pub def forField(field: String, e: ValidationErrors): List[String] =
        Map.getWithDefault(field, Nil, toMap(e))

    pub def firstForField(field: String, e: ValidationErrors): Option[String] =
        List.head(forField(field, e))

    pub def hasField(field: String, e: ValidationErrors): Bool =
        Map.memberOf(field, toMap(e))

    ///
    /// Returns a human-readable summary string (e.g. `"email: Invalid email; qty: Must be >= 1"`).
    ///
    pub def summary(e: ValidationErrors): String =
        Map.toList(toMap(e))
            |> List.flatMap(match (f, msgs) -> List.map(m -> "${f}: ${m}", msgs))
            |> String.intercalate("; ")

    ///
    /// Encodes the field error map as a JSON object (`{"field": ["msg1", ...]}`).
    ///
    pub def toJson(e: ValidationErrors): Json =
        Json.JObject(Map.map(msgs -> Json.arr(List.map(Json.str, msgs)), toMap(e)))

    ///
    /// Renders a structured `422 Unprocessable Entity` JSON response:
    /// `{"status": 422, "reason": "Unprocessable Entity", "error": "Validation failed", "errors": {...}}`.
    ///
    pub def toJsonResponse(e: ValidationErrors): Response = {
        let payload = Json.obj(
            ("status", Json.int(422)) ::
            ("reason", Json.str("Unprocessable Entity")) ::
            ("error",  Json.str("Validation failed")) ::
            ("errors", toJson(e)) ::
            Nil
        );
        Json.toResponseWithStatus(Status.unprocessableEntity(), payload)
    }

    ///
    /// Renders the first error for `field` inside a `Weft.Html` form as
    /// `<p class="field-error" role="alert">...</p>` when present.
    ///
    pub def renderFieldError(field: String, e: ValidationErrors): Unit \ Html =
        Html.whenSome(firstForField(field, e), msg ->
            Html.p(() -> {
                Html.cls("field-error");
                Html.role("alert");
                Html.text(msg)
            })
        )

    ///
    /// Returns a pure `Weft.View` node for the first error on `field`
    /// (`<p class="field-error" role="alert">...</p>`) or `View.Empty` when absent.
    ///
    pub def fieldErrorView(field: String, e: ValidationErrors): View =
        View.whenSome(firstForField(field, e), msg ->
            View.p(Vector#{
                View.cls("field-error"),
                View.role("alert"),
                View.text(msg)
            })
        )

}
