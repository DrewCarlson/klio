// ui's desktop pointer API: Modifier.onPointerEvent reports the enter, move,
// exit, press and release events a node sees, with their positions in the
// node's coordinates and the buttons held, as a mouse moves over it, clicks
// it and leaves it. The deprecated Modifier.pointerMoveFilter hears the
// enter, move and exit of a second box. The events are the ones Compose
// Desktop 1.12.0 delivers.
@file:Suppress("DEPRECATION")

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerMoveFilter
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalComposeUiApi::class)
fun main() {
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Box(Modifier.fillMaxSize()) {
            var box = Modifier.offset(50.dp, 50.dp).size(100.dp)
            for (type in listOf(PointerEventType.Enter, PointerEventType.Move, PointerEventType.Exit, PointerEventType.Press, PointerEventType.Release)) {
                box = box.onPointerEvent(type) { event ->
                    val change = event.changes.first()
                    println("$type at ${change.position} pressed=${change.pressed} primary=${event.buttons.isPrimaryPressed}")
                }
            }
            Box(box)
            Box(
                Modifier.offset(150.dp, 0.dp).size(40.dp).pointerMoveFilter(
                    onMove = { println("filter: move at $it"); false },
                    onEnter = { println("filter: enter"); false },
                    onExit = { println("filter: exit"); false },
                )
            )
        }
    }
    println("-- move outside")
    scene.hover(10f, 10f)
    println("-- move in")
    scene.hover(60f, 70f)
    println("-- move within")
    scene.hover(80f, 90f)
    println("-- click")
    scene.click(80f, 90f)
    println("-- move out")
    scene.hover(190f, 190f)
    println("-- the filter box")
    scene.hover(160f, 10f)
    scene.hover(170f, 20f)
    scene.hover(195f, 100f)
    scene.dispose()
}
