interface ExpectedSink {
    fun report(value: Int)
}

expect open class ExpectedBase() : ExpectedSink

fun ExpectedSink.failExpected(): Nothing {
    throw IllegalStateException("boom").also {
        report(42)
    }
}

class ExpectedRunner : ExpectedBase() {
    fun run() {
        try {
            failExpected()
        } catch (e: IllegalStateException) {
            println(e.message)
        }
    }
}

fun main() {
    ExpectedBase().report(7)
    ExpectedRunner().run()
}
