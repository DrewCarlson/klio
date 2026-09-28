// A class's companion initializes at the class's first construction and
// never again, however many instances follow: constructions that only store
// their parameters, of the class itself and of subclasses passing their
// parameters on to it (reordered, repeated, through several levels, or to
// an empty superclass constructor). A companion whose initializer throws
// fails the first construction and every later one, and a companion that
// constructs its own class while it initializes sees that instance built.

val log = StringBuilder()

class Counted(val id: Int) {
    companion object {
        var made = 0
        init {
            made++
            log.append("Counted.Companion ")
        }
    }
}

class Broken(val id: Int) {
    companion object {
        val bad: Int = error("companion failed")
    }
}

class SelfMaking(val id: Int) {
    companion object {
        val first = SelfMaking(-1)
        init {
            log.append("SelfMaking.Companion(${first.id}) ")
        }
    }
}

open class Base(val a: Int, val b: Int) {
    companion object {
        init {
            log.append("Base.Companion ")
        }
    }
}

open class Mid(x: Int, y: Int, val c: Int) : Base(y, x)

class Bottom(p: Int, q: Int, val d: String) : Mid(p, p, q) {
    companion object {
        init {
            log.append("Bottom.Companion ")
        }
    }
}

abstract class Empty

class OnEmpty(val v: String) : Empty()

fun main() {
    log.append("start ")
    var sum = 0
    for (i in 0 until 1000) sum += Counted(i).id
    println("$log| sum $sum made ${Counted.made}")

    log.setLength(0)
    for (i in 0 until 3) {
        try {
            Broken(i)
            println("constructed")
        } catch (e: Throwable) {
            println("${e::class.simpleName}: ${e.message ?: e.cause?.message}")
        }
    }

    log.setLength(0)
    val made = (1..3).map { SelfMaking(it).id }
    println("$log| $made ${SelfMaking.first.id}")

    log.setLength(0)
    log.append("before ")
    val mids = (1..3).map { Mid(it, it * 10, it * 100) }
    log.append("mids ")
    val bottoms = (1..3).map { Bottom(it, it + 1, "b$it") }
    println(log.toString().trimEnd())
    println(mids.map { "${it.a}/${it.b}/${it.c}" })
    println(bottoms.map { "${it.a}/${it.b}/${it.c}/${it.d}" })
    var total = 0L
    for (i in 0 until 2000) {
        val bt = Bottom(i, -i, "x")
        total += bt.a + bt.b * 3 + bt.c * 7
    }
    println(total)

    val empties = (1..3).map { OnEmpty("e$it") }
    println(empties.map { it.v } + (empties[0] is Empty))
}
