// A Popup opens a layer above the content, in the same window. Its position
// provider places it against the bounds of the layout it is called from, and
// clipping keeps it inside the window. A press inside the popup goes to the
// popup. A press around it tells the popup, and then reaches the content
// below unless the popup is focusable. The mouse hover moves between the
// content and the popup. The popup's content is composed under the caller's
// composition, so it sees the caller's composition locals and state.
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

val LocalLabel = compositionLocalOf { "none" }

/** The anchor every popup here opens from: 60 x 60 at (40, 40). */
@Composable
fun Anchor(content: @Composable () -> Unit) {
    Box(Modifier.offset(40.dp, 40.dp).size(60.dp)) { content() }
}

fun Modifier.reportPosition(name: String): Modifier = onGloballyPositioned {
    println("$name at ${it.positionInWindow()} size ${it.size}")
}

fun placement() {
    println("--- placement ---")
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Anchor {
            Popup(alignment = Alignment.TopStart, offset = IntOffset(10, 70)) {
                Box(Modifier.size(50.dp).reportPosition("top-start + (10, 70)"))
            }
            Popup(alignment = Alignment.BottomEnd) {
                Box(Modifier.size(30.dp).reportPosition("bottom-end"))
            }
            Popup(alignment = Alignment.TopStart, offset = IntOffset(150, 0)) {
                Box(Modifier.size(50.dp).reportPosition("clipped"))
            }
            Popup(
                alignment = Alignment.TopStart,
                offset = IntOffset(150, 0),
                properties = PopupProperties(clippingEnabled = false),
            ) {
                Box(Modifier.size(50.dp).reportPosition("unclipped"))
            }
        }
    }
    scene.dispose()
}

fun clicks(name: String, properties: PopupProperties) {
    println("--- $name ---")
    var shown by mutableStateOf(true)
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Box(Modifier.fillMaxSize().clickable { println("content clicked") }) {
            Anchor {
                if (shown) {
                    Popup(
                        alignment = Alignment.TopStart,
                        offset = IntOffset(10, 70),
                        onDismissRequest = { println("dismiss requested"); shown = false },
                        properties = properties,
                    ) {
                        Box(Modifier.size(50.dp).clickable { println("popup clicked") })
                    }
                }
            }
        }
    }
    println("click inside")
    scene.click(60f, 130f)
    println("click outside")
    scene.click(10f, 10f)
    println("shown=$shown")
    println("click outside again")
    scene.click(10f, 10f)
    scene.dispose()
}

fun hover() {
    println("--- hover ---")
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Box(Modifier.fillMaxSize().pointerInput(Unit) {
            awaitPointerEventScope {
                while (true) println("content " + awaitPointerEvent().type)
            }
        }) {
            Anchor {
                Popup(alignment = Alignment.TopStart, offset = IntOffset(10, 70)) {
                    Box(Modifier.size(50.dp).pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) println("popup " + awaitPointerEvent().type)
                        }
                    })
                }
            }
        }
    }
    println("hover content")
    scene.hover(10f, 10f)
    println("hover content again")
    scene.hover(20f, 10f)
    println("hover popup")
    scene.hover(60f, 130f)
    println("hover content")
    scene.hover(10f, 10f)
    scene.dispose()
}

fun locals() {
    println("--- locals and state ---")
    var count by mutableStateOf(0)
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        CompositionLocalProvider(LocalLabel provides "from the caller") {
            Anchor {
                Popup {
                    println("popup sees label=${LocalLabel.current} count=$count")
                    Box(Modifier.size(50.dp).clickable { count++ })
                }
            }
        }
    }
    scene.click(45f, 45f)
    scene.click(45f, 45f)
    scene.dispose()
}

fun main() {
    placement()
    clicks("plain popup", PopupProperties())
    clicks("focusable popup", PopupProperties(focusable = true))
    clicks("kept on outside click", PopupProperties(dismissOnClickOutside = false))
    hover()
    locals()
}
