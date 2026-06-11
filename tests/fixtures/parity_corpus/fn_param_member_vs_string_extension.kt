class UrlBuilder(var s: String) {
    fun takeFrom(v: String) { s = v }
}

class Builder {
    var url: UrlBuilder = UrlBuilder("")
    fun url(block: UrlBuilder.(UrlBuilder) -> Unit) { url.block(url) }
}

fun Builder.url(urlString: String) {
    url.takeFrom(urlString)
}

class Client(val name: String)

inline fun Client.fetch(block: Builder.() -> Unit): String {
    val b = Builder()
    b.block()
    return b.url.s
}

inline fun Client.fetch(urlString: String, block: Builder.() -> Unit = {}): String = fetch {
    url(urlString)
    block()
}

fun main() {
    val c = Client("c1")
    println(c.fetch("http://a/"))
    println(c.fetch { url("http://b/") })
}
