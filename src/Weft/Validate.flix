pub mod Weft.Validate {
    use Weft.HttpError
    use Weft.Json
    use Weft.Validate
    use Weft.ValidationError
    use Weft.ValidationErrors

    ///
    /// Algebraic effect for accumulating multi-field validation errors without
    /// short-circuiting on the first invalid input.
    ///
    /// Example:
    /// ```flix
    /// Validate.toResult(() -> {
    ///     let email = Validate.requireEmail("email", Map.get("email", form));
    ///     let name  = Validate.requireNonEmpty("name", Map.get("name", form))
    ///         |> Validate.minLength("name", 2);
    ///     let price = Validate.requireInt64("price_cents", Map.get("price_cents", form))
    ///         |> Validate.minInt64("price_cents", 1i64);
    ///     { email = email, name = name, priceCents = price }
    /// })
    /// ```
    ///
    pub eff Validate {
        def addError(field: String, message: String): Unit
    }

    // --- Handlers ---

    ///
    /// Runs `f` purely, returning both the built value and all accumulated `ValidationErrors`.
    /// Useful for SSR forms that re-render user inputs alongside inline field errors.
    ///
    pub def collect(f: Unit -> a \ ef): (a, ValidationErrors) \ (ef - Validate) =
        region rc {
            let errsRef = Ref.fresh(rc, ValidationErrors.empty());
            let value = run {
                f()
            } with handler Validate {
                def addError(field, msg, k) = {
                    Ref.transform(e -> ValidationErrors.add(field, msg, e), errsRef);
                    k()
                }
            };
            (value, Ref.get(errsRef))
        }

    ///
    /// Runs `f` purely, returning `Ok(value)` if zero errors were recorded or `Err(errors)` otherwise.
    ///
    pub def toResult(f: Unit -> a \ ef): Result[ValidationErrors, a] \ (ef - Validate) = {
        let (v, errs) = collect(f);
        if (ValidationErrors.isEmpty(errs)) Ok(v) else Err(errs)
    }

    ///
    /// Runs `f` and raises `ValidationError.fail(errs)` if any validation errors were collected.
    /// Pairs with `Middleware.validationErrorJson` for structured `422` API responses.
    ///
    pub def orFail(f: Unit -> a \ ef): a \ (ef - Validate) + ValidationError =
        match toResult(f) {
            case Ok(v)     => v
            case Err(errs) => ValidationError.fail(errs)
        }

    ///
    /// Runs `f` and raises `HttpError.unprocessable(summary)` if any validation errors were collected.
    ///
    pub def orHttpError(f: Unit -> a \ ef): a \ (ef - Validate) + HttpError =
        match toResult(f) {
            case Ok(v)     => v
            case Err(errs) => HttpError.unprocessable(ValidationErrors.summary(errs))
        }

    // --- Generic Assertion ---

    ///
    /// Records `message` under `field` when `cond` is `false`.
    ///
    pub def check(cond: Bool, field: String, message: String): Unit \ Validate =
        if (cond) () else Validate.addError(field, message)

    // --- Form / String Validators (pipe-friendly) ---

    pub def requireString(field: String, opt: Option[String]): String \ Validate =
        match opt {
            case Some(s) => s
            case None =>
                Validate.addError(field, "This field is required");
                ""
        }

    pub def requireNonEmpty(field: String, opt: Option[String]): String \ Validate =
        match opt {
            case Some(raw) =>
                let trimmed = String.trim(raw);
                if (String.isEmpty(trimmed)) {
                    Validate.addError(field, "Must not be empty");
                    ""
                } else {
                    trimmed
                }
            case None =>
                Validate.addError(field, "This field is required");
                ""
        }

    pub def minLength(field: String, min: Int32, s: String): String \ Validate = {
        if (not String.isEmpty(s) and String.length(s) < min)
            Validate.addError(field, "Must be at least ${min} characters")
        else ();
        s
    }

    pub def maxLength(field: String, max: Int32, s: String): String \ Validate = {
        if (String.length(s) > max)
            Validate.addError(field, "Must be at most ${max} characters")
        else ();
        s
    }

    pub def email(field: String, s: String): String \ Validate = {
        if (not String.isEmpty(s) and not isValidEmail(s))
            Validate.addError(field, "Must be a valid email address")
        else ();
        s
    }

    pub def requireEmail(field: String, opt: Option[String]): String \ Validate =
        requireNonEmpty(field, opt) |> email(field)

    pub def httpUrl(field: String, s: String): String \ Validate = {
        let lower = String.toLowerCase(s);
        let ok = String.startsWith({prefix = "https://"}, lower) or String.startsWith({prefix = "http://"}, lower);
        if (not String.isEmpty(s) and not ok)
            Validate.addError(field, "Must be a valid http:// or https:// URL")
        else ();
        s
    }

    pub def oneOf(field: String, allowed: List[String], s: String): String \ Validate = {
        if (not String.isEmpty(s) and not List.memberOf(s, allowed)) {
            let choices = String.intercalate(", ", allowed);
            Validate.addError(field, "Must be one of: ${choices}")
        } else ();
        s
    }

    // --- Form / String Numeric Parsers & Range Validators ---

    pub def requireInt(field: String, opt: Option[String]): Int32 \ Validate =
        match opt {
            case None =>
                Validate.addError(field, "This field is required");
                0
            case Some(raw) =>
                let trimmed = String.trim(raw);
                match Int32.fromString(trimmed) {
                    case Some(n) => n
                    case None =>
                        Validate.addError(field, "Must be a valid integer");
                        0
                }
        }

    pub def requireInt64(field: String, opt: Option[String]): Int64 \ Validate =
        match opt {
            case None =>
                Validate.addError(field, "This field is required");
                0i64
            case Some(raw) =>
                let trimmed = String.trim(raw);
                match Int64.fromString(trimmed) {
                    case Some(n) => n
                    case None =>
                        Validate.addError(field, "Must be a valid 64-bit integer");
                        0i64
                }
        }

    pub def requireFloat(field: String, opt: Option[String]): Float64 \ Validate =
        match opt {
            case None =>
                Validate.addError(field, "This field is required");
                0.0f64
            case Some(raw) =>
                let trimmed = String.trim(raw);
                match Float64.fromString(trimmed) {
                    case Some(f) => f
                    case None =>
                        Validate.addError(field, "Must be a valid number");
                        0.0f64
                }
        }

    pub def minInt(field: String, min: Int32, n: Int32): Int32 \ Validate = {
        if (n < min) Validate.addError(field, "Must be at least ${min}") else ();
        n
    }

    pub def maxInt(field: String, max: Int32, n: Int32): Int32 \ Validate = {
        if (n > max) Validate.addError(field, "Must be at most ${max}") else ();
        n
    }

    pub def minInt64(field: String, min: Int64, n: Int64): Int64 \ Validate = {
        if (n < min) Validate.addError(field, "Must be at least ${min}") else ();
        n
    }

    pub def maxInt64(field: String, max: Int64, n: Int64): Int64 \ Validate = {
        if (n > max) Validate.addError(field, "Must be at most ${max}") else ();
        n
    }

    pub def positiveInt(field: String, n: Int32): Int32 \ Validate =
        minInt(field, 1, n)

    pub def positiveInt64(field: String, n: Int64): Int64 \ Validate =
        minInt64(field, 1i64, n)

    // --- Accumulating JSON Extractors ---

    pub def jsonString(field: String, j: Json): String \ Validate =
        match Json.getField(field, j) {
            case Some(Json.JString(s)) => s
            case Some(_) =>
                Validate.addError(field, "Must be a string");
                ""
            case None =>
                Validate.addError(field, "This field is required");
                ""
        }

    pub def jsonNonEmptyString(field: String, j: Json): String \ Validate =
        match Json.getField(field, j) {
            case Some(Json.JString(raw)) =>
                let s = String.trim(raw);
                if (String.isEmpty(s)) {
                    Validate.addError(field, "Must not be empty");
                    ""
                } else s
            case Some(_) =>
                Validate.addError(field, "Must be a string");
                ""
            case None =>
                Validate.addError(field, "This field is required");
                ""
        }

    pub def jsonInt(field: String, j: Json): Int32 \ Validate =
        match Json.getField(field, j) {
            case Some(v) => match Json.asInt(v) {
                case Some(n) => n
                case None =>
                    Validate.addError(field, "Must be an integer");
                    0
            }
            case None =>
                Validate.addError(field, "This field is required");
                0
        }

    pub def jsonInt64(field: String, j: Json): Int64 \ Validate =
        match Json.getField(field, j) {
            case Some(v) => match Json.asInt64(v) {
                case Some(n) => n
                case None =>
                    Validate.addError(field, "Must be a 64-bit integer");
                    0i64
            }
            case None =>
                Validate.addError(field, "This field is required");
                0i64
        }

    pub def jsonFloat(field: String, j: Json): Float64 \ Validate =
        match Json.getField(field, j) {
            case Some(v) => match Json.asFloat(v) {
                case Some(f) => f
                case None =>
                    Validate.addError(field, "Must be a number");
                    0.0f64
            }
            case None =>
                Validate.addError(field, "This field is required");
                0.0f64
        }

    pub def jsonBool(field: String, j: Json): Bool \ Validate =
        match Json.getField(field, j) {
            case Some(Json.JBool(b)) => b
            case Some(_) =>
                Validate.addError(field, "Must be a boolean");
                false
            case None =>
                Validate.addError(field, "This field is required");
                false
        }

    pub def jsonArray(field: String, j: Json): List[Json] \ Validate =
        match Json.getField(field, j) {
            case Some(Json.JArray(xs)) => xs
            case Some(_) =>
                Validate.addError(field, "Must be an array");
                Nil
            case None =>
                Validate.addError(field, "This field is required");
                Nil
        }

    pub def jsonOptionalString(field: String, j: Json): Option[String] \ Validate =
        match Json.getField(field, j) {
            case None                  => None
            case Some(Json.JNull)      => None
            case Some(Json.JString(s)) => Some(s)
            case Some(_) =>
                Validate.addError(field, "Must be a string");
                None
        }

    pub def jsonOptionalInt(field: String, j: Json): Option[Int32] \ Validate =
        match Json.getField(field, j) {
            case None             => None
            case Some(Json.JNull) => None
            case Some(v) => match Json.asInt(v) {
                case Some(n) => Some(n)
                case None =>
                    Validate.addError(field, "Must be an integer");
                    None
            }
        }

    pub def jsonOptionalInt64(field: String, j: Json): Option[Int64] \ Validate =
        match Json.getField(field, j) {
            case None             => None
            case Some(Json.JNull) => None
            case Some(v) => match Json.asInt64(v) {
                case Some(n) => Some(n)
                case None =>
                    Validate.addError(field, "Must be a 64-bit integer");
                    None
            }
        }

    // --- Internal Helpers ---

    def isValidEmail(s: String): Bool = {
        let hasSpace = String.exists(Char.isWhitespace, s);
        if (hasSpace)
            false
        else
            match String.indexOfLeft({substr = "@"}, s) {
                case None => false
                case Some(atIdx) =>
                    let local = String.sliceLeft({end = atIdx}, s);
                    let domain = String.sliceRight({start = atIdx + 1}, s);
                    let extraAt = String.contains({substr = "@"}, domain);
                    if (String.isEmpty(local) or String.isEmpty(domain) or extraAt)
                        false
                    else
                        match String.indexOfRight({substr = "."}, domain) {
                            case Some(dotIdx) =>
                                dotIdx > 0 and dotIdx + 1 < String.length(domain)
                            case None => false
                        }
            }
    }

}
