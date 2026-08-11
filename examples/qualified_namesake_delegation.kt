// A user function that shares a name with a stdlib function and delegates to
// it by FULL QUALIFICATION must not have the qualified call re-picked back to
// itself at dispatch (the compose-ui `synchronized` actual delegates to
// `kotlin.synchronized` exactly this way and recursed to a stack overflow).
class Lock

fun <R> synchronized(lock: Lock, block: () -> R): R =
    kotlin.synchronized(lock, block)

fun main() {
    val l = Lock()
    println(synchronized(l) { 41 + 1 })
    println(kotlin.synchronized(l) { "direct" })
}
