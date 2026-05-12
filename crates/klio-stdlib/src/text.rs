//! `kotlin.text.*`: `String`, `CharSequence`, `StringBuilder`, regex.

use std::cmp::Ordering;

/// Compare two `&str`s the way Kotlin's `String.compareTo` does:
/// lexicographically over UTF-16 code units. For BMP-only strings the result
/// matches a UTF-8 byte comparison, but supplementary characters diverge
/// because a UTF-16 surrogate pair starts with a high surrogate (D800–DBFF),
/// while the same code point's UTF-8 encoding starts with a 4-byte lead
/// (F0–F4) that sorts after every 3-byte lead (E0–EF) used for U+E000–U+FFFF.
///
/// Streams `encode_utf16()` in lockstep — no whole-string `Vec<u16>`.
#[must_use]
pub fn compare_utf16(a: &str, b: &str) -> Ordering {
    let mut ai = a.encode_utf16();
    let mut bi = b.encode_utf16();
    loop {
        match (ai.next(), bi.next()) {
            (Some(x), Some(y)) => match x.cmp(&y) {
                Ordering::Equal => continue,
                non_eq => return non_eq,
            },
            (Some(_), None) => return Ordering::Greater,
            (None, Some(_)) => return Ordering::Less,
            (None, None) => return Ordering::Equal,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering::*;

    #[test]
    fn bmp_strings_match_utf8_order() {
        assert_eq!(compare_utf16("abc", "abd"), Less);
        assert_eq!(compare_utf16("abc", "abc"), Equal);
        assert_eq!(compare_utf16("abd", "abc"), Greater);
        assert_eq!(compare_utf16("", ""), Equal);
        assert_eq!(compare_utf16("", "a"), Less);
        assert_eq!(compare_utf16("a", ""), Greater);
        assert_eq!(compare_utf16("hello", "hello!"), Less);
    }

    /// 😀 (U+1F600) UTF-16 surrogate pair: D83D DE00. D83D < E000 so 😀 sorts
    /// before U+E000 in UTF-16. UTF-8 is F0 9F 98 80 vs EE 80 80, and
    /// F0 > EE, so byte order disagrees.
    #[test]
    fn supplementary_vs_private_use_diverges_from_utf8() {
        let grin = "\u{1F600}";
        let pua = "\u{E000}";
        assert_eq!(compare_utf16(grin, pua), Less);
        assert_eq!(grin.cmp(pua), Greater);
    }

    /// Second supplementary pair: U+1D11E (MUSICAL SYMBOL G CLEF), UTF-16
    /// D834 DD1E. D834 < F8FF so clef < U+F8FF in UTF-16; UTF-8 says the
    /// opposite (F0 > EF).
    #[test]
    fn another_supplementary_divergence() {
        let clef = "\u{1D11E}";
        let high_bmp = "\u{F8FF}";
        assert_eq!(compare_utf16(clef, high_bmp), Less);
        assert_eq!(clef.cmp(high_bmp), Greater);
    }

    #[test]
    fn equal_supplementary_pairs() {
        assert_eq!(compare_utf16("\u{1F600}", "\u{1F600}"), Equal);
    }

    #[test]
    fn shorter_is_less_when_prefix_equal() {
        assert_eq!(compare_utf16("\u{1F600}", "\u{1F600}a"), Less);
        assert_eq!(compare_utf16("\u{1F600}a", "\u{1F600}"), Greater);
    }
}
