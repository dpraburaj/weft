pub mod Weft.StaticStore {
    use Weft.StaticFile
    use Weft.StaticStore

    import java.lang.Exception
    import java.nio.file.Files
    import java.nio.file.LinkOption
    import java.nio.file.Path
    import java.nio.file.Paths

    ///
    /// Algebraic effect abstracting static asset storage so static file routes
    /// can be tested 100% purely with `runPure` and backed by the filesystem
    /// with `runFromDir` in production.
    ///
    pub eff StaticStore {
        def readFile(relativePath: String): Option[StaticFile]
    }

    ///
    /// 100% pure in-memory handler backed by a map of `relativePath -> bytes`.
    /// MIME types and ETags are computed automatically via `StaticFile.fromBytes`.
    ///
    pub def runPure(files: Map[String, Vector[Int8]], f: Unit -> a \ ef): a \ (ef - StaticStore) = {
        let normalized = Map.foldLeftWithKey((acc, k, v) -> {
            let cleanKey = normalizeKey(k);
            Map.insert(cleanKey, StaticFile.fromBytes(cleanKey, v, 0i64), acc)
        }, Map.empty(), files);
        runPureFiles(normalized, f)
    }

    ///
    /// 100% pure in-memory handler backed by pre-constructed `StaticFile` entries
    /// (useful when tests want to control `lastModifiedMs`, `contentType`, or `etag`).
    ///
    pub def runPureFiles(files: Map[String, StaticFile], f: Unit -> a \ ef): a \ (ef - StaticStore) = {
        let normalized = Map.foldLeftWithKey((acc, k, v) ->
            Map.insert(normalizeKey(k), v, acc)
        , Map.empty(), files);
        run {
            f()
        } with handler StaticStore {
            def readFile(relPath, k) =
                k(Map.get(normalizeKey(relPath), normalized))
        }
    }

    ///
    /// Filesystem-backed `StaticStore` handler serving files safely from `rootDir`.
    ///
    /// Defends against path traversal (`../`, symlinks escaping root, null bytes,
    /// backslashes) by canonicalizing both `rootDir` and the resolved file path.
    ///
    pub def runFromDir(rootDir: String, f: Unit -> a \ ef): a \ (ef - StaticStore) + IO = {
        let rootOpt = resolveCanonicalDir(rootDir);
        run {
            f()
        } with handler StaticStore {
            def readFile(relPath, k) =
                let fileOpt = match rootOpt {
                    case None       => None
                    case Some(root) => readSafeFromDir(root, relPath)
                };
                k(fileOpt)
        }
    }

    // --- Internal Helpers ---

    def normalizeKey(k: String): String =
        match String.stripPrefix({substr = "/"}, k) {
            case Some(rest) => normalizeKey(rest)
            case None       => k
        }

    def resolveCanonicalDir(dir: String): Option[Path] \ IO =
        try {
            let emptyParts: Array[String, IO] = Array#{} @ Static;
            let p = Paths.get(dir, emptyParts).toAbsolutePath().normalize();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (Files.isDirectory(p, linkOpts))
                Some(p.toRealPath(linkOpts))
            else
                None
        } catch {
            case _: Exception => None
        }

    def readSafeFromDir(root: Path, relPath: String): Option[StaticFile] \ IO =
        if (String.isEmpty(relPath) or
            String.contains({substr = "\\"}, relPath) or
            String.contains({substr = "\u0000"}, relPath))
            None
        else
            try {
                let candidate = root.resolve(relPath).normalize();
                let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
                if (not candidate.startsWith(root))
                    None
                else if (not Files.isRegularFile(candidate, linkOpts))
                    None
                else {
                    let real = candidate.toRealPath(linkOpts);
                    if (not real.startsWith(root) or not Files.isReadable(real))
                        None
                    else {
                        let bytes = Files.readAllBytes(real);
                        let mtime = Files.getLastModifiedTime(real, linkOpts).toMillis();
                        Some(StaticFile.fromBytes(relPath, Array.toVector(bytes), mtime))
                    }
                }
            } catch {
                case _: Exception => None
            }

}
