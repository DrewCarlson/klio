// A `@Volatile` property orders every access to it as the JVM orders a
// volatile field's: a thread that sees the flag set sees every store made
// before it was set. A property that is not `@Volatile` is read and written
// plainly, and still never torn: a racing reader sees one whole stored value,
// and an object published through it is seen fully made.
import kotlin.concurrent.Volatile
import kotlin.concurrent.thread

class Mailbox {
    var payload: IntArray? = null
    var note = ""
    @Volatile var ready = false
}

class Point(val x: Int, val y: Int)

class Holder {
    var point: Point? = null
    var count = 0L
}

fun main() {
    val box = Mailbox()
    val reader = thread {
        while (!box.ready) {}
        println("reader saw " + box.payload!!.sum() + " " + box.note)
    }
    box.payload = IntArray(100) { it }
    box.note = "and the note"
    box.ready = true
    reader.join()

    // Stores a thread made before it ended are seen by the thread that joins it.
    val holder = Holder()
    thread {
        for (i in 0 until 1000) {
            holder.point = Point(i, i * 2)
            holder.count++
        }
    }.join()
    println("last point " + holder.point!!.x + "," + holder.point!!.y + " after " + holder.count)

    // A reader racing a writer's plain stores sees whole points, each fully made.
    val shared = Holder()
    shared.point = Point(0, 0)
    val writer = thread {
        for (i in 1..200_000) {
            shared.point = Point(i, 2 * i)
            shared.count = i.toLong() * 0x1_0000_0001L
        }
    }
    var bad = 0
    while (writer.isAlive) {
        val p = shared.point!!
        if (p.y != 2 * p.x) bad++
        val c = shared.count
        if ((c ushr 32) != (c and 0xffff_ffffL)) bad++
    }
    writer.join()
    println("last " + shared.point!!.x + ", torn reads " + bad)
}
