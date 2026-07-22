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

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.klioDrawToSurface
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerInputEventData
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputEventProcessor
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.PositionCalculator
import androidx.compose.ui.klio.KlioComposeOwner
import androidx.compose.ui.klio.KlioRecomposerDriver
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
): Boolean {
    val handle = __composeui_winOpen(width, height, title)
    if (handle == 0L) return false

    val recomposerDriver = KlioRecomposerDriver()
    val recomposer = recomposerDriver.recomposer
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
        recomposerDriver.frame()
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
            PointerInputEvent(
                eventType,
                uptime,
                listOf(data),
                buttons = PointerButtons(isPrimaryPressed = down),
            ),
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
    recomposerDriver.close()
    return true
}

/**
 * Receiver scope of an [application] block; [exitApplication] requests the
 * running window loop to stop, mirroring desktop Compose's ApplicationScope.
 */
interface ApplicationScope {
    fun exitApplication()
}

/** The application composition emits no UI nodes of its own. */
private class KlioNoopApplier : AbstractApplier<Unit>(Unit) {
    override fun insertTopDown(index: Int, instance: Unit) {}
    override fun insertBottomUp(index: Int, instance: Unit) {}
    override fun remove(index: Int, count: Int) {}
    override fun move(from: Int, to: Int, count: Int) {}
    override fun onClear() {}
}

/** One live native window: its engine owner, content composition, and loop state. */
internal class KlioWindowHolder(
    val handle: Long,
    val owner: KlioComposeOwner,
    val composition: Composition,
    val processor: PointerInputEventProcessor,
    var w: Int,
    var h: Int,
    var title: String,
) {
    var uptime: Long = 0L
    var dirty: Boolean = true
    var closed: Boolean = false
    var onCloseRequest: () -> Unit = {}
}

internal class KlioApplicationScope(
    private val recomposer: Recomposer,
    private val density: Float,
) : ApplicationScope {
    val windows = mutableListOf<KlioWindowHolder>()
    var exited = false

    override fun exitApplication() {
        exited = true
    }

    fun open(title: String, width: Int, height: Int, content: @Composable () -> Unit): KlioWindowHolder? {
        val handle = __composeui_winOpen(width, height, title)
        if (handle == 0L) return null
        val owner = KlioComposeOwner(Density(density), LayoutDirection.Ltr)
        val composition = Composition(KlioUiApplier(owner.root), recomposer)
        composition.setContent {
            ProvideKlioCompositionLocals(owner) { content() }
        }
        val holder = KlioWindowHolder(
            handle, owner, composition, PointerInputEventProcessor(owner.root),
            width, height, title,
        )
        windows.add(holder)
        return holder
    }

    fun close(holder: KlioWindowHolder) {
        if (holder.closed) return
        holder.closed = true
        __composeui_winClose(holder.handle)
        holder.composition.dispose()
    }
}

/**
 * Declare a window inside an [application] block, desktop-Compose style. The
 * window opens when this composable enters the composition and closes when it
 * leaves — so a window gated on state (`if (show) Window(...)`) opens and
 * closes with that state. [title], [width], and [height] are
 * recomposition-driven: changing the state they read retitles/resizes the
 * live native window. The native close button invokes [onCloseRequest]; the
 * window only actually closes when the app's state stops composing it (or the
 * whole application exits).
 */
@Composable
fun ApplicationScope.Window(
    onCloseRequest: () -> Unit,
    title: String = "Untitled",
    width: Int = 800,
    height: Int = 600,
    content: @Composable () -> Unit,
) {
    val scope = this
    if (scope !is KlioApplicationScope) return
    val holder = remember { scope.open(title, width, height, content) }
    if (holder != null) {
        holder.onCloseRequest = onCloseRequest
        if (holder.title != title) {
            holder.title = title
            __composeui_winSetTitle(holder.handle, title)
        }
        if (holder.w != width || holder.h != height) {
            holder.w = width
            holder.h = height
            __composeui_winSetSize(holder.handle, width, height)
            holder.dirty = true
        }
        DisposableEffect(Unit) {
            onDispose { scope.close(holder) }
        }
    }
}

private fun renderWindowFrame(holder: KlioWindowHolder) {
    holder.owner.setRootConstraints(Constraints(maxWidth = holder.w, maxHeight = holder.h))
    holder.owner.measureAndLayoutForFrame()
    val surface = __composeui_winSurface(holder.handle)
    if (surface == 0L) return
    __composeui_winClear(holder.handle, 0xFF000000.toInt())
    klioDrawToSurface(surface) { holder.owner.drawTo(this) }
    __composeui_winPresent(holder.handle)
    holder.dirty = false
}

private fun dispatchWindowPointer(holder: KlioWindowHolder, x: Int, y: Int, down: Boolean, hover: Boolean) {
    holder.uptime += 8
    val position = Offset(x.toFloat(), y.toFloat())
    val data = PointerInputEventData(
        id = PointerId(0),
        uptime = holder.uptime,
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
    holder.processor.process(
        PointerInputEvent(
            eventType,
            holder.uptime,
            listOf(data),
            buttons = PointerButtons(isPrimaryPressed = down),
        ),
        IdentityPositionCalculator,
    )
}

/** Drain one window's pending events; returns true when anything arrived. */
private fun pumpWindow(holder: KlioWindowHolder, timeoutMs: Int): Boolean {
    var any = false
    val onResize: (Int, Int) -> Unit = { nw, nh ->
        holder.w = nw
        holder.h = nh
        renderWindowFrame(holder)
    }
    var ev = __composeui_winPoll(holder.handle, timeoutMs, onResize)
    while (true) {
        val type = (ev shr 32).toInt()
        val a = ((ev shr 16) and 0xFFFF).toInt()
        val b = (ev and 0xFFFF).toInt()
        when (type) {
            2 -> {
                any = true
                holder.onCloseRequest()
            }
            1 -> {
                any = true
                dispatchWindowPointer(holder, a, b, down = true, hover = false)
                dispatchWindowPointer(holder, a, b, down = false, hover = false)
                holder.dirty = true
            }
            4 -> {
                any = true
                dispatchWindowPointer(holder, a, b, down = false, hover = true)
                holder.dirty = true
            }
            5 -> {
                any = true
                holder.w = a
                holder.h = b
                holder.dirty = true
            }
        }
        if (type == 0) break
        ev = __composeui_winPoll(holder.handle, 0, onResize)
    }
    return any
}

/**
 * One frame under an OS-driven frame source: advance recomposition and redraw
 * every live window. Called by the platform's frame callback (not a loop);
 * returns true while any window is live. Mirrors one iteration of [application]'s
 * loop minus the blocking event poll (input arrives via a separate callback).
 */
private fun frameHosted(recomposerDriver: KlioRecomposerDriver, scope: KlioApplicationScope): Boolean {
    if (recomposerDriver.frame()) {
        for (win in scope.windows) if (!win.closed) win.dirty = true
    }
    val live = scope.windows.filter { !it.closed }
    if (live.isEmpty()) return false
    for (win in live) renderWindowFrame(win)
    return true
}

/**
 * Run a compose application: [content] is a COMPOSABLE block whose [Window]
 * declarations manage native windows — multiple windows compose side by side,
 * state-gated windows open/close with recomposition, and window parameters
 * (title/size) follow the state they read. The loop drives recomposition,
 * rendering, and input for every live window until [ApplicationScope.exitApplication]
 * runs or the last window leaves the composition. Headless-safe (no windowing
 * backend → windows never open and the loop ends). `maxFrames` bounds the loop
 * for deterministic tests; a real app omits it. Returns true when at least one
 * window opened.
 */
fun application(
    maxFrames: Int = -1,
    density: Float = 1f,
    content: @Composable ApplicationScope.() -> Unit,
): Boolean {
    val recomposerDriver = KlioRecomposerDriver()
    val recomposer = recomposerDriver.recomposer
    val scope = KlioApplicationScope(recomposer, density)
    val appComposition = Composition(KlioNoopApplier(), recomposer)
    appComposition.setContent {
        scope.content()
    }
    val openedAny = scope.windows.isNotEmpty()
    if (__composeui_isHosted()) {
        // OS-driven (mobile): the platform's frame source (e.g. iOS
        // CADisplayLink) calls the registered callback once per vsync on the
        // resident interpreter. Register it and return without a loop; the
        // recomposer + windows captured by the callback stay alive because the
        // VM stays resident.
        __composeui_setFrameCallback { frameHosted(recomposerDriver, scope) }
        return openedAny
    }
    var frame = 0
    while (!scope.exited && (maxFrames < 0 || frame < maxFrames)) {
        // One recomposition frame: state invalidated by effects or events
        // (not only input) marks every live window for redraw — a title
        // counter driven by LaunchedEffect repaints without a pointer.
        if (recomposerDriver.frame()) {
            for (win in scope.windows) {
                if (!win.closed) win.dirty = true
            }
        }
        val live = scope.windows.filter { !it.closed }
        if (live.isEmpty()) break
        for (win in live) {
            if (win.dirty) renderWindowFrame(win)
        }
        for (win in live) {
            if (win.closed) continue
            if (pumpWindow(win, 16)) win.dirty = true
        }
        frame += 1
    }
    for (win in scope.windows) scope.close(win)
    appComposition.dispose()
    recomposerDriver.close()
    return openedAny
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

internal fun __composeui_winSetTitle(handle: Long, title: String): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetTitle not installed")

internal fun __composeui_winSetSize(handle: Long, width: Int, height: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetSize not installed")

// True when the platform owns the frame loop (mobile): [application] then
// registers a per-frame callback and returns instead of running its own loop.
internal fun __composeui_isHosted(): Boolean =
    error("intrinsic androidx.compose.ui.window.__composeui_isHosted not installed")

// Register the per-frame render callback with the host; the platform frame
// source invokes it once per vsync on the resident VM.
internal fun __composeui_setFrameCallback(callback: () -> Boolean): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_setFrameCallback not installed")
