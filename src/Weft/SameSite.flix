pub mod Weft.SameSite {
    use Weft.SameSite

    ///
    /// Cookie `SameSite` attribute.
    ///
    pub enum SameSite with Eq {
        case Strict
        case Lax
        case None
    }

    instance ToString[SameSite] {
        pub def toString(s: SameSite): String = match s {
            case SameSite.Strict => "Strict"
            case SameSite.Lax    => "Lax"
            case SameSite.None   => "None"
        }
    }
}
