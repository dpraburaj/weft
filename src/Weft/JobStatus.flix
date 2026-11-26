pub mod Weft.JobStatus {
    use Weft.JobStatus

    ///
    /// Lifecycle state of a background job.
    ///
    pub enum JobStatus with Eq, Order {
        case Pending
        case Running
        case Completed
        case Failed
        case Dead
    }

    instance ToString[JobStatus] {
        pub def toString(s: JobStatus): String = match s {
            case JobStatus.Pending   => "pending"
            case JobStatus.Running   => "running"
            case JobStatus.Completed => "completed"
            case JobStatus.Failed    => "failed"
            case JobStatus.Dead      => "dead"
        }
    }

    pub def parse(s: String): Option[JobStatus] = match String.toLowerCase(String.trim(s)) {
        case "pending"   => Some(JobStatus.Pending)
        case "running"   => Some(JobStatus.Running)
        case "completed" => Some(JobStatus.Completed)
        case "failed"    => Some(JobStatus.Failed)
        case "dead"      => Some(JobStatus.Dead)
        case _           => None
    }

}
