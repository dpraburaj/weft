pub mod Weft.Email {
    use Weft.Email
    use Weft.Headers
    use Weft.HtmlDoc
    use Weft.Json

    ///
    /// Immutable email message for `Weft.Mailer`.
    ///
    pub enum Email {
        case Email({
            sender   = String,
            to       = List[String],
            cc       = List[String],
            bcc      = List[String],
            replyTo  = Option[String],
            subject  = String,
            textBody = Option[String],
            htmlBody = Option[String],
            headers  = Headers
        })
    }

    instance Eq[Email] {
        pub def eq(a: Email, b: Email): Bool =
            let Email.Email(x) = a;
            let Email.Email(y) = b;
            x#sender == y#sender and
            x#to == y#to and
            x#cc == y#cc and
            x#bcc == y#bcc and
            x#replyTo == y#replyTo and
            x#subject == y#subject and
            x#textBody == y#textBody and
            x#htmlBody == y#htmlBody and
            x#headers == y#headers
    }

    instance ToString[Email] {
        pub def toString(e: Email): String =
            "Email(from=${sender(e)}, to=${String.intercalate(", ", to(e))}, subject=${subject(e)})"
    }

    ///
    /// Creates an `Email` from `sender` to a single recipient `to` with `subject`.
    ///
    pub def make(sender: String, to: String, subject: String): Email =
        Email.Email({
            sender   = sender,
            to       = to :: Nil,
            cc       = Nil,
            bcc      = Nil,
            replyTo  = None,
            subject  = subject,
            textBody = None,
            htmlBody = None,
            headers  = Headers.empty()
        })

    // --- Accessors ---

    pub def sender(e: Email): String            = let Email.Email(r) = e; r#sender
    pub def to(e: Email): List[String]          = let Email.Email(r) = e; r#to
    pub def cc(e: Email): List[String]          = let Email.Email(r) = e; r#cc
    pub def bcc(e: Email): List[String]         = let Email.Email(r) = e; r#bcc
    pub def replyTo(e: Email): Option[String]   = let Email.Email(r) = e; r#replyTo
    pub def subject(e: Email): String           = let Email.Email(r) = e; r#subject
    pub def textBody(e: Email): Option[String]  = let Email.Email(r) = e; r#textBody
    pub def htmlBody(e: Email): Option[String]  = let Email.Email(r) = e; r#htmlBody
    pub def headers(e: Email): Headers          = let Email.Email(r) = e; r#headers

    // --- Builders ---

    pub def withTo(addrs: List[String], e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ to = addrs | r })

    pub def addTo(addr: String, e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ to = List.append(r#to, addr :: Nil) | r })

    pub def withCc(addrs: List[String], e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ cc = addrs | r })

    pub def withBcc(addrs: List[String], e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ bcc = addrs | r })

    pub def withReplyTo(addr: String, e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ replyTo = Some(addr) | r })

    pub def withText(body: String, e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ textBody = Some(body) | r })

    ///
    /// Sets the HTML body directly from a `Weft.Html` rendered `HtmlDoc`.
    ///
    pub def withHtml(doc: HtmlDoc, e: Email): Email =
        withHtmlString(HtmlDoc.toHtmlString(doc), e)

    pub def withHtmlString(rawHtml: String, e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ htmlBody = Some(rawHtml) | r })

    pub def withHeader(name: String, value: String, e: Email): Email =
        let Email.Email(r) = e;
        Email.Email({ headers = Headers.set(name, value, r#headers) | r })

    // --- JSON Serialization (for JobQueue & HTTP Mail APIs) ---

    pub def toJson(e: Email): Json = {
        let base =
            ("from", Json.str(sender(e))) ::
            ("to", Json.arr(List.map(Json.str, to(e)))) ::
            ("subject", Json.str(subject(e))) ::
            Nil;
        let withCcField = if (List.isEmpty(cc(e))) base
            else ("cc", Json.arr(List.map(Json.str, cc(e)))) :: base;
        let withBccField = if (List.isEmpty(bcc(e))) withCcField
            else ("bcc", Json.arr(List.map(Json.str, bcc(e)))) :: withCcField;
        let withReplyField = match replyTo(e) {
            case None    => withBccField
            case Some(v) => ("reply_to", Json.str(v)) :: withBccField
        };
        let withTextField = match textBody(e) {
            case None    => withReplyField
            case Some(v) => ("text", Json.str(v)) :: withReplyField
        };
        let withHtmlField = match htmlBody(e) {
            case None    => withTextField
            case Some(v) => ("html", Json.str(v)) :: withTextField
        };
        let headerPairs = Headers.toList(headers(e));
        let withHeadersField = if (List.isEmpty(headerPairs)) withHtmlField
            else ("headers", Json.obj(List.map(match (k, v) -> (k, Json.str(v)), headerPairs))) :: withHtmlField;
        Json.obj(List.reverse(withHeadersField))
    }

    pub def fromJson(j: Json): Result[String, Email] = {
        let fromOpt = Option.flatMap(Json.asString, Json.getField("from", j));
        let subjectOpt = Option.flatMap(Json.asString, Json.getField("subject", j));
        let toRes = decodeStringList("to", j);
        match (fromOpt, subjectOpt, toRes) {
            case (Some(f), Some(subj), Ok(toList)) if not List.isEmpty(toList) =>
                let ccList = Result.getWithDefault(Nil, decodeOptionalStringList("cc", j));
                let bccList = Result.getWithDefault(Nil, decodeOptionalStringList("bcc", j));
                let replyOpt = Option.flatMap(Json.asString, Json.getField("reply_to", j));
                let textOpt = Option.flatMap(Json.asString, Json.getField("text", j));
                let htmlOpt = Option.flatMap(Json.asString, Json.getField("html", j));
                let hdrs = decodeHeaders(j);
                Ok(Email.Email({
                    sender   = f,
                    to       = toList,
                    cc       = ccList,
                    bcc      = bccList,
                    replyTo  = replyOpt,
                    subject  = subj,
                    textBody = textOpt,
                    htmlBody = htmlOpt,
                    headers  = hdrs
                }))
            case _ =>
                Err("Email JSON requires 'from' (string), non-empty 'to' (string array), and 'subject' (string)")
        }
    }

    def decodeStringList(field: String, j: Json): Result[String, List[String]] =
        match Option.flatMap(Json.asArray, Json.getField(field, j)) {
            case None => Err("Missing array field '${field}'")
            case Some(xs) =>
                def loop(rem: List[Json], acc: List[String]): Result[String, List[String]] = match rem {
                    case Nil => Ok(List.reverse(acc))
                    case x :: rest => match Json.asString(x) {
                        case Some(s) => loop(rest, s :: acc)
                        case None    => Err("Expected string element in '${field}'")
                    }
                };
                loop(xs, Nil)
        }

    def decodeOptionalStringList(field: String, j: Json): Result[String, List[String]] =
        match Json.getField(field, j) {
            case None => Ok(Nil)
            case Some(_) => decodeStringList(field, j)
        }

    def decodeHeaders(j: Json): Headers =
        match Json.getField("headers", j) {
            case Some(Json.JObject(m)) =>
                Map.foldLeftWithKey((acc, k, v) ->
                    match Json.asString(v) {
                        case Some(s) => Headers.set(k, s, acc)
                        case None    => acc
                    }
                , Headers.empty(), m)
            case _ =>
                Headers.empty()
        }

}
