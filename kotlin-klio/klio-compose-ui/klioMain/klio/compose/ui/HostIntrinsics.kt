// Host-intrinsic entrypoints for klio.compose.ui.
//
// The interpreter routes this FQN to the Zig implementation in src/compose_ui
// (registered in pack_cache's mergedHostBindings). The body is the not-installed
// fallback.

package klio.compose.ui

// Replays a newline-separated display list of draw ops (see src/compose_ui's
// skiaRender) onto a Skia raster surface, writes a PNG to `path`, and returns an
// FNV-1a checksum of the encoded bytes (0 if Skia is unavailable).
internal fun __composeui_skiaRender(
    path: String,
    width: Int,
    height: Int,
    displayList: String,
): Long = error("intrinsic klio.compose.ui.__composeui_skiaRender not installed")

/// Render a raw draw-op display list to a PNG via the Skia backend. Ops are
/// newline-separated; colors are 8-hex-digit ARGB:
///   clear AARRGGBB · rect x y w h C · srect x y w h stroke C · rrect x y w h rx ry C
///   · circle cx cy r C · line x0 y0 x1 y1 stroke C
fun renderDisplayListToPng(path: String, width: Int, height: Int, displayList: String): Long =
    __composeui_skiaRender(path, width, height, displayList)
