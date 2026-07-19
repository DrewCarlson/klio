// A `var` captured and mutated by a local `fun` that is declared INSIDE a
// lambda must box (Kotlin `Ref` semantics): the write from the local function
// has to be visible at the decl site and across the function's recursive
// calls. The reference scan has to descend into a nested local function's
// body, or the enclosing lambda never marks the var boxed and the increment
// lands on an unboxed capture copy.

fun main() {
    var counter = 0
    val recorded = mutableListOf<Int>()
    run {
        fun emit(depth: Int) {
            recorded.add(counter)
            counter++
            if (depth > 0) {
                emit(depth - 1)
                emit(depth - 1)
            }
        }
        emit(2)
    }
    println("recorded=$recorded")
    println("counter=$counter")
}
