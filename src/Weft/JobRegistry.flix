pub mod Weft.JobRegistry {
    use Weft.JobHandler
    use Weft.JobRegistry

    ///
    /// Effect-polymorphic registry mapping job `kind` strings to handlers.
    ///
    pub enum JobRegistry[ef: Eff] {
        case JobRegistry(Map[String, JobHandler[ef]])
    }

    ///
    /// Returns an empty pure `JobRegistry[{}]`.
    ///
    pub def empty(): JobRegistry[{}] = JobRegistry.JobRegistry(Map.empty())

    ///
    /// Registers a handler for `kind`, widening the registry's effect row to `ef1 + ef2`.
    ///
    pub def register(kind: String, h: JobHandler[ef1], reg: JobRegistry[ef2]): JobRegistry[ef1 + ef2] =
        let JobRegistry.JobRegistry(m) = reg;
        let widenedMap: Map[String, JobHandler[ef1 + ef2]] =
            Map.map(existing -> j -> checked_ecast(existing(j)), m);
        let widenedHandler: JobHandler[ef1 + ef2] = j -> checked_ecast(h(j));
        JobRegistry.JobRegistry(Map.insert(kind, widenedHandler, widenedMap))

    ///
    /// Looks up a handler by job `kind`.
    ///
    pub def lookup(kind: String, reg: JobRegistry[ef]): Option[JobHandler[ef]] =
        let JobRegistry.JobRegistry(m) = reg;
        Map.get(kind, m)

    ///
    /// Lists all registered job kinds.
    ///
    pub def kinds(reg: JobRegistry[ef]): List[String] =
        let JobRegistry.JobRegistry(m) = reg;
        Map.keysOf(m) |> Set.toList

}
