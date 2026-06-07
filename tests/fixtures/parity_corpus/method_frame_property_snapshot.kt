open class Counter {
    open var count = 0
    fun bump() { count++ }
}

class Sub : Counter() {
    fun read() {
        super.bump()
        val n = count
        println(n)
    }

    fun bumpMany(times: Int) {
        for (i in 0 until times) {
            super.bump()
        }
        println(count)
    }
}

fun main() {
    val s = Sub()
    s.read()
    s.bumpMany(3)
    println(s.count)
}
