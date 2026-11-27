pub mod Weft.Schedule {
    use Weft.Schedule

    import java.time.Instant
    import java.time.ZoneOffset

    ///
    /// Recurring task schedule specification — either a fixed millisecond interval
    /// or a standard 5-field UTC cron expression (`minute hour dayOfMonth month dayOfWeek`).
    ///
    pub enum Schedule {
        case EveryMs(Int64)
        case Cron({
            expr       = String,
            minutes    = Set[Int32],
            hours      = Set[Int32],
            daysOfMonth = Set[Int32],
            months     = Set[Int32],
            daysOfWeek = Set[Int32]
        })
    }

    instance Eq[Schedule] {
        pub def eq(a: Schedule, b: Schedule): Bool = match (a, b) {
            case (Schedule.EveryMs(x), Schedule.EveryMs(y)) => x == y
            case (Schedule.Cron(x), Schedule.Cron(y)) =>
                x#expr == y#expr and
                x#minutes == y#minutes and
                x#hours == y#hours and
                x#daysOfMonth == y#daysOfMonth and
                x#months == y#months and
                x#daysOfWeek == y#daysOfWeek
            case _ => false
        }
    }

    instance ToString[Schedule] {
        pub def toString(s: Schedule): String = match s {
            case Schedule.EveryMs(ms) => "every ${ms}ms"
            case Schedule.Cron(c)     => "cron(${c#expr})"
        }
    }

    // --- Interval Constructors ---

    pub def everyMs(ms: Int64): Schedule =
        Schedule.EveryMs(Int64.max(1i64, ms))

    pub def everySeconds(secs: Int64): Schedule =
        everyMs(Int64.max(1i64, secs) * 1000i64)

    pub def everyMinute(): Schedule =
        everyMs(60000i64)

    pub def everyMinutes(mins: Int32): Schedule =
        everyMs(Int32.toInt64(Int32.max(1, mins)) * 60000i64)

    pub def everyHours(hours: Int32): Schedule =
        everyMs(Int32.toInt64(Int32.max(1, hours)) * 3600000i64)

    // --- Calendar / Cron Constructors (UTC) ---

    pub def hourly(): Schedule =
        hourlyAt(0)

    def clampInt(lo: Int32, hi: Int32, x: Int32): Int32 =
        Int32.max(lo, Int32.min(hi, x))

    pub def hourlyAt(minute: Int32): Schedule = {
        let m = clampInt(0, 59, minute);
        Schedule.Cron({
            expr        = "${m} * * * *",
            minutes     = Set.singleton(m),
            hours       = fullRange(0, 23),
            daysOfMonth = fullRange(1, 31),
            months      = fullRange(1, 12),
            daysOfWeek  = fullRange(0, 6)
        })
    }

    pub def daily(): Schedule =
        dailyAt(0, 0)

    pub def dailyAt(hour: Int32, minute: Int32): Schedule = {
        let h = clampInt(0, 23, hour);
        let m = clampInt(0, 59, minute);
        Schedule.Cron({
            expr        = "${m} ${h} * * *",
            minutes     = Set.singleton(m),
            hours       = Set.singleton(h),
            daysOfMonth = fullRange(1, 31),
            months      = fullRange(1, 12),
            daysOfWeek  = fullRange(0, 6)
        })
    }

    ///
    /// Runs weekly on `dayOfWeek` (`0` = Sunday .. `6` = Saturday) at `hour:minute` UTC.
    ///
    pub def weeklyOn(dayOfWeek: Int32, hour: Int32, minute: Int32): Schedule = {
        let dow = clampInt(0, 6, dayOfWeek);
        let h = clampInt(0, 23, hour);
        let m = clampInt(0, 59, minute);
        Schedule.Cron({
            expr        = "${m} ${h} * * ${dow}",
            minutes     = Set.singleton(m),
            hours       = Set.singleton(h),
            daysOfMonth = fullRange(1, 31),
            months      = fullRange(1, 12),
            daysOfWeek  = Set.singleton(dow)
        })
    }

    ///
    /// Parses a standard 5-field UTC cron expression:
    /// `<minute 0-59> <hour 0-23> <day-of-month 1-31> <month 1-12> <day-of-week 0-6 (0=Sun, 7=Sun)>`.
    ///
    /// Supports `*`, `*/step`, single values (`5`), ranges (`1-5`, `1-5/2`), and comma-separated lists (`0,15,30,45`).
    ///
    pub def cron(expr: String): Result[String, Schedule] = {
        let parts = String.words(String.trim(expr));
        match parts {
            case minStr :: hrStr :: domStr :: monStr :: dowStr :: Nil =>
                forM (
                    mins <- parseField("minute", 0, 59, minStr);
                    hrs  <- parseField("hour", 0, 23, hrStr);
                    doms <- parseField("day-of-month", 1, 31, domStr);
                    mons <- parseField("month", 1, 12, monStr);
                    rawDows <- parseField("day-of-week", 0, 7, dowStr)
                ) yield {
                    // Normalize cron Sunday=7 -> 0
                    let dows = Set.map(d -> if (d == 7) 0 else d, rawDows);
                    Schedule.Cron({
                        expr        = String.intercalate(" ", parts),
                        minutes     = mins,
                        hours       = hrs,
                        daysOfMonth = doms,
                        months      = mons,
                        daysOfWeek  = dows
                    })
                }
            case _ =>
                Err("Cron expression must have exactly 5 whitespace-separated fields: '${expr}'")
        }
    }

    // --- Pure Evaluation ---

    ///
    /// Returns `true` if `schedule` is due to run at `nowMs`, given the optional timestamp
    /// `lastRunAtMs` of its most recent execution.
    ///
    /// - `EveryMs(interval)`: due on the first tick (`None`) or once `nowMs - last >= interval`.
    /// - `Cron(...)`: due when the current UTC minute matches all 5 cron fields AND the task
    ///   has not already executed during this UTC minute bucket (`nowMs / 60000`).
    ///
    pub def isDue(schedule: Schedule, lastRunAtMs: Option[Int64], nowMs: Int64): Bool =
        match schedule {
            case Schedule.EveryMs(intervalMs) =>
                match lastRunAtMs {
                    case None         => true
                    case Some(lastMs) => (nowMs - lastMs) >= intervalMs
                }
            case Schedule.Cron(c) =>
                let currentBucket = nowMs / 60000i64;
                let alreadyRanThisMinute = match lastRunAtMs {
                    case None         => false
                    case Some(lastMs) => (lastMs / 60000i64) >= currentBucket
                };
                if (alreadyRanThisMinute)
                    false
                else
                    matchesCronUtc(c, nowMs)
        }

    def matchesCronUtc(
        c: {
            expr        = String,
            minutes     = Set[Int32],
            hours       = Set[Int32],
            daysOfMonth = Set[Int32],
            months      = Set[Int32],
            daysOfWeek  = Set[Int32]
        },
        nowMs: Int64
    ): Bool = {
        let (minute, hour, dom, month, dow) = utcParts(nowMs);
        Set.memberOf(minute, c#minutes) and
        Set.memberOf(hour, c#hours) and
        Set.memberOf(dom, c#daysOfMonth) and
        Set.memberOf(month, c#months) and
        Set.memberOf(dow, c#daysOfWeek)
    }

    ///
    /// Pure value conversion from epoch millis to UTC `(minute, hour, dayOfMonth, month, dayOfWeek0Sun)`.
    ///
    def utcParts(epochMs: Int64): (Int32, Int32, Int32, Int32, Int32) =
        unsafe IO {
            let dt = Instant.ofEpochMilli(epochMs).atOffset(ZoneOffset.UTC);
            let javaDow = dt.getDayOfWeek().getValue(); // 1=Mon..7=Sun
            let cronDow = Int32.modulo(javaDow, 7);     // 0=Sun, 1=Mon..6=Sat
            (dt.getMinute(), dt.getHour(), dt.getDayOfMonth(), dt.getMonthValue(), cronDow)
        }

    // --- Cron Field Parser ---

    def fullRange(lo: Int32, hi: Int32): Set[Int32] =
        List.range(lo, hi + 1) |> List.toSet

    def parseField(fieldName: String, minVal: Int32, maxVal: Int32, raw: String): Result[String, Set[Int32]] = {
        let items = String.splitOn({substr = ","}, raw);
        def loop(rem: List[String], acc: Set[Int32]): Result[String, Set[Int32]] = match rem {
            case Nil =>
                if (Set.isEmpty(acc)) Err("Empty cron ${fieldName} field") else Ok(acc)
            case item :: rest =>
                match parseItem(fieldName, minVal, maxVal, String.trim(item)) {
                    case Err(e)  => Err(e)
                    case Ok(set) => loop(rest, Set.union(acc, set))
                }
        };
        loop(items, Set.empty())
    }

    def parseItem(fieldName: String, minVal: Int32, maxVal: Int32, item: String): Result[String, Set[Int32]] = {
        let slashParts = String.splitOn({substr = "/"}, item);
        match slashParts {
            case rangePart :: Nil =>
                parseRange(fieldName, minVal, maxVal, rangePart, 1)
            case rangePart :: stepStr :: Nil =>
                match Int32.fromString(stepStr) {
                    case Some(step) if step > 0 => parseRange(fieldName, minVal, maxVal, rangePart, step)
                    case _ => Err("Invalid step '${stepStr}' in cron ${fieldName} field")
                }
            case _ =>
                Err("Invalid cron ${fieldName} item '${item}'")
        }
    }

    def parseRange(fieldName: String, minVal: Int32, maxVal: Int32, part: String, step: Int32): Result[String, Set[Int32]] =
        if (part == "*")
            Ok(steppedRange(minVal, maxVal, step))
        else {
            let dashParts = String.splitOn({substr = "-"}, part);
            match dashParts {
                case singleStr :: Nil =>
                    match Int32.fromString(singleStr) {
                        case Some(v) if v >= minVal and v <= maxVal =>
                            if (step == 1) Ok(Set.singleton(v))
                            else Ok(steppedRange(v, maxVal, step))
                        case _ =>
                            Err("Value '${singleStr}' out of range [${minVal}..${maxVal}] in cron ${fieldName} field")
                    }
                case loStr :: hiStr :: Nil =>
                    match (Int32.fromString(loStr), Int32.fromString(hiStr)) {
                        case (Some(lo), Some(hi)) if lo >= minVal and hi <= maxVal and lo <= hi =>
                            Ok(steppedRange(lo, hi, step))
                        case _ =>
                            Err("Range '${part}' out of bounds [${minVal}..${maxVal}] in cron ${fieldName} field")
                    }
                case _ =>
                    Err("Invalid range '${part}' in cron ${fieldName} field")
            }
        }

    def steppedRange(lo: Int32, hi: Int32, step: Int32): Set[Int32] = {
        def loop(cur: Int32, acc: Set[Int32]): Set[Int32] =
            if (cur > hi) acc
            else loop(cur + step, Set.insert(cur, acc));
        loop(lo, Set.empty())
    }

}
