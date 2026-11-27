pub mod Features.Admin.AdminJobs {
    use weft::Weft.Job
    use weft::Weft.JobError
    use weft::Weft.JobRegistry
    use weft::Weft.Json
    use weft::Weft.Mailer
    use weft::Weft.MailError

    ///
    /// Registers the Admin slice's background job handlers (`order.status_email`).
    ///
    pub def register(reg: JobRegistry[ef]): JobRegistry[ef + {Mailer, JobError}] =
        reg |> JobRegistry.register("order.status_email", handleOrderStatusUpdate)

    def handleOrderStatusUpdate(job: Job): Unit \ {Mailer, JobError} = {
        let p = Job.payload(job);
        let to = getStrField("email", p);
        let orderNum = getStrField("orderNumber", p);
        let status = getStrField("status", p);
        let name = getStrField("customerName", p);
        if (String.isEmpty(to) or String.isEmpty(orderNum))
            JobError.fail("Invalid order.status_email payload")
        else
            MailError.runToJobError(() -> {
                let email = Shared.Mailer.orderStatusEmail(to, name, orderNum, status);
                let _ = Mailer.send(email);
                ()
            })
    }

    def getStrField(k: String, j: Json): String =
        match Json.getField(k, j) {
            case Some(Json.JString(s)) => s
            case _                     => ""
        }

}
