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
///   · circle cx cy r C · line x0 y0 x1 y1 stroke C · text x y size C <utf8>
fun renderDisplayListToPng(path: String, width: Int, height: Int, displayList: String): Long =
    __composeui_skiaRender(path, width, height, displayList)

// The wrapped height (px, ceil'd) of `text` laid out to `width` at font `size` via
// the Skia backend's real font metrics; 0 if Skia is unavailable (the layout pass
// then estimates from the nominal mono advance).
internal fun __composeui_measureText(text: String, width: Int, size: Int): Long =
    error("intrinsic klio.compose.ui.__composeui_measureText not installed")

// Windowing intrinsics (Skia + X11 backend). All degrade gracefully (winOpen
// returns 0, winPoll reports close) when no windowing backend is present.

// Opens a window and returns its handle (0 on failure).
internal fun __composeui_winOpen(width: Int, height: Int, title: String): Long =
    error("intrinsic klio.compose.ui.__composeui_winOpen not installed")

// Replays the display list into the window's surface and presents it.
internal fun __composeui_winRender(handle: Long, displayList: String): Long =
    error("intrinsic klio.compose.ui.__composeui_winRender not installed")

// Waits up to timeoutMs for an event; returns (type << 32) | (a << 16) | b.
// type 0 none, 1 click (a=x b=y), 2 close, 3 key (a=char b=keysym),
// 4 move (a=x b=y), 5 resize (a=w b=h).
internal fun __composeui_winPoll(handle: Long, timeoutMs: Int): Long =
    error("intrinsic klio.compose.ui.__composeui_winPoll not installed")

internal fun __composeui_winClose(handle: Long): Long =
    error("intrinsic klio.compose.ui.__composeui_winClose not installed")
