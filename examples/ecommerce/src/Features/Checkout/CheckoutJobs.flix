pub mod Features.Checkout.CheckoutJobs {
    use weft::Weft.Job
    use weft::Weft.JobError
    use weft::Weft.JobRegistry
    use weft::Weft.Json
    use weft::Weft.Mailer
    use weft::Weft.MailError

    ///
    /// Registers the Checkout slice's background job handlers (`order.confirmation_email`).
    ///
    pub def register(reg: JobRegistry[ef]): JobRegistry[ef + {Mailer, JobError}] =
        reg |> JobRegistry.register("order.confirmation_email", handleOrderConfirmation)

    def handleOrderConfirmation(job: Job): Unit \ {Mailer, JobError} = {
        let p = Job.payload(job);
        let to = getStrField("email", p);
        let orderNum = getStrField("orderNumber", p);
        let name = getStrField("customerName", p);
        let total = getStrField("totalDisplay", p);
        if (String.isEmpty(to) or String.isEmpty(orderNum))
            JobError.fail("Invalid order.confirmation_email payload")
        else
            MailError.runToJobError(() -> {
                let email = Shared.Mailer.orderConfirmationEmail(to, name, orderNum, total);
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
