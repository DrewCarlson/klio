import io.ktor.http.*

fun main() {
    for (u in listOf("http://google.com/", "a123://google.com/", "a.+-://google.com/", "a://google.com/")) {
        val r = try { URLBuilder(u).buildString() } catch (e: Exception) { "ERR: " + (e.cause?.message ?: e.message) }
        println("$u -> $r")
    }
}
