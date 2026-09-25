// benchRecompose: what one recomposer frame costs when the composition
// invalidates itself. The content emits two nodes and writes back the state it
// read, so every frame recomposes it, the shape of the compose runtime's
// throughput-bound tests (derivedStateOfLeak). Frames are driven one at a time
// through a BroadcastFrameClock on an unconfined scope, so each sendFrame runs
// that frame's recomposition before it returns, and the frame count is fixed:
// two runs do the same work.
//
//   klio run tests/bench/recompose.kt
//
// Prints the recomposition count, which is deterministic, then the wall time
// and the time per frame, which are the measurement. Time it for user CPU as
// well: the wall time here includes nothing but the frames.

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.snapshots.Snapshot
import kotlin.time.TimeSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

const val FRAMES = 2000

class Node(val kind: String) {
    var value = 0
    val children = mutableListOf<Node>()
}

class NodeApplier(root: Node) : AbstractApplier<Node>(root) {
    override fun insertTopDown(index: Int, instance: Node) {
        current.children.add(index, instance)
    }

    override fun insertBottomUp(index: Int, instance: Node) {}

    override fun remove(index: Int, count: Int) {
        repeat(count) { current.children.removeAt(index) }
    }

    override fun move(from: Int, to: Int, count: Int) {
        val node = current.children.removeAt(from)
        current.children.add(if (from > to) to else to - count, node)
    }

    override fun onClear() {
        root.children.clear()
    }
}

@Composable
fun Leaf(kind: String, value: Int) {
    ComposeNode<Node, NodeApplier>(
        factory = { Node(kind) },
        update = { set(value) { this.value = it } },
    )
}

val tick = mutableIntStateOf(0)
var recompositions = 0

@Composable
fun Content() {
    recompositions += 1
    val n = tick.intValue
    Leaf("a", n)
    Leaf("b", n + 1)
    // Writing back what this composition read invalidates it for the next frame.
    tick.intValue = n + 1
}

fun main() {
    val clock = BroadcastFrameClock()
    val scope = CoroutineScope(clock + Dispatchers.Unconfined)
    val recomposer = Recomposer(scope.coroutineContext)
    val runner = scope.launch { recomposer.runRecomposeAndApplyChanges() }
    val root = Node("root")
    val composition = Composition(NodeApplier(root), recomposer)
    composition.setContent { Content() }
    // The write-back made during the first composition does not schedule
    // another; one write from outside starts the loop, as derivedStateOfLeak's
    // first increment does.
    tick.intValue += 1

    var frameTime = 0L
    val start = TimeSource.Monotonic.markNow()
    repeat(FRAMES) {
        Snapshot.sendApplyNotifications()
        frameTime += 16_666_666L
        clock.sendFrame(frameTime)
    }
    val elapsed = start.elapsedNow()

    println("frames=$FRAMES recompositions=$recompositions nodes=${root.children.size} value=${root.children[0].value}")
    println("wall ${elapsed.inWholeMilliseconds} ms, ${elapsed.inWholeMicroseconds / FRAMES} us per frame")

    composition.dispose()
    recomposer.close()
    runner.cancel()
}
