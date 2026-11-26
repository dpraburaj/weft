pub mod Weft.WorkerHandle {
    use Weft.WorkerHandle

    import java.lang.InterruptedException
    import java.lang.Thread
    import java.util.concurrent.atomic.AtomicBoolean

    ///
    /// Handle to a running background virtual-thread worker pool.
    ///
    pub enum WorkerHandle {
        case WorkerHandle(AtomicBoolean, List[Thread])
    }

    ///
    /// Signals all background virtual-thread workers to stop and waits for them to exit.
    ///
    pub def stop(h: WorkerHandle): Unit \ IO =
        let WorkerHandle.WorkerHandle(running, threads) = h;
        running.set(false);
        List.forEach(t -> t.interrupt(), threads);
        List.forEach(t ->
            try {
                t.join(2000i64)
            } catch {
                case _: InterruptedException => ()
            },
            threads
        )

    ///
    /// Returns `true` if the worker pool has not been stopped.
    ///
    pub def isRunning(h: WorkerHandle): Bool \ IO =
        let WorkerHandle.WorkerHandle(running, _) = h;
        running.get()

}
