pub mod Weft.SqlBuilder {
    use Weft.SqlBuilder
    use Weft.SqlValue

    ///
    /// Lightweight immutable parameterized SQL query builder for dynamic filtering,
    /// `IN (...)` clauses, and pagination while keeping SQL fragments and bind params
    /// guaranteed in sync.
    ///
    pub enum SqlBuilder {
        case SqlBuilder({
            chunks = List[String],
            params = List[SqlValue]
        })
    }

    pub def empty(): SqlBuilder =
        SqlBuilder.SqlBuilder({ chunks = Nil, params = Nil })

    pub def fromSql(sql: String): SqlBuilder =
        SqlBuilder.SqlBuilder({ chunks = sql :: Nil, params = Nil })

    ///
    /// Appends raw SQL text (no bind parameters).
    ///
    pub def append(sql: String, b: SqlBuilder): SqlBuilder =
        let SqlBuilder.SqlBuilder(r) = b;
        SqlBuilder.SqlBuilder({ chunks = sql :: r#chunks | r })

    ///
    /// Appends a SQL fragment together with a single bind parameter.
    ///
    pub def appendParam(sql: String, v: SqlValue, b: SqlBuilder): SqlBuilder =
        let SqlBuilder.SqlBuilder(r) = b;
        SqlBuilder.SqlBuilder({
            chunks = sql :: r#chunks,
            params = v :: r#params
        })

    ///
    /// Appends a SQL fragment together with multiple bind parameters in order.
    ///
    pub def appendParams(sql: String, vs: List[SqlValue], b: SqlBuilder): SqlBuilder =
        let SqlBuilder.SqlBuilder(r) = b;
        SqlBuilder.SqlBuilder({
            chunks = sql :: r#chunks,
            params = List.append(List.reverse(vs), r#params)
        })

    ///
    /// Appends `<column> IN (?, ?, ...)` for non-empty `vals`, or `1 = 0` for an empty list.
    ///
    pub def appendIn(column: String, vals: List[SqlValue], b: SqlBuilder): SqlBuilder =
        if (List.isEmpty(vals))
            append("1 = 0", b)
        else {
            let placeholders = List.repeat(List.length(vals), "?") |> String.intercalate(", ");
            appendParams("${column} IN (${placeholders})", vals, b)
        }

    ///
    /// Appends ` WHERE <c1> AND <c2> ...` for all provided `(sqlExpr, bindParams)` predicates.
    /// Emits nothing when `predicates` is empty.
    ///
    pub def appendWhere(predicates: List[(String, List[SqlValue])], b: SqlBuilder): SqlBuilder =
        match predicates {
            case Nil => b
            case first :: rest =>
                let (sql0, ps0) = first;
                let b1 = appendParams(" WHERE ${sql0}", ps0, b);
                List.foldLeft((acc, pred) -> {
                    let (s, ps) = pred;
                    appendParams(" AND ${s}", ps, acc)
                }, b1, rest)
        }

    ///
    /// Appends ` LIMIT ? OFFSET ?` for pagination.
    ///
    pub def appendLimitOffset(limit: Int32, offset: Int32, b: SqlBuilder): SqlBuilder =
        appendParams(
            " LIMIT ? OFFSET ?",
            SqlValue.int(Int32.max(0, limit)) :: SqlValue.int(Int32.max(0, offset)) :: Nil,
            b
        )

    ///
    /// Materializes the final `(sqlString, orderedParams)` ready for `Db.queryRows` / `Db.queryMap`.
    ///
    pub def build(b: SqlBuilder): (String, List[SqlValue]) =
        let SqlBuilder.SqlBuilder(r) = b;
        let sql = String.intercalate("", List.reverse(r#chunks));
        (sql, List.reverse(r#params))

}
