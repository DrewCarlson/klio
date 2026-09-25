// Array element stores published across threads while collections run. A
// writer fills a large shared array, already tenured, with fresh boxes and
// publishes it three ways: through a volatile flag, through a monitor, and by
// thread start and join. The small collection threshold runs many minor
// collections during each fill, so a box only the array's store barrier
// remembers must stay alive, and the reader must see every box whole.
//>env KLIO_GC_THRESHOLD_KB=128
//> volatile 20000 checksum 199990000
//> monitor 20000 checksum 199990000
//> join 20000 checksum 199990000
import kotlin.concurrent.Volatile
import kotlin.concurrent.thread

class Box(val v: Int, val tag: String)

class Flag {
    @Volatile
    var ready = false
}

const val SIZE = 20000

fun tenured(): Array<Box?> {
    val arr = arrayOfNulls<Box>(SIZE)
    // Survive collections first, so the stores below land in a tenured array.
    repeat(40) { Array(2000) { i -> Box(i, "x") } }
    return arr
}

fun fill(arr: Array<Box?>) {
    for (i in 0 until SIZE) {
        // 7919 is prime to SIZE, so the stores scatter over every index.
        arr[(i * 7919) % SIZE] = Box(i, "b$i")
    }
}

fun check(arr: Array<Box?>): String {
    var n = 0
    var sum = 0L
    for (b in arr) {
        if (b != null && b.tag == "b${b.v}") {
            n++
            sum += b.v
        }
    }
    return "$n checksum $sum"
}

fun main() {
    run {
        val arr = tenured()
        val flag = Flag()
        val t = thread {
            fill(arr)
            flag.ready = true
        }
        while (!flag.ready) {
            Box(0, "spin")
        }
        println("volatile ${check(arr)}")
        t.join()
    }
    run {
        val arr = tenured()
        val lock = Any()
        var done = false
        val t = thread {
            synchronized(lock) {
                fill(arr)
                done = true
            }
        }
        while (!synchronized(lock) { done }) {
            Box(0, "spin")
        }
        println("monitor ${check(arr)}")
        t.join()
    }
    run {
        val arr = tenured()
        val t = thread { fill(arr) }
        t.join()
        println("join ${check(arr)}")
    }
}
