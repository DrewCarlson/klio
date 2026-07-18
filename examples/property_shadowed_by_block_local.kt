// A `var` declared inside a branch block shadows a same-named class
// property only within that block. Once the block ends, a bare-name
// write must reach the property (through its setter/field), not the
// dead local's storage — and reads and writes must agree on the target.

class Writer {
    var currentSlot: Int = 5
    var count: Int = 1

    fun startGroup(inserting: Boolean): Int {
        val end =
            if (inserting) {
                var currentSlot = currentSlot
                currentSlot += 100
                currentSlot
            } else {
                currentSlot = 77
                currentSlot + 1
            }
        return end
    }

    fun touch(flag: Boolean): Int {
        if (flag) {
            var count = 900
            count++
        } else {
            count = 42
        }
        return count
    }
}

fun main() {
    val w = Writer()
    println(w.startGroup(false))
    println(w.currentSlot)
    println(w.startGroup(true))
    println(w.currentSlot)
    println(w.touch(false))
    println(w.touch(true))
    println(w.count)
}
