pub mod Weft.Env {
    use Weft.Env
    use Weft.Validate

    import java.lang.System

    ///
    /// Algebraic effect for reading application configuration from environment variables.
    ///
    /// Production code uses `Env.runWithSystem` (or `Env.runWithSystemAndDefaults`),
    /// while tests use `Env.runWithMap` (100% pure, zero `IO`).
    ///
    pub eff Env {
        def getVar(name: String): Option[String]
    }

    // --- Pure Readers ---

    ///
    /// Returns the raw environment variable value if present.
    ///
    pub def get(name: String): Option[String] \ Env =
        Env.getVar(name)

    ///
    /// Returns the trimmed environment variable value if present and non-empty.
    ///
    pub def getNonEmpty(name: String): Option[String] \ Env =
        match Env.getVar(name) {
            case Some(v) =>
                let t = String.trim(v);
                if (String.isEmpty(t)) None else Some(t)
            case None => None
        }

    pub def getOrDefault(name: String, defaultVal: String): String \ Env =
        Option.getWithDefault(defaultVal, getNonEmpty(name))

    pub def getIntOrDefault(name: String, defaultVal: Int32): Int32 \ Env =
        match getNonEmpty(name) |> Option.flatMap(Int32.fromString) {
            case Some(n) => n
            case None    => defaultVal
        }

    pub def getInt64OrDefault(name: String, defaultVal: Int64): Int64 \ Env =
        match getNonEmpty(name) |> Option.flatMap(Int64.fromString) {
            case Some(n) => n
            case None    => defaultVal
        }

    pub def getBoolOrDefault(name: String, defaultVal: Bool): Bool \ Env =
        match getNonEmpty(name) |> Option.map(String.toLowerCase) {
            case Some("true")  => true
            case Some("1")     => true
            case Some("yes")   => true
            case Some("on")    => true
            case Some("false") => false
            case Some("0")     => false
            case Some("no")    => false
            case Some("off")   => false
            case _             => defaultVal
        }

    // --- Startup Validation Helpers (compose with `Weft.Validate`) ---

    ///
    /// Reads a required non-empty environment variable, accumulating an error into `Validate`
    /// if missing or blank so all missing startup config keys are reported together!
    ///
    pub def require(name: String): String \ {Env, Validate} =
        match getNonEmpty(name) {
            case Some(v) => v
            case None =>
                Validate.addError(name, "Missing required environment variable '${name}'");
                ""
        }

    ///
    /// Reads a required 32-bit integer environment variable, accumulating into `Validate`.
    ///
    pub def requireInt(name: String): Int32 \ {Env, Validate} =
        match getNonEmpty(name) {
            case None =>
                Validate.addError(name, "Missing required environment variable '${name}'");
                0
            case Some(raw) => match Int32.fromString(raw) {
                case Some(n) => n
                case None =>
                    Validate.addError(name, "Environment variable '${name}' must be an integer, got '${raw}'");
                    0
            }
        }

    ///
    /// Pure `.env` file parser supporting `#` comments, optional `export ` prefixes,
    /// and single/double-quoted values.
    ///
    pub def parseDotEnv(content: String): Map[String, String] =
        String.splitOn({substr = "\n"}, content)
            |> List.foldLeft((acc, rawLine) -> {
                let trimmed = String.trim(rawLine);
                if (String.isEmpty(trimmed) or String.startsWith({prefix = "#"}, trimmed))
                    acc
                else {
                    let line = match String.stripPrefix({substr = "export "}, trimmed) {
                        case Some(rest) => String.trim(rest)
                        case None       => trimmed
                    };
                    match String.indexOfLeft({substr = "="}, line) {
                        case None => acc
                        case Some(idx) =>
                            let k = String.trim(String.sliceLeft({end = idx}, line));
                            let rawV = String.trim(String.sliceRight({start = idx + 1}, line));
                            if (String.isEmpty(k))
                                acc
                            else
                                Map.insert(k, unquoteDotEnv(rawV), acc)
                    }
                }
            }, Map.empty())

    // --- Handlers ---

    ///
    /// 100% pure handler backed by an explicit `Map[String, String]`.
    ///
    pub def runWithMap(vars: Map[String, String], f: Unit -> a \ ef): a \ (ef - Env) =
        run {
            f()
        } with handler Env {
            def getVar(name, k) = k(Map.get(name, vars))
        }

    ///
    /// Production handler reading from `java.lang.System.getenv`.
    ///
    pub def runWithSystem(f: Unit -> a \ ef): a \ (ef - Env) + IO =
        run {
            f()
        } with handler Env {
            def getVar(name, k) = {
                let raw = System.getenv(name);
                let opt = if (Object.isNull(raw)) None else Some(raw);
                k(opt)
            }
        }

    ///
    /// Reads from `System.getenv` first, falling back to `defaults` (e.g. parsed from `.env`).
    ///
    pub def runWithSystemAndDefaults(defaults: Map[String, String], f: Unit -> a \ ef): a \ (ef - Env) + IO =
        run {
            f()
        } with handler Env {
            def getVar(name, k) = {
                let raw = System.getenv(name);
                let opt = if (Object.isNull(raw)) Map.get(name, defaults) else Some(raw);
                k(opt)
            }
        }

    // --- Internal Helpers ---

    def unquoteDotEnv(v: String): String = {
        let len = String.length(v);
        if (len >= 2 and String.charAt(0, v) == '"' and String.charAt(len - 1, v) == '"') {
            String.slice({start = 1}, {end = len - 1}, v)
                |> String.replace({src = "\\n"}, {dst = "\n"})
                |> String.replace({src = "\\r"}, {dst = "\r"})
                |> String.replace({src = "\\t"}, {dst = "\t"})
                |> String.replace({src = "\\\""}, {dst = "\""})
        } else if (len >= 2 and String.charAt(0, v) == '\'' and String.charAt(len - 1, v) == '\'') {
            String.slice({start = 1}, {end = len - 1}, v)
        } else {
            v
        }
    }

}
