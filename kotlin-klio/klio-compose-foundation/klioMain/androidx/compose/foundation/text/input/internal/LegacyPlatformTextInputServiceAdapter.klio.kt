/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text.input.internal

import androidx.compose.ui.text.input.EditCommand
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.ImeOptions
import androidx.compose.ui.text.input.TextFieldValue

/**
 * klio actual for the legacy text-input service.
 *
 * klio has no IME. Text reaches a field through the window layer's key/text
 * events, which drive the field's own state, so the platform service has nothing
 * to start or stop. The adapter therefore keeps the session's callbacks but
 * performs no platform work: `BasicTextField` composes, measures, lays out and
 * DRAWS through the real engine, which is what the render tier needs. Wiring the
 * SDL text events into `onEditCommand` is the next step and belongs here.
 *
 * The base class already serves `showSoftwareKeyboard` / `hideSoftwareKeyboard`
 * (both `final`, both routed to the modifier node), so only the session surface
 * is supplied.
 */
internal class KlioLegacyPlatformTextInputServiceAdapter :
    LegacyPlatformTextInputServiceAdapter() {

    private var onEditCommand: ((List<EditCommand>) -> Unit)? = null
    private var onImeActionPerformed: ((ImeAction) -> Unit)? = null

    override fun startInput(
        value: TextFieldValue,
        imeOptions: ImeOptions,
        onEditCommand: (List<EditCommand>) -> Unit,
        onImeActionPerformed: (ImeAction) -> Unit,
    ) {
        this.onEditCommand = onEditCommand
        this.onImeActionPerformed = onImeActionPerformed
    }

    override fun stopInput() {
        onEditCommand = null
        onImeActionPerformed = null
    }

    override fun updateState(oldValue: TextFieldValue?, newValue: TextFieldValue) {
        // No platform input connection to keep in sync.
    }

    override fun startStylusHandwriting() {
        // No stylus surface.
    }
}

internal actual fun createLegacyPlatformTextInputServiceAdapter():
    LegacyPlatformTextInputServiceAdapter = KlioLegacyPlatformTextInputServiceAdapter()
