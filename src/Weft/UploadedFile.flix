pub mod Weft.UploadedFile {
    use Weft.Body
    use Weft.UploadedFile

    ///
    /// Represents a file uploaded in a `multipart/form-data` request.
    ///
    pub enum UploadedFile {
        case UploadedFile({
            fieldName   = String,
            fileName    = String,
            contentType = String,
            data        = Vector[Int8]
        })
    }

    instance Eq[UploadedFile] {
        pub def eq(a: UploadedFile, b: UploadedFile): Bool =
            let UploadedFile.UploadedFile(x) = a;
            let UploadedFile.UploadedFile(y) = b;
            x#fieldName == y#fieldName and
            x#fileName == y#fileName and
            x#contentType == y#contentType and
            x#data == y#data
    }

    ///
    /// Constructs an `UploadedFile` from its metadata and raw bytes.
    ///
    pub def make(fieldName: String, fileName: String, contentType: String, data: Vector[Int8]): UploadedFile =
        UploadedFile.UploadedFile({
            fieldName   = fieldName,
            fileName    = fileName,
            contentType = contentType,
            data        = data
        })

    pub def fieldName(f: UploadedFile): String   = let UploadedFile.UploadedFile(r) = f; r#fieldName
    pub def fileName(f: UploadedFile): String    = let UploadedFile.UploadedFile(r) = f; r#fileName
    pub def contentType(f: UploadedFile): String = let UploadedFile.UploadedFile(r) = f; r#contentType
    pub def data(f: UploadedFile): Vector[Int8]  = let UploadedFile.UploadedFile(r) = f; r#data
    pub def size(f: UploadedFile): Int32         = Vector.length(data(f))
    pub def asText(f: UploadedFile): String      = Body.utf8String(data(f))

}
