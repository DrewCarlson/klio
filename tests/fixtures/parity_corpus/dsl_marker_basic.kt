@DslMarker
annotation class HtmlTagMarker

@HtmlTagMarker
class Html {
    val children = mutableListOf<String>()
    fun a(label: String) { children.add("<a>$label</a>") }
    fun render(): String = children.joinToString("")
}

@HtmlTagMarker
class Body {
    val children = mutableListOf<String>()
    fun p(text: String) { children.add("<p>$text</p>") }
    fun render(): String = children.joinToString("")
}

fun main() {
    val html = Html().apply {
        a("home")
        a("about")
    }
    val body = Body().apply {
        p("hello")
        p("world")
    }
    println(html.render())
    println(body.render())
}
