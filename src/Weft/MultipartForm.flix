pub mod Weft.MultipartForm {
    use Weft.HttpError
    use Weft.MultipartForm
    use Weft.UploadedFile

    ///
    /// Parsed `multipart/form-data` payload containing text fields and uploaded binary files.
    ///
    pub enum MultipartForm {
        case MultipartForm({
            fields = Map[String, List[String]],
            files  = Map[String, List[UploadedFile]]
        })
    }

    instance Eq[MultipartForm] {
        pub def eq(a: MultipartForm, b: MultipartForm): Bool =
            let MultipartForm.MultipartForm(x) = a;
            let MultipartForm.MultipartForm(y) = b;
            x#fields == y#fields and x#files == y#files
    }

    pub def empty(): MultipartForm =
        MultipartForm.MultipartForm({
            fields = Map.empty(),
            files  = Map.empty()
        })

    pub def make(fields: Map[String, List[String]], files: Map[String, List[UploadedFile]]): MultipartForm =
        MultipartForm.MultipartForm({
            fields = fields,
            files  = files
        })

    pub def fieldsMap(form: MultipartForm): Map[String, List[String]] =
        let MultipartForm.MultipartForm(r) = form;
        r#fields

    pub def filesMap(form: MultipartForm): Map[String, List[UploadedFile]] =
        let MultipartForm.MultipartForm(r) = form;
        r#files

    ///
    /// Returns the first value for text field `name`, if present.
    ///
    pub def field(name: String, form: MultipartForm): Option[String] =
        List.head(fieldAll(name, form))

    ///
    /// Returns all values for text field `name` in order.
    ///
    pub def fieldAll(name: String, form: MultipartForm): List[String] =
        Map.getWithDefault(name, Nil, fieldsMap(form))

    ///
    /// Returns the first uploaded file for `name`, if present.
    ///
    pub def file(name: String, form: MultipartForm): Option[UploadedFile] =
        List.head(files(name, form))

    ///
    /// Returns all uploaded files for `name` in order.
    ///
    pub def files(name: String, form: MultipartForm): List[UploadedFile] =
        Map.getWithDefault(name, Nil, filesMap(form))

    ///
    /// Returns every uploaded file across all field names.
    ///
    pub def allFiles(form: MultipartForm): List[UploadedFile] =
        Map.valuesOf(filesMap(form)) |> List.flatten

    // --- Validating Extractors (`HttpError`) ---

    pub def requireField(name: String, form: MultipartForm): String \ HttpError =
        field(name, form) |> HttpError.orBadRequest("Missing required multipart field '${name}'")

    pub def requireNonEmptyField(name: String, form: MultipartForm): String \ HttpError =
        let v = String.trim(requireField(name, form));
        if (String.isEmpty(v))
            HttpError.badRequest("Multipart field '${name}' must not be empty")
        else
            v

    pub def requireFile(name: String, form: MultipartForm): UploadedFile \ HttpError =
        file(name, form) |> HttpError.orBadRequest("Missing required file upload '${name}'")

}
