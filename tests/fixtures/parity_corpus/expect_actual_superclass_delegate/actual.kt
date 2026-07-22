class ExpectedSinkImpl : ExpectedSink {
    override fun report(value: Int) {
        println("reported $value")
    }
}

actual open class ExpectedBase(
    private val sink: ExpectedSink,
) : ExpectedSink by sink {
    actual constructor() : this(ExpectedSinkImpl())
}
