/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The data transfer types of java.awt.datatransfer that Compose Desktop's
// clipboard is written against, with the same names and behaviour: a
// Transferable offers its data in DataFlavors, a Clipboard holds one with its
// owner, and the system clipboard is the host's. A program copies text as it
// does on the desktop, with a StringSelection.
//
// The subset is the one the clipboard needs: DataFlavor has the Java class
// flavors (a representation class and a name) and stringFlavor, the flavor the
// host's text is read and written in; a StringSelection offers its string in
// stringFlavor only.
package klio.datatransfer

import androidx.compose.ui.platform.makeSynchronizedObject
import androidx.compose.ui.platform.synchronized
import kotlin.reflect.KClass

/** A format a [Transferable] offers its data in. */
public open class DataFlavor(
    public val representationClass: KClass<*>,
    humanPresentableName: String?,
) {
    /** The flavor's MIME type, with the representation class as its parameter. */
    public val mimeType: String =
        "$SERIALIZED_OBJECT_MIME_TYPE; class=" + (representationClass.qualifiedName ?: "")

    public val humanPresentableName: String = humanPresentableName ?: mimeType

    /** Whether [mimeType], without its parameters, is this flavor's. */
    public fun isMimeTypeEqual(mimeType: String): Boolean =
        mimeType.substringBefore(';').trim().equals(SERIALIZED_OBJECT_MIME_TYPE, ignoreCase = true)

    /** Two flavors are equal when their MIME types and representation classes are. */
    override fun equals(other: Any?): Boolean =
        other is DataFlavor && representationClass == other.representationClass &&
            isMimeTypeEqual(other.mimeType)

    override fun hashCode(): Int = representationClass.hashCode() * 31 + SERIALIZED_OBJECT_MIME_TYPE.hashCode()

    override fun toString(): String =
        "klio.datatransfer.DataFlavor[mimetype=$SERIALIZED_OBJECT_MIME_TYPE;representationclass=" +
            (representationClass.qualifiedName ?: "") + "]"

    public companion object {
        /** The MIME type of a flavor whose data is an object of its representation class. */
        public const val javaSerializedObjectMimeType: String = SERIALIZED_OBJECT_MIME_TYPE

        /** Text, as a String. */
        public val stringFlavor: DataFlavor = DataFlavor(String::class, "Unicode String")
    }
}

private const val SERIALIZED_OBJECT_MIME_TYPE = "application/x-java-serialized-object"

/** Data a clipboard (or a drag) carries, in the flavors it offers. */
public interface Transferable {
    /** The flavors the data can be had in, preferred first. */
    public fun getTransferDataFlavors(): Array<out DataFlavor?>

    public fun isDataFlavorSupported(flavor: DataFlavor): Boolean

    /**
     * The data in [flavor]; throws [UnsupportedFlavorException] for a flavor
     * the transferable does not offer.
     */
    public fun getTransferData(flavor: DataFlavor): Any?
}

/** The flavors the data can be had in, as the desktop's property reads them. */
public val Transferable.transferDataFlavors: Array<out DataFlavor?>
    get() = getTransferDataFlavors()

/** Told when the contents it put on a clipboard are replaced. */
public fun interface ClipboardOwner {
    public fun lostOwnership(clipboard: Clipboard?, contents: Transferable?)
}

/** Thrown for data asked for in a flavor it is not offered in. */
public class UnsupportedFlavorException(flavor: DataFlavor?) : Exception(flavor?.humanPresentableName)

/** A string, offered as [DataFlavor.stringFlavor]. */
public class StringSelection(private val data: String) : Transferable, ClipboardOwner {
    override fun getTransferDataFlavors(): Array<out DataFlavor?> = arrayOf(DataFlavor.stringFlavor)

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean = flavor == DataFlavor.stringFlavor

    override fun getTransferData(flavor: DataFlavor): Any {
        if (flavor == DataFlavor.stringFlavor) return data
        throw UnsupportedFlavorException(flavor)
    }

    override fun lostOwnership(clipboard: Clipboard?, contents: Transferable?) {}
}

/**
 * A clipboard: it holds one [Transferable] and the owner that put it there,
 * which is told when other contents replace it.
 */
public open class Clipboard(public val name: String) {
    private val lock = makeSynchronizedObject(this)
    private var owner: ClipboardOwner? = null
    private var contents: Transferable? = null

    /**
     * Puts [contents] on the clipboard for [owner]. The previous owner, when
     * another, is told it lost the clipboard once the new contents are in.
     */
    public open fun setContents(contents: Transferable, owner: ClipboardOwner?) {
        replace(contents, owner)
    }

    /** The clipboard's contents, or null when it holds none. */
    public open fun getContents(requestor: Any?): Transferable? = synchronized(lock) { contents }

    /** The flavors the clipboard's contents are offered in. */
    public open val availableDataFlavors: Array<out DataFlavor?>
        get() = getContents(null)?.getTransferDataFlavors() ?: emptyArray()

    public open fun isDataFlavorAvailable(flavor: DataFlavor): Boolean =
        getContents(null)?.isDataFlavorSupported(flavor) ?: false

    /** The clipboard's data in [flavor]; throws [UnsupportedFlavorException] when it has none in it. */
    public open fun getData(flavor: DataFlavor): Any? {
        val contents = getContents(null) ?: throw UnsupportedFlavorException(flavor)
        return contents.getTransferData(flavor)
    }

    /** Replaces the contents and owner, telling the previous owner. */
    protected fun replace(contents: Transferable, owner: ClipboardOwner?) {
        var lost: ClipboardOwner? = null
        var lostContents: Transferable? = null
        synchronized(lock) {
            if (this.owner != null && this.owner !== owner) {
                lost = this.owner
                lostContents = this.contents
            }
            this.owner = owner
            this.contents = contents
        }
        lost?.lostOwnership(this, lostContents)
    }
}

/**
 * The system clipboard, or null when there is none (a host without one, or a
 * program run with `KLIO_CLIPBOARD=none`, as a headless desktop has none).
 * With `KLIO_CLIPBOARD=private` it is a clipboard of the program's own that
 * nothing outside the program reads or changes, as tests run.
 */
public fun systemClipboard(): Clipboard? = SystemClipboardHolder.clipboard

private object SystemClipboardHolder {
    val clipboard: Clipboard? = when (__klio_clipMode()) {
        CLIP_SYSTEM -> HostClipboard()
        CLIP_PRIVATE -> Clipboard("System")
        else -> null
    }
}

private const val CLIP_SYSTEM = 1
private const val CLIP_PRIVATE = 2

/**
 * The host's clipboard, as text. While no other application has changed it,
 * the contents this program put there are its own, as the desktop hands a
 * program back the Transferable it set. Once another has, its contents are
 * the host's text, and the program's owner is told it lost the clipboard.
 */
private class HostClipboard : Clipboard("System") {
    private val lock = makeSynchronizedObject(this)

    // The host's change count when this program last wrote or read it.
    private var seen = Long.MIN_VALUE

    override fun setContents(contents: Transferable, owner: ClipboardOwner?) {
        val text =
            if (contents.isDataFlavorSupported(DataFlavor.stringFlavor)) {
                contents.getTransferData(DataFlavor.stringFlavor) as? String
            } else {
                null
            }
        synchronized(lock) {
            __klio_clipSetText(text)
            seen = __klio_clipChangeCount()
        }
        replace(contents, owner)
    }

    override fun getContents(requestor: Any?): Transferable? {
        val changed = synchronized(lock) {
            val count = __klio_clipChangeCount()
            if (count == seen) {
                null
            } else {
                seen = count
                HostTransferable(__klio_clipText())
            }
        }
        if (changed != null) replace(changed, null)
        return super.getContents(requestor)
    }
}

/** What another application put on the host's clipboard: its text, if any. */
private class HostTransferable(private val text: String?) : Transferable {
    override fun getTransferDataFlavors(): Array<out DataFlavor?> =
        if (text != null) arrayOf(DataFlavor.stringFlavor) else emptyArray()

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean =
        text != null && flavor == DataFlavor.stringFlavor

    override fun getTransferData(flavor: DataFlavor): Any {
        if (text != null && flavor == DataFlavor.stringFlavor) return text
        throw UnsupportedFlavorException(flavor)
    }
}

// KLIO_CLIPBOARD's clipboard: 0 none, 1 the host's, 2 the program's own.
internal fun __klio_clipMode(): Int =
    error("intrinsic klio.datatransfer.__klio_clipMode not installed")

// The host clipboard's change count, which moves whenever any application
// changes it.
internal fun __klio_clipChangeCount(): Long =
    error("intrinsic klio.datatransfer.__klio_clipChangeCount not installed")

// The host clipboard's text, or null when it holds none.
internal fun __klio_clipText(): String? =
    error("intrinsic klio.datatransfer.__klio_clipText not installed")

// Replaces the host clipboard's contents with the text, or empties it for null.
internal fun __klio_clipSetText(text: String?): Long =
    error("intrinsic klio.datatransfer.__klio_clipSetText not installed")
