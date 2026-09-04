// Run with: klio run --feature io.ktor/io examples/channel_segment_namesake.kt
// A ktor ByteChannel pumps data through kotlinx.coroutines' upstream
// BufferedChannel, whose ChannelSegment extends the internal
// kotlinx.coroutines.internal.Segment while kotlinx.io ships a PUBLIC
// class of the same simple name. The internal classifier is package-
// mangled in the combined image; supertype and type references that
// reach it through an import of its declaring package must follow the
// mangle instead of binding the public namesake.
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import io.ktor.utils.io.*

fun main() {
    runTest {
        val ch = ByteChannel()
        val writer = launch {
            repeat(300) { ch.writeInt(it) }
            ch.flushAndClose()
        }
        var sum = 0
        repeat(300) { sum += ch.readInt() }
        writer.join()
        println("sum = " + sum)
    }
}
