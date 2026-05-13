// `@DslMarker` scopes implicit receivers so that nested DSL builders only
// expose the innermost receiver's members. Two classes carrying the same
// dsl-marker annotation form one "DSL" — within a nested lambda, the inner
// receiver hides every outer member of the shared marker.

@DslMarker
annotation class HtmlTagMarker

@HtmlTagMarker
class Html {
    val parts = mutableListOf<String>()
    fun a(label: String) { parts.add("<a>$label</a>") }
    fun render(): String = parts.joinToString("")
}

@HtmlTagMarker
class Body {
    val parts = mutableListOf<String>()
    fun p(text: String) { parts.add("<p>$text</p>") }
    fun render(): String = parts.joinToString("")
}

fun main() {
    val page = Html().apply {
        a("home")
        a("about")
    }
    val body = Body().apply {
        p("hello")
        p("world")
    }
    println(page.render())
    println(body.render())
}
