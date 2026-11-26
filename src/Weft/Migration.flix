pub mod Weft.Migration {
    use Weft.Db
    use Weft.DbError
    use Weft.Migration
    use Weft.Row
    use Weft.SqlValue

    ///
    /// A versioned, forward-only SQL schema migration.
    ///
    pub enum Migration {
        case Migration({
            version = Int32,
            name    = String,
            sql     = String
        })
    }

    pub def make(version: Int32, name: String, sql: String): Migration =
        Migration.Migration({ version = version, name = name, sql = sql })

    pub def version(m: Migration): Int32 = let Migration.Migration(r) = m; r#version
    pub def name(m: Migration): String   = let Migration.Migration(r) = m; r#name
    pub def sql(m: Migration): String    = let Migration.Migration(r) = m; r#sql

    ///
    /// Applies all pending migrations in ascending `version` order, tracking applied
    /// versions in `_weft_migrations`. Safe and idempotent to call on every startup.
    ///
    /// Returns the list of newly applied migration versions.
    ///
    pub def runAll(migrations: List[Migration]): List[Int32] \ {Db, DbError} = {
        let _ = Db.executeSql(
            "CREATE TABLE IF NOT EXISTS _weft_migrations (" +
            "version INTEGER PRIMARY KEY, " +
            "name TEXT NOT NULL, " +
            "applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
        );
        let appliedRows = Db.querySql("SELECT version FROM _weft_migrations");
        let appliedSet = List.foldLeft((acc, row) -> {
            let v = Row.requireInt("version", row);
            Set.insert(v, acc)
        }, Set.empty(), appliedRows);

        let sorted = List.sortBy(version, migrations);
        let pending = List.filter(m -> not Set.memberOf(version(m), appliedSet), sorted);

        List.map(m -> {
            Db.transaction(() -> {
                let stmts = splitStatements(sql(m));
                List.forEach(stmt -> {
                    let _ = Db.executeSql(stmt);
                    ()
                }, stmts);
                let _ = Db.execute(
                    "INSERT INTO _weft_migrations (version, name) VALUES (?, ?)",
                    SqlValue.int(version(m)) :: SqlValue.text(name(m)) :: Nil
                );
                version(m)
            })
        }, pending)
    }

    def splitStatements(rawSql: String): List[String] =
        String.splitOn({substr = ";"}, rawSql)
            |> List.map(String.trim)
            |> List.filter(s -> not String.isEmpty(s))

}
