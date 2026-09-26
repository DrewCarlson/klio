// klio's surfaces (a window's frame, a tray icon, an offscreen PNG) are Skia
// surfaces the host owns. A skiko Canvas over one draws where the surface's
// draws go; it frees nothing, and [owner] keeps what owns the pointer alive.
package klio.skia

import org.jetbrains.skia.Canvas

/** A skiko Canvas over the SkCanvas at [pointer], which [owner] keeps alive. */
fun wrapCanvas(pointer: Long, owner: Any): Canvas = Canvas(pointer, false, owner)
