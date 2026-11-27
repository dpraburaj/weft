pub mod Weft.ScheduledTask {
    use Weft.Schedule
    use Weft.ScheduledTask

    ///
    /// A named recurring task paired with its `Schedule` and effect-polymorphic action.
    ///
    pub enum ScheduledTask[ef: Eff] {
        case ScheduledTask({
            name     = String,
            schedule = Schedule,
            action   = Unit -> Unit \ ef
        })
    }

    pub def make(name: String, schedule: Schedule, action: Unit -> Unit \ ef): ScheduledTask[ef] =
        ScheduledTask.ScheduledTask({
            name     = name,
            schedule = schedule,
            action   = action
        })

    pub def name(t: ScheduledTask[ef]): String          = let ScheduledTask.ScheduledTask(r) = t; r#name
    pub def schedule(t: ScheduledTask[ef]): Schedule    = let ScheduledTask.ScheduledTask(r) = t; r#schedule
    pub def action(t: ScheduledTask[ef]): Unit -> Unit \ ef = let ScheduledTask.ScheduledTask(r) = t; r#action

}
