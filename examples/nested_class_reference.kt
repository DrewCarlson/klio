// A private nested class is visible throughout its declaring class's body,
// including inside lambdas nested in its members. Constructing it, referring
// to its members with `::`, and naming it as a type all reach the same
// declaration wherever they appear.
//
// Run with: klio run examples/nested_class_reference.kt

class Registry {
    private class Box(val i: Int) {
        fun doubled(): Int = i * 2
    }

    private val boxes = listOf(Box(1), Box(2), Box(3))

    fun sumDirect(): Int = boxes.map(Box::i).sum()

    fun sumInLambda(): Int {
        var total = 0
        run { total = boxes.map(Box::i).sum() }
        return total
    }

    fun sumMethodRefInLambda(): Int {
        var total = 0
        run { total = boxes.map(Box::doubled).sum() }
        return total
    }

    fun sumNestedLambdas(): Int =
        boxes.map { it }.let { xs -> xs.map(Box::i).sum() }

    fun buildInLambda(): Int {
        var total = 0
        run { total = Box(7).i }
        return total
    }

    fun namedAsType(): Int {
        var total = 0
        run {
            val one: Box = Box(9)
            total = one.i
        }
        return total
    }
}

fun main() {
    val r = Registry()
    println("direct    = " + r.sumDirect())
    println("lambda    = " + r.sumInLambda())
    println("methodref = " + r.sumMethodRefInLambda())
    println("nested    = " + r.sumNestedLambdas())
    println("build     = " + r.buildInLambda())
    println("astype    = " + r.namedAsType())
}
