pub mod Shared.Mailer {
    use weft::Weft.Email
    use weft::Weft.Html

    pub def senderAddress(): String = "orders@weftroasters.com"

    ///
    /// Builds a rich HTML + plain-text order confirmation `Weft.Email`.
    ///
    pub def orderConfirmationEmail(
        to: String,
        customerName: String,
        orderNumber: String,
        totalDisplay: String
    ): Email = {
        let html = Html.page("Order ${orderNumber} Confirmed", () ->
            Html.main_(() -> {
                Html.h1Text("Thank you for your order, ${customerName}!");
                Html.pText("Your Weft Roasters order ${orderNumber} totaling ${totalDisplay} is confirmed.");
                Html.pText("We are roasting your beans fresh and will email you when it ships.")
            })
        );
        Email.make(senderAddress(), to, "Order ${orderNumber} Confirmed — Weft Roasters")
            |> Email.withReplyTo("support@weftroasters.com")
            |> Email.withText("Hi ${customerName}, thank you for your order ${orderNumber} totaling ${totalDisplay}. We are roasting your beans fresh!")
            |> Email.withHtml(html)
    }

    ///
    /// Builds a rich HTML + plain-text order fulfillment status update `Weft.Email`.
    ///
    pub def orderStatusEmail(
        to: String,
        customerName: String,
        orderNumber: String,
        status: String
    ): Email = {
        let html = Html.page("Order ${orderNumber} Update", () ->
            Html.main_(() -> {
                Html.h1Text("Order ${orderNumber} is now ${status}");
                Html.pText("Hi ${customerName}, your Weft Roasters order ${orderNumber} status has been updated to: ${status}.")
            })
        );
        Email.make(senderAddress(), to, "Order ${orderNumber} is now ${status}")
            |> Email.withReplyTo("support@weftroasters.com")
            |> Email.withText("Hi ${customerName}, your Weft Roasters order ${orderNumber} status has been updated to: ${status}.")
            |> Email.withHtml(html)
    }

}
