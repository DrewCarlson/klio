/*
 * Copyright 2025 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// ui's desktopMain PlatformClipboard.desktop.kt (v1.12.0) over klio.datatransfer,
// which has java.awt.datatransfer's types: the system clipboard is
// klio.datatransfer's (null where the desktop's Toolkit throws
// HeadlessException), and a transferable's flavors are read through its
// transferDataFlavors extension. Its transferables raise no IOException, so the
// catch for one goes, and a flavor argument is never null. The rest is the
// desktop's.
package androidx.compose.ui.platform

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.text.AnnotatedString
import klio.datatransfer.ClipboardOwner
import klio.datatransfer.DataFlavor
import klio.datatransfer.StringSelection
import klio.datatransfer.Transferable
import klio.datatransfer.UnsupportedFlavorException
import klio.datatransfer.transferDataFlavors

actual typealias NativeClipboard = Any

private val systemClipboard by lazy {
    klio.datatransfer.systemClipboard()
}

@Deprecated(
    "Use AwtPlatformClipboard instead, which supports suspend functions.",
    ReplaceWith("AwtPlatformClipboard", "androidx.compose.ui.platform.AwtPlatformClipboard"),
)
@Suppress("DEPRECATION")
internal class AwtClipboardManager : ClipboardManager {
    override fun getText(): AnnotatedString? =
        getClipboardText()?.let { AnnotatedString(it) }

    override fun setText(annotatedString: AnnotatedString) {
        setClipboardText(annotatedString.text)
    }

    override fun hasText(): Boolean = !getClipboardText().isNullOrEmpty()

    override fun getClip(): ClipEntry? = null

    @Suppress("GetterSetterNames")
    override fun setClip(clipEntry: ClipEntry?) = Unit

    private fun setClipboardText(text: String) {
        systemClipboard?.setContents(StringSelection(text), null)
    }

    private fun getClipboardText(): String? {
        return try {
            systemClipboard?.getData(DataFlavor.stringFlavor) as String?
        } catch (_: UnsupportedFlavorException) {
            null
        } catch (_: IllegalStateException) {
            null
        }
    }
}

internal class AwtPlatformClipboard internal constructor() : Clipboard {
    override suspend fun getClipEntry(): ClipEntry? {
        val transferable = systemClipboard?.getContents(null) ?: return null
        val flavors = transferable.transferDataFlavors
        if (flavors?.size == 0) return null
        return ClipEntry(transferable)
    }

    override suspend fun setClipEntry(clipEntry: ClipEntry?) {
        val transferable = clipEntry?.asAwtTransferable
        systemClipboard?.setContents(
            /* contents = */ transferable ?: EmptyTransferable,
            /* owner = */ transferable as? ClipboardOwner,
        )
    }

    /**
     * Provides an instance of a platform clipboard.
     * The actual implementation may vary depending on the underlying GUI toolkit.
     * See [awtClipboard] to access [klio.datatransfer.Clipboard].
     */
    override val nativeClipboard: NativeClipboard
        get() = systemClipboard ?: NoClipboard
}

/**
 * The object returned as the [NativeClipboard] when [AwtPlatformClipboard.systemClipboard] is null.
 */
private data object NoClipboard

/**
 * Returns [klio.datatransfer.Clipboard] instance if it's available, or null otherwise.
 */
@ExperimentalComposeUiApi
val Clipboard.awtClipboard: klio.datatransfer.Clipboard?
    get() = nativeClipboard as? klio.datatransfer.Clipboard

/**
 * A wrapper for platform clip entry instance which can be used to access
 * or set the Clipboard content. The actual implementation may vary
 * depending on the underlying GUI toolkit and on the actual implementation
 * of Clipboard.nativeClipboard.
 *
 * See [asAwtTransferable] to access [Transferable].
 */
actual class ClipEntry
@ExperimentalComposeUiApi
constructor(
    @property:ExperimentalComposeUiApi
    val nativeClipEntry: Any
) {
    // TODO: https://youtrack.jetbrains.com/issue/CMP-1260
    actual val clipMetadata: ClipMetadata
        get() = TODO("ClipMetadata is not implemented. Consider using nativeClipboard")
}

/**
 * Returns a [Transferable] instance if the [ClipEntry.nativeClipEntry]
 * type is [Transferable]. Otherwise, it returns null.
 */
@ExperimentalComposeUiApi
val ClipEntry.asAwtTransferable: Transferable?
    get() = nativeClipEntry as? Transferable

private object EmptyTransferable : Transferable {
    override fun getTransferDataFlavors(): Array<DataFlavor> {
        return emptyArray()
    }

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean = false

    override fun getTransferData(flavor: DataFlavor): Any {
        throw UnsupportedFlavorException(flavor)
    }
}

@Suppress("DEPRECATION")
internal actual fun createPlatformClipboardManager(): ClipboardManager = AwtClipboardManager()

internal actual fun createPlatformClipboard(): Clipboard = AwtPlatformClipboard()
