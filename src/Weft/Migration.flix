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

    ///
    /// Splits a multi-statement SQL migration safely without splitting inside:
    /// - single-quoted string literals (`'a;b'`, `'it''s'`)
    /// - double-quoted identifiers (`"col;name"`)
    /// - line (`-- ...`) and block (`/* ... */`) comments
    /// - `BEGIN ... END` compound blocks (e.g. `CREATE TRIGGER ... BEGIN ...; END;`)
    ///
    pub def splitStatements(rawSql: String): List[String] = {
        let len = String.length(rawSql);
        def isWordChar(c: Char): Bool =
            Char.isLetterOrDigit(c) or c == '_';

        def matchKeywordAt(i: Int32, kw: String): Bool = {
            let kwLen = String.length(kw);
            if (i + kwLen > len)
                false
            else {
                let prevOk = i == 0 or not isWordChar(String.charAt(i - 1, rawSql));
                let nextOk = i + kwLen == len or not isWordChar(String.charAt(i + kwLen, rawSql));
                prevOk and nextOk and
                    String.toUpperCase(String.slice({start = i}, {end = i + kwLen}, rawSql)) == kw
            }
        };

        def loop(
            i: Int32,
            stmtStart: Int32,
            inSingle: Bool,
            inDouble: Bool,
            inLineComment: Bool,
            inBlockComment: Bool,
            beginDepth: Int32,
            acc: List[String]
        ): List[String] = {
            if (i >= len) {
                let tail = String.trim(String.slice({start = stmtStart}, {end = len}, rawSql));
                let finalAcc = if (String.isEmpty(tail)) acc else tail :: acc;
                List.reverse(finalAcc)
            } else {
                let c = String.charAt(i, rawSql);
                if (inLineComment) {
                    if (c == '\n')
                        loop(i + 1, stmtStart, false, false, false, false, beginDepth, acc)
                    else
                        loop(i + 1, stmtStart, false, false, true, false, beginDepth, acc)
                } else if (inBlockComment) {
                    if (c == '*' and i + 1 < len and String.charAt(i + 1, rawSql) == '/')
                        loop(i + 2, stmtStart, false, false, false, false, beginDepth, acc)
                    else
                        loop(i + 1, stmtStart, false, false, false, true, beginDepth, acc)
                } else if (inSingle) {
                    if (c == '\'' and i + 1 < len and String.charAt(i + 1, rawSql) == '\'')
                        loop(i + 2, stmtStart, true, false, false, false, beginDepth, acc)
                    else if (c == '\'')
                        loop(i + 1, stmtStart, false, false, false, false, beginDepth, acc)
                    else
                        loop(i + 1, stmtStart, true, false, false, false, beginDepth, acc)
                } else if (inDouble) {
                    if (c == '"' and i + 1 < len and String.charAt(i + 1, rawSql) == '"')
                        loop(i + 2, stmtStart, false, true, false, false, beginDepth, acc)
                    else if (c == '"')
                        loop(i + 1, stmtStart, false, false, false, false, beginDepth, acc)
                    else
                        loop(i + 1, stmtStart, false, true, false, false, beginDepth, acc)
                } else if (c == '-' and i + 1 < len and String.charAt(i + 1, rawSql) == '-') {
                    loop(i + 2, stmtStart, false, false, true, false, beginDepth, acc)
                } else if (c == '/' and i + 1 < len and String.charAt(i + 1, rawSql) == '*') {
                    loop(i + 2, stmtStart, false, false, false, true, beginDepth, acc)
                } else if (c == '\'') {
                    loop(i + 1, stmtStart, true, false, false, false, beginDepth, acc)
                } else if (c == '"') {
                    loop(i + 1, stmtStart, false, true, false, false, beginDepth, acc)
                } else if (matchKeywordAt(i, "BEGIN")) {
                    loop(i + 5, stmtStart, false, false, false, false, beginDepth + 1, acc)
                } else if (beginDepth > 0 and matchKeywordAt(i, "END")) {
                    loop(i + 3, stmtStart, false, false, false, false, beginDepth - 1, acc)
                } else if (c == ';' and beginDepth == 0) {
                    let chunk = String.trim(String.slice({start = stmtStart}, {end = i}, rawSql));
                    let nextAcc = if (String.isEmpty(chunk)) acc else chunk :: acc;
                    loop(i + 1, i + 1, false, false, false, false, 0, nextAcc)
                } else {
                    loop(i + 1, stmtStart, false, false, false, false, beginDepth, acc)
                }
            }
        };
        loop(0, 0, false, false, false, false, 0, Nil)
    }

}
