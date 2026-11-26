pub mod Weft.Db {
    use Weft.Db
    use Weft.DbError
    use Weft.HttpError
    use Weft.Row
    use Weft.SqlValue

    ///
    /// Driver-agnostic algebraic effect for relational database operations.
    ///
    pub eff Db {
        def queryRows(sql: String, params: List[SqlValue]): List[Row]
        def execute(sql: String, params: List[SqlValue]): Int32
        def insertAndGetId(sql: String, params: List[SqlValue]): Int64
        def beginTx(): Unit
        def commitTx(): Unit
        def rollbackTx(): Unit
    }

    ///
    /// Runs a parameterized query with no bind parameters.
    ///
    pub def querySql(sql: String): List[Row] \ Db =
        Db.queryRows(sql, Nil)

    ///
    /// Runs a parameterized query and decodes every row using `decode`.
    ///
    pub def queryMap(sql: String, params: List[SqlValue], decode: Row -> a \ ef): List[a] \ Db + ef =
        Db.queryRows(sql, params) |> List.map(decode)

    ///
    /// Runs a parameterized query and returns the first row, if any.
    ///
    pub def queryOne(sql: String, params: List[SqlValue]): Option[Row] \ Db =
        match Db.queryRows(sql, params) {
            case r :: _ => Some(r)
            case Nil    => None
        }

    ///
    /// Runs a parameterized query and decodes the first row, if any.
    ///
    pub def queryOneMap(sql: String, params: List[SqlValue], decode: Row -> a \ ef): Option[a] \ Db + ef =
        match queryOne(sql, params) {
            case Some(r) => Some(decode(r))
            case None    => None
        }

    ///
    /// Executes a SQL statement with no bind parameters.
    ///
    pub def executeSql(sql: String): Int32 \ Db =
        Db.execute(sql, Nil)

    ///
    /// Runs `f` inside a database transaction.
    ///
    /// - Commits automatically if `f` returns normally.
    /// - Automatically rolls back and re-raises if `f` raises `DbError`!
    ///
    pub def transaction(f: Unit -> a \ ef): a \ ef + {Db, DbError} = {
        Db.beginTx();
        run {
            let result = f();
            Db.commitTx();
            result
        } with handler DbError {
            def raise(kind, msg, _k) = {
                Db.rollbackTx();
                DbError.raise(kind, msg)
            }
        }
    }

    ///
    /// Runs `f` inside a database transaction that automatically rolls back on
    /// EITHER `DbError` OR `HttpError` (e.g., validation failure or `404`/`403` mid-tx)!
    ///
    pub def transactionHttp(f: Unit -> a \ ef): a \ ef + {Db, DbError, HttpError} = {
        Db.beginTx();
        run {
            let result = f();
            Db.commitTx();
            result
        } with handler DbError {
            def raise(kind, msg, _k) = {
                Db.rollbackTx();
                DbError.raise(kind, msg)
            }
        } with handler HttpError {
            def raise(st, msg, _k) = {
                Db.rollbackTx();
                HttpError.raise(st, msg)
            }
        }
    }

    ///
    /// Pure mock handler for `Db` — useful for unit testing SQL-calling code with zero `IO`.
    ///
    pub def runMock(
        onQuery: (String, List[SqlValue]) -> List[Row] \ efq,
        onExecute: (String, List[SqlValue]) -> Int32 \ efe,
        onInsert: (String, List[SqlValue]) -> Int64 \ efi,
        f: Unit -> a \ ef
    ): a \ (ef - Db) + efq + efe + efi =
        run {
            f()
        } with handler Db {
            def queryRows(sql, params, k)      = k(onQuery(sql, params))
            def execute(sql, params, k)        = k(onExecute(sql, params))
            def insertAndGetId(sql, params, k) = k(onInsert(sql, params))
            def beginTx(k)                     = k()
            def commitTx(k)                    = k()
            def rollbackTx(k)                  = k()
        }

}
