// String length/index operations take an ASCII fast path (byte length == UTF-16
// length for ASCII) and fall back to a UTF-16 walk for non-ASCII — same results
// either way. Covers length, indexOf, substring, contains, and char indexing.
fun main() {
    val a = "hello world foo bar"        // ASCII
    val b = "héllo wörld foo ☃ end"      // non-ASCII (accents + snowman)
    println("${a.length} ${a.indexOf("foo")} ${a.substring(6, 11)} ${a.contains("bar")}")
    println("${b.length} ${b.indexOf("foo")} ${b.substring(0, 6)} ${b.contains("☃")}")
    println("${a[4].code} ${b[1].code} ${b.indexOf("☃")}")
}
