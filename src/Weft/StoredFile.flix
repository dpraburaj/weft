pub mod Weft.StoredFile {
    use Weft.StoredFile

    ///
    /// Metadata for an object stored in `Weft.Storage`.
    ///
    pub enum StoredFile {
        case StoredFile({
            path           = String,
            sizeBytes      = Int64,
            contentType    = String,
            lastModifiedMs = Int64
        })
    }

    instance Eq[StoredFile] {
        pub def eq(a: StoredFile, b: StoredFile): Bool =
            let StoredFile.StoredFile(x) = a;
            let StoredFile.StoredFile(y) = b;
            x#path == y#path and
            x#sizeBytes == y#sizeBytes and
            x#contentType == y#contentType and
            x#lastModifiedMs == y#lastModifiedMs
    }

    pub def make(path: String, sizeBytes: Int64, contentType: String, lastModifiedMs: Int64): StoredFile =
        StoredFile.StoredFile({
            path           = path,
            sizeBytes      = Int64.max(0i64, sizeBytes),
            contentType    = contentType,
            lastModifiedMs = lastModifiedMs
        })

    pub def path(f: StoredFile): String          = let StoredFile.StoredFile(r) = f; r#path
    pub def sizeBytes(f: StoredFile): Int64      = let StoredFile.StoredFile(r) = f; r#sizeBytes
    pub def contentType(f: StoredFile): String   = let StoredFile.StoredFile(r) = f; r#contentType
    pub def lastModifiedMs(f: StoredFile): Int64 = let StoredFile.StoredFile(r) = f; r#lastModifiedMs

}
