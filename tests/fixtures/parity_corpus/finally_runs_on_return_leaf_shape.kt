// A tiny finally-carrying body must not be served framelessly: the
// finally runs on the return path, and a return inside the finally
// replaces the pending one.
fun a(): Int {
    try { return 1 } finally { println("fin-a") }
}
fun b(): Int {
    try { return 1 } finally { println("fin-b"); return 2 }
}
fun main() {
    println(a())
    println(b())
}
