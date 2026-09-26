/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// A window's input method sessions, as Compose Desktop's
// DesktopTextInputService2 runs them over AWT's input method events. While a
// text field has the keyboard the window's input method is on, its candidate
// window follows the field's cursor, and what it composes and commits edits
// the field; a key press it takes reaches no key listener.

package androidx.compose.ui.window

import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.text.input.CommitTextCommand
import androidx.compose.ui.text.input.EditCommand
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.ImeOptions
import androidx.compose.ui.text.input.SetComposingTextCommand
import androidx.compose.ui.text.input.TextFieldValue
import kotlin.math.roundToInt
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

@OptIn(ExperimentalComposeUiApi::class)
@Suppress("DEPRECATION")
internal class KlioWindowTextInput(private val handle: Long) :
    androidx.compose.ui.text.input.PlatformTextInputService {

    /**
     * One text field's hold on the input method: a session's [request], or the
     * legacy service's [onEditCommand] and the [focusedRect] it reports.
     */
    private class Session(
        val request: PlatformTextInputMethodRequest?,
        val onEditCommand: ((List<EditCommand>) -> Unit)?,
    ) {
        /** The composing text of the input method's last event. */
        var imeComposingText = ""
        var focusedRect: Rect? = null
        var placed: IntArray? = null
    }

    private var session: Session? = null

    private fun begin(session: Session) {
        this.session = session
        __composeui_winSetTextInput(handle, true)
        updateRect()
    }

    private fun end(session: Session) {
        if (this.session !== session) return
        this.session = null
        __composeui_winSetTextInput(handle, false)
    }

    suspend fun startInputMethod(request: PlatformTextInputMethodRequest): Nothing {
        val session = Session(request, null)
        begin(session)
        try {
            coroutineScope {
                // During a composition the selection is collapsed at its end; a
                // selection that moves elsewhere finishes composing.
                launch {
                    snapshotFlow { request.state.selection }.collect { selection ->
                        val composition = request.state.composition ?: return@collect
                        if (!selection.collapsed || selection.end != composition.end) {
                            request.editText { finishComposingText() }
                        }
                    }
                }
                // A composition the field ends itself ends for the input method too.
                launch {
                    snapshotFlow { request.state.composition }.collect { composition ->
                        if (session.imeComposingText.isNotEmpty() && composition == null) {
                            session.imeComposingText = ""
                            __composeui_winEndComposition(handle)
                        }
                    }
                }
                awaitCancellation()
            }
        } finally {
            end(session)
        }
    }

    override fun startInput(
        value: TextFieldValue,
        imeOptions: ImeOptions,
        onEditCommand: (List<EditCommand>) -> Unit,
        onImeActionPerformed: (ImeAction) -> Unit,
    ) {
        begin(Session(null, onEditCommand))
    }

    override fun stopInput() {
        val session = session ?: return
        if (session.request == null) end(session)
    }

    override fun showSoftwareKeyboard() {}

    override fun hideSoftwareKeyboard() {}

    override fun updateState(oldValue: TextFieldValue?, newValue: TextFieldValue) {}

    override fun notifyFocusedRect(rect: Rect) {
        session?.focusedRect = rect
        updateRect()
    }

    /**
     * The input method's event: [committed] text to insert, then the text it is
     * composing, which replaces the composition before it.
     */
    fun onInputMethodEvent(committed: String, composing: String) {
        val session = session ?: return
        session.imeComposingText = composing
        val request = session.request
        if (request != null) {
            request.editText {
                commitText(committed, 1)
                if (composing.isNotEmpty()) setComposingText(composing, 1)
            }
        } else {
            val commands = mutableListOf<EditCommand>(CommitTextCommand(committed, 1))
            if (composing.isNotEmpty()) commands.add(SetComposingTextCommand(composing, 1))
            session.onEditCommand?.invoke(commands)
        }
    }

    /**
     * Places the input method's candidate window at the field's cursor, as the
     * desktop's text location is: a zero-width rectangle at its horizontal center.
     */
    fun updateRect() {
        val session = session ?: return
        val r = session.request?.focusedRectInRoot?.invoke() ?: session.focusedRect ?: return
        val placed = intArrayOf(r.center.x.roundToInt(), r.top.roundToInt(), 0, r.height.roundToInt())
        if (session.placed?.contentEquals(placed) == true) return
        session.placed = placed
        __composeui_winSetTextInputRect(handle, placed[0], placed[1], placed[2], placed[3])
    }
}

/** Turns the window's input method on for a focused text field, or off. */
internal fun __composeui_winSetTextInput(handle: Long, enabled: Boolean): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetTextInput not installed")

/** Where the focused text field's cursor is in the window's content, for the candidate window. */
internal fun __composeui_winSetTextInputRect(handle: Long, x: Int, y: Int, width: Int, height: Int): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetTextInputRect not installed")

/** Ends the input method's composition, which the field has already ended. */
internal fun __composeui_winEndComposition(handle: Long): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_winEndComposition not installed")

/** The text of the event the window's last poll returned. */
internal fun __composeui_winEventText(handle: Long): String =
    error("intrinsic androidx.compose.ui.window.__composeui_winEventText not installed")
