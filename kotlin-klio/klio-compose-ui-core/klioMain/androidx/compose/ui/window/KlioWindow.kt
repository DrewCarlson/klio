/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The klio desktop window driver for the REAL androidx.compose.ui engine: a
// native window (SDL2 / Cocoa via src/compose_ui) whose frames are drawn by
// KlioComposeOwner — compose → measure/layout → NodeCoordinator.draw(KlioCanvas)
// directly onto the window's Skia surface — with pointer events dispatched
// through the engine's own PointerInputEventProcessor (hit testing, press/
// release semantics, clickable/Button onClick).

package androidx.compose.ui.window

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.klioDrawToSurface
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerInputEventData
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputEventProcessor
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.PositionCalculator
import androidx.compose.ui.klio.KlioComposeOwner
import androidx.compose.ui.klio.KlioUiApplier
import androidx.compose.ui.klio.ProvideKlioCompositionLocals
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection

/** The window's coordinate space IS the root's: screen == local. */
private object IdentityPositionCalculator : PositionCalculator {
    override fun screenToLocal(positionOnScreen: Offset): Offset = positionOnScreen
    override fun localToScreen(localPosition: Offset): Offset = localPosition
}

/**
 * Open a native window and run [content] through the real compose.ui engine
 * until the window closes (or [maxFrames] loop iterations pass; negative runs
 * until close). Headless-safe: without a windowing backend it returns
 * immediately. This is klio's analogue of desktop Compose's `singleWindowApplication`.
 */
fun runComposeWindow(
    width: Int,
    height: Int,
    title: String,
    density: Float = 1f,
    maxFrames: Int = -1,
    content: @Composable () -> Unit,
) {
    val handle = __composeui_winOpen(width, height, title)
    if (handle == 0L) return

    val recomposer = Recomposer()
    val owner = KlioComposeOwner(Density(density), LayoutDirection.Ltr)
    val composition = Composition(KlioUiApplier(owner.root), recomposer)
    composition.setContent {
        ProvideKlioCompositionLocals(owner) { content() }
    }
    val pointerProcessor = PointerInputEventProcessor(owner.root)
    var w = width
    var h = height
    var uptime = 0L

    fun renderFrame() {
        recomposer.recompose()
        owner.setRootConstraints(Constraints(maxWidth = w, maxHeight = h))
        owner.measureAndLayoutForFrame()
        val surface = __composeui_winSurface(handle)
        if (surface == 0L) return
        __composeui_winClear(handle, 0xFF000000.toInt())
        klioDrawToSurface(surface) { owner.drawTo(this) }
        __composeui_winPresent(handle)
    }

    fun pointer(x: Int, y: Int, down: Boolean, hover: Boolean) {
        uptime += 8
        val position = Offset(x.toFloat(), y.toFloat())
        val data = PointerInputEventData(
            id = PointerId(0),
            uptime = uptime,
            positionOnScreen = position,
            position = position,
            down = down,
            pressure = 1f,
            type = PointerType.Mouse,
            activeHover = hover,
            scaleGestureFactor = 1f,
            panGestureOffset = Offset.Zero,
        )
        val eventType = when {
            down -> PointerEventType.Press
            hover -> PointerEventType.Move
            else -> PointerEventType.Release
        }
        pointerProcessor.process(
            PointerInputEvent(eventType, uptime, listOf(data)),
            IdentityPositionCalculator,
        )
    }

    var frame = 0
    var running = true
    var dirty = true
    val onResize: (Int, Int) -> Unit = { nw, nh ->
        w = nw
        h = nh
        renderFrame()
    }
    while (running && (maxFrames < 0 || frame < maxFrames)) {
        if (dirty) {
            renderFrame()
            dirty = false
        }
        var ev = __composeui_winPoll(handle, 100, onResize)
        while (true) {
            val type = (ev shr 32).toInt()
            val a = ((ev shr 16) and 0xFFFF).toInt()
            val b = (ev and 0xFFFF).toInt()
            when (type) {
                2 -> running = false
                1 -> {
                    // A click event carries press+release at one position:
                    // dispatch DOWN then UP so press gestures fire onClick.
                    pointer(a, b, down = true, hover = false)
                    pointer(a, b, down = false, hover = false)
                    dirty = true
                }
                4 -> {
                    pointer(a, b, down = false, hover = true)
                    dirty = true
                }
                5 -> {
                    w = a
                    h = b
                    dirty = true
                }
            }
            if (type == 0 || !running) break
            ev = __composeui_winPoll(handle, 0, onResize)
        }
        frame += 1
    }
    __composeui_winClose(handle)
    composition.dispose()
    recomposer.close()
}

// --- Host intrinsics (klio.compose.ui window surface, bound by FQN) ---------

internal fun __composeui_winOpen(width: Int, height: Int, title: String): Long =
    error("intrinsic klio.compose.ui.__composeui_winOpen not installed")

internal fun __composeui_winPoll(handle: Long, timeoutMs: Int, onResize: (Int, Int) -> Unit): Long =
    error("intrinsic klio.compose.ui.__composeui_winPoll not installed")

internal fun __composeui_winClose(handle: Long): Long =
    error("intrinsic klio.compose.ui.__composeui_winClose not installed")

internal fun __composeui_winSurface(handle: Long): Long =
    error("intrinsic klio.compose.ui.__composeui_winSurface not installed")

internal fun __composeui_winPresent(handle: Long): Long =
    error("intrinsic klio.compose.ui.__composeui_winPresent not installed")

internal fun __composeui_winClear(handle: Long, argb: Int): Long =
    error("intrinsic klio.compose.ui.__composeui_winClear not installed")
