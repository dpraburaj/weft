pub mod Shared.Mailer {

    ///
    /// Domain algebraic effect for transactional emails (order confirmations & shipping updates).
    ///
    pub eff Mailer {
        def sendEmail(to: String, subject: String, body: String): Unit
    }

    pub type alias EmailMessage = {
        to      = String,
        subject = String,
        body    = String
    }

    ///
    /// Development/demo handler that logs outbound emails via Flix's `Logger` effect.
    ///
    pub def runWithLogger(f: Unit -> a \ ef): a \ (ef - Mailer) + Logger =
        run {
            f()
        } with handler Mailer {
            def sendEmail(to, subject, body, k) = {
                Logger.info("[Mailer] To: ${to} | Subject: ${subject} | ${body}");
                k()
            }
        }

    ///
    /// Pure test handler that records every sent email in a region `Ref`.
    ///
    pub def runRecording(outRef: Ref[List[EmailMessage], r], f: Unit -> a \ ef): a \ (ef - Mailer) + r =
        run {
            f()
        } with handler Mailer {
            def sendEmail(to, subject, body, k) = {
                let msg: EmailMessage = { to = to, subject = subject, body = body };
                Ref.transform(xs -> List.append(xs, msg :: Nil), outRef);
                k()
            }
        }

}
