class Logging(var v: Int) {
    operator fun getValue(thisRef: Any?, prop: Any?): Int = v
    operator fun setValue(thisRef: Any?, prop: Any?, value: Int) {
        println("set = $value")
        v = value
    }
}

var n: Int by Logging(0)

fun main() {
    println(n)
    n = 5
    println(n)
    n = 9
    println(n)
}
