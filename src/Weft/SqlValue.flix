pub mod Weft.SqlValue {
    use Weft.SqlValue

    ///
    /// Typed SQL parameter and result value for safe parameterized queries.
    ///
    pub enum SqlValue with Eq {
        case SqlNull
        case SqlInt(Int32)
        case SqlInt64(Int64)
        case SqlFloat(Float64)
        case SqlText(String)
        case SqlBool(Bool)
        case SqlBlob(Vector[Int8])
    }

    instance ToString[SqlValue] {
        pub def toString(v: SqlValue): String = match v {
            case SqlValue.SqlNull     => "NULL"
            case SqlValue.SqlInt(i)   => "${i}"
            case SqlValue.SqlInt64(i) => "${i}"
            case SqlValue.SqlFloat(f) => "${f}"
            case SqlValue.SqlText(s)  => s
            case SqlValue.SqlBool(b)  => "${b}"
            case SqlValue.SqlBlob(bs) => "<blob:${Vector.length(bs)} bytes>"
        }
    }

    pub def nullVal(): SqlValue           = SqlValue.SqlNull
    pub def int(i: Int32): SqlValue       = SqlValue.SqlInt(i)
    pub def int64(i: Int64): SqlValue     = SqlValue.SqlInt64(i)
    pub def float(f: Float64): SqlValue   = SqlValue.SqlFloat(f)
    pub def text(s: String): SqlValue     = SqlValue.SqlText(s)
    pub def bool(b: Bool): SqlValue       = SqlValue.SqlBool(b)
    pub def blob(bs: Vector[Int8]): SqlValue = SqlValue.SqlBlob(bs)

    pub def optionalText(opt: Option[String]): SqlValue = match opt {
        case Some(s) => SqlValue.SqlText(s)
        case None    => SqlValue.SqlNull
    }

    pub def optionalInt(opt: Option[Int32]): SqlValue = match opt {
        case Some(i) => SqlValue.SqlInt(i)
        case None    => SqlValue.SqlNull
    }

    pub def optionalInt64(opt: Option[Int64]): SqlValue = match opt {
        case Some(i) => SqlValue.SqlInt64(i)
        case None    => SqlValue.SqlNull
    }

    pub def optionalFloat(opt: Option[Float64]): SqlValue = match opt {
        case Some(f) => SqlValue.SqlFloat(f)
        case None    => SqlValue.SqlNull
    }

    pub def optionalBool(opt: Option[Bool]): SqlValue = match opt {
        case Some(b) => SqlValue.SqlBool(b)
        case None    => SqlValue.SqlNull
    }

    pub def optionalBlob(opt: Option[Vector[Int8]]): SqlValue = match opt {
        case Some(bs) => SqlValue.SqlBlob(bs)
        case None     => SqlValue.SqlNull
    }

}
