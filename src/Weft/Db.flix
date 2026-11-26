pub mod Weft.Db {
    use Weft.Db
    use Weft.DbError
    use Weft.DbErrorKind
    use Weft.HttpError
    use Weft.Row
    use Weft.SqlValue

    ///
    /// Driver-agnostic algebraic effect for relational database operations.
    ///
    /// Low-level operations return `Result[(DbErrorKind, String), a]` so that `DbError`
    /// is always raised at the call site (inside any enclosing `Db.transaction`,
    /// `Db.transactionHttp`, `DbError.runToResult`, or `Middleware.dbErrorToHttp`).
    ///
    pub eff Db {
        def rawQueryRows(sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), List[Row]]
        def rawExecute(sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int32]
        def rawInsertAndGetId(sql: String, params: List[SqlValue]): Result[(DbErrorKind, String), Int64]
        def rawBeginTx(): Result[(DbErrorKind, String), Unit]
        def rawCommitTx(): Result[(DbErrorKind, String), Unit]
        def rawRollbackTx(): Unit
    }

    def unwrapDb(res: Result[(DbErrorKind, String), a]): a \ DbError = match res {
        case Ok(v)            => v
        case Err((kind, msg)) => DbError.raise(kind, msg)
    }

    ///
    /// Runs a parameterized query and returns all matching rows.
    ///
    pub def queryRows(sql: String, params: List[SqlValue]): List[Row] \ {Db, DbError} =
        unwrapDb(Db.rawQueryRows(sql, params))

    ///
    /// Executes a parameterized SQL statement and returns the affected row count.
    ///
    pub def execute(sql: String, params: List[SqlValue]): Int32 \ {Db, DbError} =
        unwrapDb(Db.rawExecute(sql, params))

    ///
    /// Executes a parameterized `INSERT` statement and returns the generated row ID.
    ///
    pub def insertAndGetId(sql: String, params: List[SqlValue]): Int64 \ {Db, DbError} =
        unwrapDb(Db.rawInsertAndGetId(sql, params))

    pub def beginTx(): Unit \ {Db, DbError} =
        unwrapDb(Db.rawBeginTx())

    pub def commitTx(): Unit \ {Db, DbError} =
        unwrapDb(Db.rawCommitTx())

    pub def rollbackTx(): Unit \ Db =
        Db.rawRollbackTx()

    ///
    /// Runs a parameterized query with no bind parameters.
    ///
    pub def querySql(sql: String): List[Row] \ {Db, DbError} =
        queryRows(sql, Nil)

    ///
    /// Runs a parameterized query and decodes every row using `decode`.
    ///
    pub def queryMap(sql: String, params: List[SqlValue], decode: Row -> a \ ef): List[a] \ {Db, DbError} + ef =
        queryRows(sql, params) |> List.map(decode)

    ///
    /// Runs a parameterized query and returns the first row, if any.
    ///
    pub def queryOne(sql: String, params: List[SqlValue]): Option[Row] \ {Db, DbError} =
        match queryRows(sql, params) {
            case r :: _ => Some(r)
            case Nil    => None
        }

    ///
    /// Runs a parameterized query and decodes the first row, if any.
    ///
    pub def queryOneMap(sql: String, params: List[SqlValue], decode: Row -> a \ ef): Option[a] \ {Db, DbError} + ef =
        match queryOne(sql, params) {
            case Some(r) => Some(decode(r))
            case None    => None
        }

    ///
    /// Executes a SQL statement with no bind parameters.
    ///
    pub def executeSql(sql: String): Int32 \ {Db, DbError} =
        execute(sql, Nil)

    ///
    /// Runs `f` inside a database transaction (or a nested `SAVEPOINT` when already in a tx).
    ///
    /// - Commits/releases automatically if `f` returns normally.
    /// - Automatically rolls back and re-raises if `f` raises `DbError`!
    ///
    pub def transaction(f: Unit -> a \ ef): a \ ef + {Db, DbError} = {
        beginTx();
        run {
            let result = f();
            commitTx();
            result
        } with handler DbError {
            def raise(kind, msg, _k) = {
                rollbackTx();
                DbError.raise(kind, msg)
            }
        }
    }

    ///
    /// Runs `f` inside a database transaction (or nested `SAVEPOINT`) that automatically
    /// rolls back on EITHER `DbError` OR `HttpError`!
    ///
    pub def transactionHttp(f: Unit -> a \ ef): a \ ef + {Db, DbError, HttpError} = {
        beginTx();
        run {
            let result = f();
            commitTx();
            result
        } with handler DbError {
            def raise(kind, msg, _k) = {
                rollbackTx();
                DbError.raise(kind, msg)
            }
        } with handler HttpError {
            def raise(st, msg, _k) = {
                rollbackTx();
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
            def rawQueryRows(sql, params, k)      = k(Ok(onQuery(sql, params)))
            def rawExecute(sql, params, k)        = k(Ok(onExecute(sql, params)))
            def rawInsertAndGetId(sql, params, k) = k(Ok(onInsert(sql, params)))
            def rawBeginTx(k)                     = k(Ok(()))
            def rawCommitTx(k)                    = k(Ok(()))
            def rawRollbackTx(k)                  = k()
        }

}
