// Regex `\p{...}` and `\P{...}` classes as the JVM's java.util.regex resolves
// them: the ASCII POSIX classes, Unicode general categories (one letter, `Is`,
// `gc=`), scripts (`Is`, `sc=`, ISO 15924 aliases), blocks (`In`, `blk=`),
// the `java*` classes and the Unicode binary properties, inside and outside
// brackets, with nested classes, `&&` intersection, whole-class negation and
// IGNORE_CASE. An unknown property is a PatternSyntaxException.

fun check(pattern: String, input: String, options: Set<RegexOption> = emptySet()) {
    val result = Regex(pattern, options).matches(input)
    println("${if (options.isEmpty()) "" else "(i) "}$pattern ~ \"$input\": $result")
}

fun fails(pattern: String) {
    try {
        Regex(pattern)
        println("$pattern compiled")
    } catch (e: IllegalArgumentException) {
        println("$pattern: " + e.message!!.lines().first())
    }
}

fun main() {
    // The group-name finder ktor's regex routes use.
    val finder = Regex("""(^|[^\\])\(\?<(\p{Alpha}\p{Alnum}*)>(.*?[^\\])?\)""")
    println(finder.findAll("""/(?<user>\w+)/(?<login>.+)""").map { it.groupValues[2] }.toList())

    check("""\p{Alpha}+""", "abcXYZ")
    check("""\p{Alpha}""", "é")
    check("""\p{Lower}\p{Upper}\p{Digit}\p{XDigit}""", "aZ7f")
    check("""\p{Punct}\p{Graph}\p{Print}\p{Blank}\p{Space}""", "!~  \n")
    check("""\p{Cntrl}\p{ASCII}""", "\u0001\u007f")
    check("""\p{Lower}""", "A", setOf(RegexOption.IGNORE_CASE))

    check("""\p{L}+""", "héllo")
    check("""\pL\pN""", "ж٣")
    check("""\p{Lu}\p{Ll}\p{Lt}""", "Éaǅ")
    check("""\p{IsLu}\p{gc=Nd}\p{general_category=Sc}""", "Ω7€")
    check("""\PL\P{Lu}""", "1a")
    check("""\PL""", "a")
    check("""\p{Zs}\p{Pd}\p{Sm}\p{Cc}""", "　-+\u0007")
    check("""\p{LC}\p{LD}\p{L1}""", "aZÿ")
    check("""\p{Lu}""", "a")
    check("""\p{Lu}""", "a", setOf(RegexOption.IGNORE_CASE))

    check("""\p{IsGreek}+""", "αβγ")
    check("""\p{IsGreek}""", "a")
    check("""\p{sc=Latin}\p{script=cyrillic}\p{IsLatn}\p{IsHan}""", "aжz字")

    check("""\p{InGreek}\p{InBasicLatin}""", "αa")
    check("""\p{blk=Greek and Coptic}\p{block=GREEK}\p{InGreekandCoptic}""", "ωΩϢ")
    check("""\p{InBasicLatin}""", "é")
    check("""\p{InLatin-1 Supplement}""", "é")

    check("""\p{javaLowerCase}\p{javaUpperCase}\p{javaDigit}""", "ªÉ٣")
    check("""\p{javaWhitespace}\p{javaSpaceChar}""", "\u001f ")
    check("""\p{javaWhitespace}""", " ")
    check("""\p{javaJavaIdentifierStart}\p{javaJavaIdentifierPart}\p{javaMirrored}""", "$1(")
    check("""\p{javaLetterOrDigit}\p{javaDefined}\p{javaAlphabetic}""", "x é")

    check("""\p{IsAlpha}\p{IsAlphabetic}\p{IsLetter}""", "éΩж")
    check("""\p{IsWhite_Space}\p{IsWhiteSpace}\p{IsPunctuation}""", " \u0085¿")
    check("""\p{IsHex_Digit}\p{IsIdeographic}\p{IsJoin_Control}""", "Ｆ字‍")
    check("""\p{IsUppercase}\p{IsTitlecase}\p{IsAssigned}""", "Aǅa")
    check("""\p{IsAssigned}""", "͸")
    check("""\p{IsWord}\p{IsAlnum}\p{IsDigit}\p{IsBlank}\p{IsGraph}\p{IsPrint}""", "_٣٣\t!é")
    check("""\p{IsEmoji}""", "😀")

    check("""[\p{L}\d_]+""", "héllo_42")
    check("""[^\p{L}]""", "é")
    check("""[\P{L}]""", "5")
    check("""[a-z&&[^aeiou]]+""", "xyz")
    check("""[a-z&&[^aeiou]]""", "e")
    check("""[\p{L}&&[^\p{Lu}]]""", "é")
    check("""[\p{L}&&[^\p{Lu}]]""", "É")
    check("""[ab&&bc]""", "b")
    check("""[ab&&bc]""", "a")
    check("""[a[bc]]{3}""", "abc")
    check("""[^a[bc]]""", "c")
    check("""[]a]+""", "]a")
    check("""[a-]+""", "a-")
    check("""[a&b]+""", "a&b")
    check("""[a-c]""", "B", setOf(RegexOption.IGNORE_CASE))
    check("""[^a-c]""", "B", setOf(RegexOption.IGNORE_CASE))

    fails("""\p{Foo}""")
    fails("""a\pQ""")
    fails("""\p{sc=Klingon}""")
    fails("""\p{InNowhere}""")
    fails("""\p{lu}""")
    fails("""\p{}""")
    fails("""[z-a]""")
}
