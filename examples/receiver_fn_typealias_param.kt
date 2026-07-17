// A parameter whose type is an ALIASED receiver function type binds the
// enclosing receiver when invoked bare, exactly like the spelled-out form:
// `typealias Workflow = WScope.() -> Unit` erases nothing.

interface WScope {
    val iteration: Int
}

private class WImpl : WScope {
    override var iteration = 41
}

typealias Workflow = WScope.() -> Unit

private fun workflowOf(block: Workflow): Workflow = block

private fun normalW(done: Workflow = {}): Workflow = workflowOf {
    done()
}

fun main() {
    var received = 0
    val wf = normalW { received = iteration + 1 }
    WImpl().wf()
    println(received)
}
