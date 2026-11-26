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
    }

    instance ToString[SqlValue] {
        pub def toString(v: SqlValue): String = match v {
            case SqlValue.SqlNull     => "NULL"
            case SqlValue.SqlInt(i)   => "${i}"
            case SqlValue.SqlInt64(i) => "${i}"
            case SqlValue.SqlFloat(f) => "${f}"
            case SqlValue.SqlText(s)  => s
            case SqlValue.SqlBool(b)  => "${b}"
        }
    }

    pub def nullVal(): SqlValue          = SqlValue.SqlNull
    pub def int(i: Int32): SqlValue      = SqlValue.SqlInt(i)
    pub def int64(i: Int64): SqlValue    = SqlValue.SqlInt64(i)
    pub def float(f: Float64): SqlValue  = SqlValue.SqlFloat(f)
    pub def text(s: String): SqlValue    = SqlValue.SqlText(s)
    pub def bool(b: Bool): SqlValue      = SqlValue.SqlBool(b)

    pub def optionalText(opt: Option[String]): SqlValue = match opt {
        case Some(s) => SqlValue.SqlText(s)
        case None    => SqlValue.SqlNull
    }

    pub def optionalInt(opt: Option[Int32]): SqlValue = match opt {
        case Some(i) => SqlValue.SqlInt(i)
        case None    => SqlValue.SqlNull
    }

}
