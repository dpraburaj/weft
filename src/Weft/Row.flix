pub mod Weft.Row {
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.Row
    use Weft.SqlValue

    ///
    /// An immutable, materialized database row (case-insensitive column lookup).
    ///
    pub enum Row with Eq {
        case Row(Map[String, SqlValue])
    }

    pub def empty(): Row = Row.Row(Map.empty())

    pub def fromList(pairs: List[(String, SqlValue)]): Row =
        let m = List.foldLeft((acc, pair) -> {
            let (k, v) = pair;
            Map.insert(String.toLowerCase(k), v, acc)
        }, Map.empty(), pairs);
        Row.Row(m)

    pub def get(col: String, row: Row): Option[SqlValue] =
        let Row.Row(m) = row;
        Map.get(String.toLowerCase(col), m)

    pub def isNull(col: String, row: Row): Bool = match get(col, row) {
        case Some(SqlValue.SqlNull) => true
        case None                   => true
        case _                      => false
    }

    // --- Pure Accessors ---

    pub def getInt(col: String, row: Row): Option[Int32] = match get(col, row) {
        case Some(SqlValue.SqlInt(i))   => Some(i)
        case Some(SqlValue.SqlInt64(i)) => Int64.tryToInt32(i)
        case _                          => None
    }

    pub def getInt64(col: String, row: Row): Option[Int64] = match get(col, row) {
        case Some(SqlValue.SqlInt64(i)) => Some(i)
        case Some(SqlValue.SqlInt(i))   => Some(Int32.toInt64(i))
        case _                          => None
    }

    pub def getFloat(col: String, row: Row): Option[Float64] = match get(col, row) {
        case Some(SqlValue.SqlFloat(f)) => Some(f)
        case Some(SqlValue.SqlInt(i))   => Some(Int32.toFloat64(i))
        case Some(SqlValue.SqlInt64(i)) => Some(Int64.toFloat64(i))
        case _                          => None
    }

    pub def getString(col: String, row: Row): Option[String] = match get(col, row) {
        case Some(SqlValue.SqlText(s)) => Some(s)
        case _                         => None
    }

    pub def getBool(col: String, row: Row): Option[Bool] = match get(col, row) {
        case Some(SqlValue.SqlBool(b))  => Some(b)
        case Some(SqlValue.SqlInt(0))   => Some(false)
        case Some(SqlValue.SqlInt(1))   => Some(true)
        case Some(SqlValue.SqlInt64(0i64)) => Some(false)
        case Some(SqlValue.SqlInt64(1i64)) => Some(true)
        case _                          => None
    }

    // --- Effectful Extractors (`DbError`) ---

    pub def requireInt(col: String, row: Row): Int32 \ DbError =
        match getInt(col, row) {
            case Some(v) => v
            case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected Int32 in column '${col}'")
        }

    pub def requireInt64(col: String, row: Row): Int64 \ DbError =
        match getInt64(col, row) {
            case Some(v) => v
            case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected Int64 in column '${col}'")
        }

    pub def requireFloat(col: String, row: Row): Float64 \ DbError =
        match getFloat(col, row) {
            case Some(v) => v
            case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected Float64 in column '${col}'")
        }

    pub def requireString(col: String, row: Row): String \ DbError =
        match getString(col, row) {
            case Some(v) => v
            case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected String in column '${col}'")
        }

    pub def requireBool(col: String, row: Row): Bool \ DbError =
        match getBool(col, row) {
            case Some(v) => v
            case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected Bool in column '${col}'")
        }

    pub def optionalString(col: String, row: Row): Option[String] \ DbError =
        match get(col, row) {
            case None                      => None
            case Some(SqlValue.SqlNull)    => None
            case Some(SqlValue.SqlText(s)) => Some(s)
            case Some(_)                   => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected nullable String in column '${col}'")
        }

    pub def optionalInt(col: String, row: Row): Option[Int32] \ DbError =
        match get(col, row) {
            case None                      => None
            case Some(SqlValue.SqlNull)    => None
            case Some(SqlValue.SqlInt(i))  => Some(i)
            case Some(SqlValue.SqlInt64(i)) => match Int64.tryToInt32(i) {
                case Some(n) => Some(n)
                case None    => DbError.raise(DbErrorKind.ColumnDecodeError, "Int64 overflow in column '${col}'")
            }
            case Some(_) => DbError.raise(DbErrorKind.ColumnDecodeError, "Expected nullable Int32 in column '${col}'")
        }

}
