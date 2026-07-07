// Host-intrinsic entrypoints for klio.compose.ui.
//
// The interpreter routes this FQN to the Zig implementation in src/compose_ui
// (registered in pack_cache's mergedHostBindings). The body is the not-installed
// fallback. __composeui_writePpm encodes the rasterized pixel buffer into a real
// P6 PPM image, writes it to `path` (best-effort), and returns an FNV-1a checksum
// of the encoded bytes — the offscreen rendering sink for the UI core.

package klio.compose.ui

internal fun __composeui_writePpm(
    path: String,
    width: Int,
    height: Int,
    hexData: String,
    scale: Int,
): Long = error("intrinsic klio.compose.ui.__composeui_writePpm not installed")

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
