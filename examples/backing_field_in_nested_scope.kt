// `field` is an ordinary binding inside a property accessor, so a nested scope
// captures it like any other. The accessor-body rewrite walked only the flat
// expression forms, so a `field` inside a lambda / loop / when / try survived as
// a bare name and read an unresolved global. kotlinx-coroutines-test guards its
// scheduler clock exactly this way: `get() = synchronized(lock) { field }`.

class Box {
    var direct: Int = 1
        get() = field + 10
        set(value) { field = value * 2 }

    var viaLambda: Int = 7
        get() = run { field }
        set(value) { run { field = value * 3 } }

    var viaWhen: Int = 2
        get() = when {
            field > 100 -> -1
            else -> field * 5
        }

    var viaLoop: Int = 0
        set(value) {
            var acc = 0
            for (i in 1..value) acc += field + i
            field = acc
        }

    var viaTry: Int = 4
        get() = try {
            field
        } catch (e: Throwable) {
            -1
        }
}

fun main() {
    val b = Box()
    println(b.direct)      // 11
    b.direct = 5
    println(b.direct)      // 20
    println(b.viaLambda)   // 7
    b.viaLambda = 4
    println(b.viaLambda)   // 12
    println(b.viaWhen)     // 10
    b.viaLoop = 3
    println(b.viaLoop)     // 0+1 + 0+2 + 0+3 = 6
    println(b.viaTry)      // 4
}
