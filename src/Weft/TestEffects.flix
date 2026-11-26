pub mod Weft.TestEffects {
    use Logger.Severity
    use Time.Clock
    use Time.TimeUnit

    ///
    /// Pure handler for Flix's `Logger` effect that discards all log messages.
    ///
    pub def runSilentLogger(f: Unit -> a \ ef): a \ (ef - Logger) =
        run {
            f()
        } with handler Logger {
            def log(_, _, k) = k()
        }

    ///
    /// Pure handler for Flix's `Logger` effect that captures every `(Severity, String)`
    /// log entry in order and returns `(result, logs)`.
    ///
    pub def runCollectingLogger(f: Unit -> a \ ef): (a, List[(Severity, String)]) \ (ef - Logger) =
        region rc {
            let logs: Ref[List[(Severity, String)], rc] = Ref.fresh(rc, Nil);
            let result = run {
                f()
            } with handler Logger {
                def log(sev, msg, k) = {
                    Ref.transform(xs -> (sev, RichString.toString(msg)) :: xs, logs);
                    k()
                }
            };
            (result, List.reverse(Ref.get(logs)))
        }

    ///
    /// Pure handler for Flix's `Clock` effect returning a constant epoch timestamp (in ms).
    ///
    pub def runFixedClock(millis: Int64, f: Unit -> a \ ef): a \ (ef - Clock) =
        run {
            f()
        } with handler Clock {
            def currentTime(unit, k) = k(convertFromMillis(millis, unit))
        }

    ///
    /// Pure handler for Flix's `Clock` effect that starts at `startMillis` and advances
    /// by `stepMillis` on every `Clock.currentTime` call — making duration assertions
    /// (like `X-Response-Time` or request logs) 100% deterministic!
    ///
    pub def runSteppingClock(startMillis: Int64, stepMillis: Int64, f: Unit -> a \ ef): a \ (ef - Clock) =
        region rc {
            let current: Ref[Int64, rc] = Ref.fresh(rc, startMillis);
            run {
                f()
            } with handler Clock {
                def currentTime(unit, k) = {
                    let now = Ref.get(current);
                    Ref.put(now + stepMillis, current);
                    k(convertFromMillis(now, unit))
                }
            }
        }

    ///
    /// Pure handler for Flix's `Clock` effect backed by a mutable region `Ref[Int64, r]`
    /// (in epoch milliseconds), allowing tests to advance time arbitrarily via `Ref.put`!
    ///
    pub def runManualClock(nowMsRef: Ref[Int64, r], f: Unit -> a \ ef): a \ (ef - Clock) + r =
        run {
            f()
        } with handler Clock {
            def currentTime(unit, k) = k(convertFromMillis(Ref.get(nowMsRef), unit))
        }

    def convertFromMillis(ms: Int64, unit: TimeUnit): Int64 = match unit {
        case TimeUnit.Nanoseconds  => ms * 1000000i64
        case TimeUnit.Microseconds => ms * 1000i64
        case TimeUnit.Milliseconds => ms
        case TimeUnit.Seconds      => ms / 1000i64
        case TimeUnit.Minutes      => ms / 60000i64
        case TimeUnit.Hours        => ms / 3600000i64
        case TimeUnit.Days         => ms / 86400000i64
    }

}
