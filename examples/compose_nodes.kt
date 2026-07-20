// Node emission — the Applier path. A @Composable tree emits typed nodes through
// `ComposeNode`; a custom `Applier` materializes them into a real tree. This is
// the primitive every node-based Compose UI (Mosaic, Compose-UI) builds on:
//   - recomposition mutates a node's property in place (no rebuild),
//   - a conditional inserts / removes a node,
//   - `key { }` reorders a node while its remembered state follows the key.

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

// A minimal node tree the applier renders into.
class TestNode(val kind: String) {
    var text: String = ""
    val children = mutableListOf<TestNode>()

    fun dump(sb: StringBuilder, depth: Int) {
        var i = 0
        while (i < depth) {
            sb.append("  ")
            i += 1
        }
        sb.append(kind)
        if (text.isNotEmpty()) {
            sb.append("[")
            sb.append(text)
            sb.append("]")
        }
        sb.append("\n")
        for (c in children) c.dump(sb, depth + 1)
    }
}

// The Applier: navigates + edits the TestNode tree. down/up come from
// AbstractApplier; insert/remove/move act on the current node's children.
class TestApplier(root: TestNode) : AbstractApplier<TestNode>(root) {
    override fun insertTopDown(index: Int, instance: TestNode) {
        current.children.add(index, instance)
    }

    override fun insertBottomUp(index: Int, instance: TestNode) {
        // The tree is built top-down; nothing to do here.
    }

    override fun remove(index: Int, count: Int) {
        var i = 0
        while (i < count) {
            current.children.removeAt(index)
            i += 1
        }
    }

    override fun move(from: Int, to: Int, count: Int) {
        // Single-element move (all reconciler moves are count == 1).
        val el = current.children.removeAt(from)
        val dest = if (from > to) to else to - count
        current.children.add(dest, el)
    }

    override fun onClear() {
        root.children.clear()
    }
}

// How many nodes were created via a factory. Stays flat across a recomposition
// that only updates props / reorders — proof the tree is reused, not rebuilt.
var nodesCreated = 0

// Per-key birth order, stamped once via remember{} — proves remembered state
// follows a key across a reorder.
var births = 0

@Composable
fun Text(t: String) {
    ComposeNode<TestNode, TestApplier>(
        factory = {
            nodesCreated += 1
            TestNode("Text")
        },
        update = { set(t) { text = it } },
    )
}

@Composable
fun Box(content: @Composable () -> Unit) {
    ComposeNode<TestNode, TestApplier>(
        factory = {
            nodesCreated += 1
            TestNode("Box")
        },
        update = {},
        content = content,
    )
}

fun printTree(root: TestNode, label: String) {
    println("== " + label + " (nodesCreated=" + nodesCreated + ") ==")
    val sb = StringBuilder()
    for (c in root.children) c.dump(sb, 0)
    print(sb.toString())
}

var frameTime = 0L

/** Publish pending state writes and dispatch frames until the recomposer is
 * idle, so a recomposition provoked by a write has completed on return. */
suspend fun settle(recomposer: Recomposer, clock: BroadcastFrameClock) {
    Snapshot.sendApplyNotifications()
    while (recomposer.hasPendingWork) {
        yield()
        frameTime += 16_666_666L
        clock.sendFrame(frameTime)
        yield()
    }
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val root = TestNode("Root")
        val applier = TestApplier(root)
        val composition = Composition(applier, recomposer)

        val label = mutableStateOf("hello")
        val showOptional = mutableStateOf(true)
        val order = mutableStateOf(listOf("a", "b", "c"))

        composition.setContent {
            Box {
                Text(label.value)
                if (showOptional.value) Text("optional")
                for (id in order.value) {
                    key(id) {
                        val born = remember { births++ }
                        Text(id + "#" + born)
                    }
                }
            }
        }
        printTree(root, "initial")

        // 1. Property update in place: the label node's text changes, no new nodes.
        label.value = "world"
        settle(recomposer, clock)
        printTree(root, "after label -> world")

        // 2a. Conditional remove: the optional node drops out of the tree.
        showOptional.value = false
        settle(recomposer, clock)
        printTree(root, "after hide optional")

        // 2b. Conditional insert: it comes back (a fresh node).
        showOptional.value = true
        settle(recomposer, clock)
        printTree(root, "after show optional")

        // 3. Reorder via key{}: nodes move; remembered birth order follows the key.
        order.value = listOf("c", "a", "b")
        settle(recomposer, clock)
        printTree(root, "after reorder c,a,b")

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
        println("disposed; root children = " + root.children.size)
    }
}
