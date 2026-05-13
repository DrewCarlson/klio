@DslMarker
annotation class HtmlTagMarker

@HtmlTagMarker
class Html {
    fun a(label: String): String = "<a>$label</a>"
}

@HtmlTagMarker
class Body {
    fun p(text: String): String = "<p>$text</p>"
}

fun main() {
    Html().apply {
        Body().apply {
            // Inside the inner Body `apply`, the outer Html `a` member is
            // shadowed because both classes share `@HtmlTagMarker`.
            a("oops")
        }
    }
}
