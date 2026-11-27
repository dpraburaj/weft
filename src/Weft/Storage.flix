pub mod Weft.Storage {
    use Time.Clock
    use Weft.Body
    use Weft.InMemoryStorage
    use Weft.Mime
    use Weft.StaticFile
    use Weft.StaticStore
    use Weft.Storage
    use Weft.StorageError
    use Weft.StorageErrorKind
    use Weft.StoredFile
    use Weft.UploadedFile

    import java.io.{File => JFile}
    import java.io.FileOutputStream
    import java.lang.Exception
    import java.nio.file.Files
    import java.nio.file.LinkOption
    import java.nio.file.Path
    import java.nio.file.Paths
    import java.util.concurrent.locks.ReentrantLock

    ///
    /// Algebraic effect for writable object/file storage (inspired by Laravel's `Storage`).
    ///
    /// Backends:
    /// - `Storage.runPure` / `Storage.runPureRecording` (100% pure region-scoped fake disk for tests)
    /// - `Storage.runInMemory` (thread-safe concurrent store for virtual-thread servers)
    /// - `Storage.runLocalDir` (path-traversal-safe local filesystem driver)
    ///
    pub eff Storage {
        def rawPut(path: String, data: Vector[Int8], nowMs: Int64): Result[(StorageErrorKind, String), Unit]
        def rawGet(path: String): Result[(StorageErrorKind, String), Vector[Int8]]
        def rawGetInfo(path: String): Result[(StorageErrorKind, String), StoredFile]
        def rawDelete(path: String): Result[(StorageErrorKind, String), Bool]
        def rawExists(path: String): Bool
        def rawList(prefix: String): Result[(StorageErrorKind, String), List[StoredFile]]
    }

    def unwrapStorage(res: Result[(StorageErrorKind, String), a]): a \ StorageError = match res {
        case Ok(v)            => v
        case Err((kind, msg)) => StorageError.raise(kind, msg)
    }

    // --- Ergonomic Helpers ---

    ///
    /// Stores raw bytes at relative `path`, creating parent directories as needed.
    ///
    pub def put(path: String, data: Vector[Int8]): Unit \ {Storage, StorageError, Clock} =
        unwrapStorage(Storage.rawPut(path, data, Clock.now()))

    ///
    /// Stores a UTF-8 string at relative `path`.
    ///
    pub def putText(path: String, text: String): Unit \ {Storage, StorageError, Clock} =
        put(path, Body.utf8Bytes(text))

    ///
    /// Stores a multipart `UploadedFile` at relative `path`.
    ///
    pub def putUploaded(path: String, file: UploadedFile): Unit \ {Storage, StorageError, Clock} =
        put(path, UploadedFile.data(file))

    ///
    /// Reads raw bytes from `path`, raising `StorageError` (`NotFound` / `InvalidPath`) on failure.
    ///
    pub def get(path: String): Vector[Int8] \ {Storage, StorageError} =
        unwrapStorage(Storage.rawGet(path))

    ///
    /// Reads raw bytes from `path`, returning `None` if missing or invalid.
    ///
    pub def getOpt(path: String): Option[Vector[Int8]] \ Storage =
        match Storage.rawGet(path) {
            case Ok(bs) => Some(bs)
            case Err(_) => None
        }

    ///
    /// Reads UTF-8 text from `path`.
    ///
    pub def getText(path: String): String \ {Storage, StorageError} =
        Body.utf8String(get(path))

    ///
    /// Reads UTF-8 text from `path`, returning `None` if missing or invalid.
    ///
    pub def getTextOpt(path: String): Option[String] \ Storage =
        Option.map(Body.utf8String, getOpt(path))

    ///
    /// Returns metadata (`StoredFile`) for `path`.
    ///
    pub def stat(path: String): StoredFile \ {Storage, StorageError} =
        unwrapStorage(Storage.rawGetInfo(path))

    ///
    /// Deletes `path`, returning `true` if a file existed and was deleted, `false` otherwise.
    ///
    pub def delete(path: String): Bool \ {Storage, StorageError} =
        unwrapStorage(Storage.rawDelete(path))

    ///
    /// Returns `true` if a file exists at `path`.
    ///
    pub def exists(path: String): Bool \ Storage =
        Storage.rawExists(path)

    ///
    /// Lists all stored files whose relative path starts with `prefix` (use `""` for all files),
    /// sorted ascending by path.
    ///
    pub def list(prefix: String): List[StoredFile] \ {Storage, StorageError} =
        unwrapStorage(Storage.rawList(prefix))

    ///
    /// Bridges `Storage` into `StaticStore` so uploaded files can be served directly
    /// through `StaticFiles.routes` with MIME detection and `ETag`/`304` support!
    ///
    pub def runStaticStore(f: Unit -> a \ ef): a \ (ef - StaticStore) + Storage =
        run {
            f()
        } with handler StaticStore {
            def readFile(relPath, k) = {
                let fileOpt = match (Storage.rawGet(relPath), Storage.rawGetInfo(relPath)) {
                    case (Ok(bytes), Ok(info)) =>
                        Some(StaticFile.fromBytes(StoredFile.path(info), bytes, StoredFile.lastModifiedMs(info)))
                    case _ =>
                        None
                };
                k(fileOpt)
            }
        }

    // --- Path Sanitization ---

    ///
    /// Normalizes and validates a relative object path, rejecting empty paths, backslashes,
    /// null bytes, empty segments (`//`), and dot segments (`.` or `..`).
    ///
    pub def sanitizePath(raw: String): Result[String, String] = {
        let stripped = stripLeadingSlashes(raw);
        if (String.isEmpty(stripped))
            Err("Storage path must not be empty")
        else if (String.contains({substr = "\\"}, stripped) or String.contains({substr = "\u0000"}, stripped))
            Err("Storage path contains forbidden characters: '${raw}'")
        else {
            let segs = String.splitOn({substr = "/"}, stripped);
            let bad = List.exists(s -> String.isEmpty(s) or s == "." or s == "..", segs);
            if (bad)
                Err("Storage path contains invalid traversal or empty segment: '${raw}'")
            else
                Ok(String.intercalate("/", segs))
        }
    }

    ///
    /// Validates a prefix for `Storage.list` (`""` is allowed to list everything).
    ///
    pub def sanitizePrefix(raw: String): Result[String, String] = {
        let stripped = stripLeadingSlashes(raw);
        let cleaned = stripTrailingSlashes(stripped);
        if (String.isEmpty(cleaned))
            Ok("")
        else
            sanitizePath(cleaned)
    }

    def stripLeadingSlashes(s: String): String =
        match String.stripPrefix({substr = "/"}, s) {
            case Some(rest) => stripLeadingSlashes(rest)
            case None       => s
        }

    def stripTrailingSlashes(s: String): String =
        match String.stripSuffix({substr = "/"}, s) {
            case Some(rest) => stripTrailingSlashes(rest)
            case None       => s
        }

    def matchesPrefix(prefix: String, path: String): Bool =
        if (String.isEmpty(prefix))
            true
        else
            path == prefix or String.startsWith({prefix = "${prefix}/"}, path)

    def makeStoredFile(path: String, data: Vector[Int8], mtime: Int64): StoredFile =
        StoredFile.make(path, Int32.toInt64(Vector.length(data)), Mime.fromPath(path), mtime)

    // --- 1. Pure Region-Scoped Backend (Zero IO, Laravel's `Storage::fake()`) ---

    ///
    /// 100% pure region-scoped `Storage` handler seeded with `initial` files.
    ///
    pub def runPure(initial: Map[String, Vector[Int8]], f: Unit -> a \ ef): a \ (ef - Storage) =
        let (res, _) = runPureRecording(initial, f);
        res

    ///
    /// 100% pure region-scoped `Storage` handler returning `(result, finalFilesMap)`.
    /// Ideal for asserting uploaded/deleted files in zero-IO tests!
    ///
    pub def runPureRecording(
        initial: Map[String, Vector[Int8]],
        f: Unit -> a \ ef
    ): (a, Map[String, Vector[Int8]]) \ (ef - Storage) = {
        let seeded = Map.foldLeftWithKey((acc, k, v) ->
            match sanitizePath(k) {
                case Ok(clean) => Map.insert(clean, (v, 0i64), acc)
                case Err(_)    => acc
            }
        , Map.empty(), initial);
        region rc {
            let filesRef = Ref.fresh(rc, seeded);
            let res = run {
                f()
            } with handler Storage {
                def rawPut(path, data, nowMs, k) =
                    match sanitizePath(path) {
                        case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                        case Ok(clean) =>
                            Ref.transform(m -> Map.insert(clean, (data, nowMs), m), filesRef);
                            k(Ok(()))
                    }
                def rawGet(path, k) =
                    match sanitizePath(path) {
                        case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                        case Ok(clean) =>
                            match Map.get(clean, Ref.get(filesRef)) {
                                case Some((bs, _)) => k(Ok(bs))
                                case None          => k(Err((StorageErrorKind.NotFound, "File not found: ${clean}")))
                            }
                    }
                def rawGetInfo(path, k) =
                    match sanitizePath(path) {
                        case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                        case Ok(clean) =>
                            match Map.get(clean, Ref.get(filesRef)) {
                                case Some((bs, mtime)) => k(Ok(makeStoredFile(clean, bs, mtime)))
                                case None             => k(Err((StorageErrorKind.NotFound, "File not found: ${clean}")))
                            }
                    }
                def rawDelete(path, k) =
                    match sanitizePath(path) {
                        case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                        case Ok(clean) =>
                            let existed = Map.memberOf(clean, Ref.get(filesRef));
                            if (existed) Ref.transform(m -> Map.remove(clean, m), filesRef) else ();
                            k(Ok(existed))
                    }
                def rawExists(path, k) =
                    match sanitizePath(path) {
                        case Err(_)    => k(false)
                        case Ok(clean) => k(Map.memberOf(clean, Ref.get(filesRef)))
                    }
                def rawList(prefix, k) =
                    match sanitizePrefix(prefix) {
                        case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                        case Ok(cleanPrefix) =>
                            let items = Map.foldLeftWithKey((acc, p, entry) -> {
                                let (bs, mtime) = entry;
                                if (matchesPrefix(cleanPrefix, p))
                                    makeStoredFile(p, bs, mtime) :: acc
                                else
                                    acc
                            }, Nil, Ref.get(filesRef)) |> List.sortBy(StoredFile.path);
                            k(Ok(items))
                    }
            };
            let finalMap = Map.map(match (bs, _) -> bs, Ref.get(filesRef));
            (res, finalMap)
        }
    }

    // --- 2. Thread-Safe Concurrent In-Memory Backend ---

    ///
    /// Creates a thread-safe concurrent in-memory storage handle.
    ///
    pub def makeInMemory(): InMemoryStorage \ IO =
        InMemoryStorage.InMemoryStorage(
            new ReentrantLock(),
            Ref.fresh(Static, Map.empty())
        )

    def withLock(lock: ReentrantLock, action: Unit -> b \ IO): b \ IO = {
        lock.lock();
        try {
            let r = action();
            lock.unlock();
            r
        } catch {
            case ex: Exception =>
                lock.unlock();
                throw ex
        }
    }

    ///
    /// Handles `Storage` against a shared thread-safe `InMemoryStorage`.
    ///
    pub def runInMemory(store: InMemoryStorage, f: Unit -> a \ ef): a \ (ef - Storage) + IO = {
        let InMemoryStorage.InMemoryStorage(lock, mapRef) = store;
        run {
            f()
        } with handler Storage {
            def rawPut(path, data, nowMs, k) =
                match sanitizePath(path) {
                    case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case Ok(clean) =>
                        withLock(lock, () -> Ref.transform(m -> Map.insert(clean, (data, nowMs), m), mapRef));
                        k(Ok(()))
                }
            def rawGet(path, k) =
                match sanitizePath(path) {
                    case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case Ok(clean) =>
                        let res = withLock(lock, () ->
                            match Map.get(clean, Ref.get(mapRef)) {
                                case Some((bs, _)) => Ok(bs)
                                case None          => Err((StorageErrorKind.NotFound, "File not found: ${clean}"))
                            }
                        );
                        k(res)
                }
            def rawGetInfo(path, k) =
                match sanitizePath(path) {
                    case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case Ok(clean) =>
                        let res = withLock(lock, () ->
                            match Map.get(clean, Ref.get(mapRef)) {
                                case Some((bs, mtime)) => Ok(makeStoredFile(clean, bs, mtime))
                                case None             => Err((StorageErrorKind.NotFound, "File not found: ${clean}"))
                            }
                        );
                        k(res)
                }
            def rawDelete(path, k) =
                match sanitizePath(path) {
                    case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case Ok(clean) =>
                        let existed = withLock(lock, () -> {
                            let present = Map.memberOf(clean, Ref.get(mapRef));
                            if (present) Ref.transform(m -> Map.remove(clean, m), mapRef) else ();
                            present
                        });
                        k(Ok(existed))
                }
            def rawExists(path, k) =
                match sanitizePath(path) {
                    case Err(_)    => k(false)
                    case Ok(clean) =>
                        let present = withLock(lock, () -> Map.memberOf(clean, Ref.get(mapRef)));
                        k(present)
                }
            def rawList(prefix, k) =
                match sanitizePrefix(prefix) {
                    case Err(msg) => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case Ok(cleanPrefix) =>
                        let items = withLock(lock, () ->
                            Map.foldLeftWithKey((acc, p, entry) -> {
                                let (bs, mtime) = entry;
                                if (matchesPrefix(cleanPrefix, p))
                                    makeStoredFile(p, bs, mtime) :: acc
                                else
                                    acc
                            }, Nil, Ref.get(mapRef)) |> List.sortBy(StoredFile.path)
                        );
                        k(Ok(items))
                }
        }
    }

    // --- 3. Local Filesystem Backend ---

    ///
    /// Filesystem-backed `Storage` handler rooted at `rootDir` (creating `rootDir` if needed).
    /// Defends against path traversal (`../`), backslashes, null bytes, and symlink escapes.
    ///
    pub def runLocalDir(rootDir: String, f: Unit -> a \ ef): a \ (ef - Storage) + IO = {
        let rootRes = ensureCanonicalDir(rootDir);
        run {
            f()
        } with handler Storage {
            def rawPut(path, data, _nowMs, k) =
                match (rootRes, sanitizePath(path)) {
                    case (Err(msg), _)    => k(Err((StorageErrorKind.IoError, msg)))
                    case (_, Err(msg))    => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case (Ok(root), Ok(clean)) => k(writeLocalFile(root, clean, data))
                }
            def rawGet(path, k) =
                match (rootRes, sanitizePath(path)) {
                    case (Err(msg), _)    => k(Err((StorageErrorKind.IoError, msg)))
                    case (_, Err(msg))    => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case (Ok(root), Ok(clean)) => k(readLocalFile(root, clean))
                }
            def rawGetInfo(path, k) =
                match (rootRes, sanitizePath(path)) {
                    case (Err(msg), _)    => k(Err((StorageErrorKind.IoError, msg)))
                    case (_, Err(msg))    => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case (Ok(root), Ok(clean)) => k(statLocalFile(root, clean))
                }
            def rawDelete(path, k) =
                match (rootRes, sanitizePath(path)) {
                    case (Err(msg), _)    => k(Err((StorageErrorKind.IoError, msg)))
                    case (_, Err(msg))    => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case (Ok(root), Ok(clean)) => k(deleteLocalFile(root, clean))
                }
            def rawExists(path, k) =
                match (rootRes, sanitizePath(path)) {
                    case (Ok(root), Ok(clean)) => k(localFileExists(root, clean))
                    case _                     => k(false)
                }
            def rawList(prefix, k) =
                match (rootRes, sanitizePrefix(prefix)) {
                    case (Err(msg), _)    => k(Err((StorageErrorKind.IoError, msg)))
                    case (_, Err(msg))    => k(Err((StorageErrorKind.InvalidPath, msg)))
                    case (Ok(root), Ok(cleanPrefix)) => k(listLocalFiles(root, cleanPrefix))
                }
        }
    }

    def ensureCanonicalDir(dir: String): Result[String, Path] \ IO =
        try {
            let emptyParts: Array[String, IO] = Array#{} @ Static;
            let p = Paths.get(dir, emptyParts).toAbsolutePath().normalize();
            let dirFile = p.toFile();
            if (not dirFile.exists()) {
                let _ = dirFile.mkdirs();
                ()
            } else ();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (Files.isDirectory(p, linkOpts))
                Ok(p.toRealPath(linkOpts))
            else
                Err("Storage root is not a directory: ${dir}")
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err(if (Object.isNull(rawMsg)) "Failed to initialize storage directory" else rawMsg)
        }

    def writeLocalFile(root: Path, cleanRel: String, data: Vector[Int8]): Result[(StorageErrorKind, String), Unit] \ IO =
        try {
            let candidate = root.resolve(cleanRel).normalize();
            if (not candidate.startsWith(root) or candidate.equals(root))
                Err((StorageErrorKind.InvalidPath, "Resolved path escapes storage root: ${cleanRel}"))
            else {
                let targetFile = candidate.toFile();
                let parentFile = targetFile.getParentFile();
                if (not Object.isNull(parentFile) and not parentFile.exists()) {
                    let _ = parentFile.mkdirs();
                    ()
                } else ();
                let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
                let parentReal = candidate.getParent().toRealPath(linkOpts);
                if (not parentReal.startsWith(root))
                    Err((StorageErrorKind.PermissionDenied, "Target parent escapes storage root via symlink"))
                else {
                    let fos = new FileOutputStream(targetFile);
                    try {
                        fos.write(Vector.toArray(Static, data));
                        fos.close();
                        Ok(())
                    } catch {
                        case ex: Exception =>
                            try { fos.close() } catch { case _: Exception => () };
                            throw ex
                    }
                }
            }
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err((StorageErrorKind.IoError, if (Object.isNull(rawMsg)) "Failed to write file" else rawMsg))
        }

    def readLocalFile(root: Path, cleanRel: String): Result[(StorageErrorKind, String), Vector[Int8]] \ IO =
        try {
            let candidate = root.resolve(cleanRel).normalize();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (not candidate.startsWith(root))
                Err((StorageErrorKind.InvalidPath, "Path escapes storage root: ${cleanRel}"))
            else if (not Files.isRegularFile(candidate, linkOpts))
                Err((StorageErrorKind.NotFound, "File not found: ${cleanRel}"))
            else {
                let real = candidate.toRealPath(linkOpts);
                if (not real.startsWith(root))
                    Err((StorageErrorKind.PermissionDenied, "Symlink escapes storage root: ${cleanRel}"))
                else
                    Ok(Array.toVector(Files.readAllBytes(real)))
            }
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err((StorageErrorKind.IoError, if (Object.isNull(rawMsg)) "Failed to read file" else rawMsg))
        }

    def statLocalFile(root: Path, cleanRel: String): Result[(StorageErrorKind, String), StoredFile] \ IO =
        try {
            let candidate = root.resolve(cleanRel).normalize();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (not candidate.startsWith(root))
                Err((StorageErrorKind.InvalidPath, "Path escapes storage root: ${cleanRel}"))
            else if (not Files.isRegularFile(candidate, linkOpts))
                Err((StorageErrorKind.NotFound, "File not found: ${cleanRel}"))
            else {
                let real = candidate.toRealPath(linkOpts);
                if (not real.startsWith(root))
                    Err((StorageErrorKind.PermissionDenied, "Symlink escapes storage root: ${cleanRel}"))
                else {
                    let size = Files.size(real);
                    let mtime = Files.getLastModifiedTime(real, linkOpts).toMillis();
                    Ok(StoredFile.make(cleanRel, size, Mime.fromPath(cleanRel), mtime))
                }
            }
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err((StorageErrorKind.IoError, if (Object.isNull(rawMsg)) "Failed to stat file" else rawMsg))
        }

    def deleteLocalFile(root: Path, cleanRel: String): Result[(StorageErrorKind, String), Bool] \ IO =
        try {
            let candidate = root.resolve(cleanRel).normalize();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (not candidate.startsWith(root))
                Err((StorageErrorKind.InvalidPath, "Path escapes storage root: ${cleanRel}"))
            else if (not Files.isRegularFile(candidate, linkOpts))
                Ok(false)
            else {
                let real = candidate.toRealPath(linkOpts);
                if (not real.startsWith(root))
                    Err((StorageErrorKind.PermissionDenied, "Symlink escapes storage root: ${cleanRel}"))
                else
                    Ok(Files.deleteIfExists(real))
            }
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err((StorageErrorKind.IoError, if (Object.isNull(rawMsg)) "Failed to delete file" else rawMsg))
        }

    def localFileExists(root: Path, cleanRel: String): Bool \ IO =
        try {
            let candidate = root.resolve(cleanRel).normalize();
            let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
            if (not candidate.startsWith(root) or not Files.isRegularFile(candidate, linkOpts))
                false
            else
                candidate.toRealPath(linkOpts).startsWith(root)
        } catch {
            case _: Exception => false
        }

    def listLocalFiles(root: Path, cleanPrefix: String): Result[(StorageErrorKind, String), List[StoredFile]] \ IO =
        try {
            let collected = walkLocal(root, root.toFile(), "", cleanPrefix, Nil);
            Ok(List.sortBy(StoredFile.path, collected))
        } catch {
            case ex: Exception =>
                let rawMsg = ex.getMessage();
                Err((StorageErrorKind.IoError, if (Object.isNull(rawMsg)) "Failed to list files" else rawMsg))
        }

    def walkLocal(root: Path, dir: JFile, relDir: String, cleanPrefix: String, acc: List[StoredFile]): List[StoredFile] \ IO = {
        let children: Array[JFile, IO] = dir.listFiles();
        if (Object.isNull(children))
            acc
        else {
            let len = Array.length(children);
            def loop(i: Int32, curAcc: List[StoredFile]): List[StoredFile] \ IO = {
                if (i >= len)
                    curAcc
                else {
                    let child = Array.get(i, children);
                    let childName = child.getName();
                    let relPath = if (String.isEmpty(relDir)) childName else "${relDir}/${childName}";
                    let nextAcc = if (child.isDirectory()) {
                        walkLocal(root, child, relPath, cleanPrefix, curAcc)
                    } else if (child.isFile() and matchesPrefix(cleanPrefix, relPath)) {
                        let linkOpts: Array[LinkOption, IO] = Array#{} @ Static;
                        let real = child.toPath().toRealPath(linkOpts);
                        if (real.startsWith(root)) {
                            let info = StoredFile.make(
                                relPath,
                                child.length(),
                                Mime.fromPath(relPath),
                                child.lastModified()
                            );
                            info :: curAcc
                        } else {
                            curAcc
                        }
                    } else {
                        curAcc
                    };
                    loop(i + 1, nextAcc)
                }
            };
            loop(0, acc)
        }
    }

}
