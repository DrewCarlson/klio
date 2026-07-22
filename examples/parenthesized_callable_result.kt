class CallableResult {
    operator fun invoke(block: () -> Int): Int = block()
}

fun callableResult(): CallableResult = CallableResult()

fun main() {
    val result = (callableResult()) { 42 }
    println("result=$result")
}
