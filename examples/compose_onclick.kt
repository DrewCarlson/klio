// foundation's desktop Modifier.onClick with PointerMatcher, as Compose
// Desktop has them: a click matches the pointer and buttons its matcher
// names (the primary mouse button by default) and the keyboard modifiers it
// asks for; a button no matcher names clicks nothing. The output is Compose
// Desktop 1.12.0's.
@file:OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.PointerMatcher
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.onClick
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

fun main() {
    val scene = KlioComposeScene(100, 200)
    scene.setContent {
        Column {
            // y 0..100: the primary button, and the secondary button apart.
            Box(
                Modifier.size(100.dp)
                    .onClick { println("primary click") }
                    .onClick(matcher = PointerMatcher.mouse(PointerButton.Secondary)) { println("secondary click") }
            )
            // y 100..200: a click only with Ctrl held, and one only with Shift.
            Box(
                Modifier.size(100.dp)
                    .onClick(keyboardModifiers = { isCtrlPressed }) { println("ctrl click") }
                    .onClick(keyboardModifiers = { isShiftPressed }) { println("shift click") }
            )
        }
    }

    fun click(at: Offset, button: PointerButton = PointerButton.Primary, ctrl: Boolean = false, shift: Boolean = false) {
        val mods = PointerKeyboardModifiers(isCtrlPressed = ctrl, isShiftPressed = shift)
        scene.sendPointerEvent(PointerEventType.Press, at, button = button, keyboardModifiers = mods)
        scene.sendPointerEvent(PointerEventType.Release, at, button = button, keyboardModifiers = mods)
        scene.frame()
    }

    println("--- buttons ---")
    click(Offset(20f, 20f))
    click(Offset(20f, 20f), PointerButton.Secondary)
    click(Offset(20f, 20f), PointerButton.Tertiary)
    println("--- modifiers ---")
    click(Offset(20f, 120f))
    click(Offset(20f, 120f), ctrl = true)
    click(Offset(20f, 120f), shift = true)
    click(Offset(20f, 120f), ctrl = true, shift = true)
    println("done")
}
