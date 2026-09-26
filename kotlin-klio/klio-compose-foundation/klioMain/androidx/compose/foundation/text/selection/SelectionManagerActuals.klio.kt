package androidx.compose.foundation.text.selection

/**
 * Desktop consumes the copy shortcut itself, so the selection manager does not
 * also handle it (Android, which has no key events for this, does).
 */
internal actual val SelectionManager.skipCopyKeyEvent: Boolean
    get() = true
