// A use-site-targeted annotation on an extension-receiver property
// (mirrors stdlib Lateinit.kt's `val @receiver:... KProperty0<*>.isInitialized`).
annotation class Marker
val @receiver:Marker String.firstCharCode: Int
    get() = this[0].code
fun main() {
    println("hello".firstCharCode)
    println("Zebra".firstCharCode)
}
