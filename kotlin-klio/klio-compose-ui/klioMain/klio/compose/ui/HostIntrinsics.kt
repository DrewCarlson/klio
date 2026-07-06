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
