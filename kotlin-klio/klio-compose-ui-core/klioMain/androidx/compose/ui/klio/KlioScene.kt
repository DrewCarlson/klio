/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// A klio host's scene: its content's owner and the layers Popup and Dialog
// open above it, each with an owner and composition of its own, in the one
// window coordinate space. It lays them out, draws them in order and routes
// pointer input to them as skiko's CanvasLayersComposeScene does.

package androidx.compose.ui.klio

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.CompositionContext
import androidx.compose.runtime.CompositionLocalContext
import androidx.compose.runtime.HostDefaultKey
import androidx.compose.runtime.HostDefaultProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerInputEventProcessor
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.PositionCalculator
import androidx.compose.ui.scene.ComposeSceneContext
import androidx.compose.ui.scene.ComposeSceneLayer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.round
import androidx.navigationevent.NavigationEventDispatcher
import androidx.navigationevent.NavigationEventDispatcherOwner
import androidx.navigationevent.compose.NavigationEventDispatcherOwnerHostDefaultKey

private val PointerInputEvent.isGestureInProgress: Boolean get() = pointers.any { it.down }

/** The scene's coordinate space is the window's: screen == local. */
private object ScenePositions : PositionCalculator {
    override fun screenToLocal(positionOnScreen: Offset): Offset = positionOnScreen
    override fun localToScreen(localPosition: Offset): Offset = localPosition
}

@OptIn(InternalComposeUiApi::class)
internal class KlioScene(val main: KlioComposeOwner, width: Int, height: Int) : ComposeSceneContext {
    private val mainProcessor = PointerInputEventProcessor(main.root)
    private val layers = ArrayList<KlioSceneLayer>()
    private var focusedLayer: KlioSceneLayer? = null
    private var gestureOwner: KlioComposeOwner? = null
    private var lastHoverOwner: KlioComposeOwner? = null
    private var width = 0
    private var height = 0

    /** The back events a Popup or Dialog registers to be dismissed by. */
    val navigationEventDispatcherOwner = object : NavigationEventDispatcherOwner {
        override val navigationEventDispatcher = NavigationEventDispatcher()
    }

    /** What the host answers a composition local with a host default by. */
    val hostDefaultProvider = object : HostDefaultProvider {
        @Suppress("UNCHECKED_CAST")
        override fun <T> getHostDefault(key: HostDefaultKey<T>): T = when (key) {
            NavigationEventDispatcherOwnerHostDefaultKey -> navigationEventDispatcherOwner
            else -> null
        } as T
    }

    init {
        main.scene = this
        // The window is focused and sized before its first composition, as a
        // skiko ImageComposeScene's is: Popup and Dialog place by its size.
        main.windowInfo.isWindowFocused = true
        setSize(width, height)
    }

    private fun setSize(width: Int, height: Int) {
        this.width = width
        this.height = height
        main.windowInfo.containerSize = IntSize(width, height)
        main.windowInfo.containerDpSize = with(main.density) { DpSize(width.toDp(), height.toDp()) }
    }

    /** Measures and lays out the content and every layer over a window of this size. */
    fun measureAndLayout(width: Int, height: Int) {
        setSize(width, height)
        main.setRootConstraints(Constraints(maxWidth = width, maxHeight = height))
        main.measureAndLayoutForFrame()
        for (layer in layers.toList()) layer.measureAndLayout(width, height)
    }

    /** Draws the content, then each layer above it with its scrim under it. */
    fun draw(canvas: Canvas) {
        main.drawTo(canvas)
        for (layer in layers.toList()) layer.draw(canvas, width, height)
    }

    fun dispose() {
        for (layer in layers.toList()) layer.close()
        main.dispose()
    }

    override fun createLayer(
        density: Density,
        layoutDirection: LayoutDirection,
        focusable: Boolean,
        consumePointerInputOutside: Boolean,
    ): ComposeSceneLayer = KlioSceneLayer(density, layoutDirection, focusable, consumePointerInputOutside)

    // --- pointer input ------------------------------------------------------

    /** Routes a pointer event to the owners that take it. */
    fun processPointer(event: PointerInputEvent) {
        when (event.eventType) {
            PointerEventType.Press -> processPress(event)
            PointerEventType.Release -> processRelease(event)
            PointerEventType.Move,
            PointerEventType.Enter,
            PointerEventType.Exit -> processMove(event)
            PointerEventType.Scroll,
            PointerEventType.PanStart,
            PointerEventType.PanMove,
            PointerEventType.PanEnd,
            PointerEventType.ScaleStart,
            PointerEventType.ScaleChange,
            PointerEventType.ScaleEnd -> processHoveredEvent(event)
            PointerEventType.Unknown -> {
                // No side effects from an event of no known type.
                gestureOwner?.let { send(it, event) } ?: processHoveredEvent(event)
                return
            }
            else -> {}
        }
        // A gesture ends with its last pressed pointer.
        if (!event.isGestureInProgress) gestureOwner = null
    }

    private fun processorOf(owner: KlioComposeOwner): PointerInputEventProcessor =
        if (owner === main) mainProcessor else layers.first { it.owner === owner }.processor

    private fun send(owner: KlioComposeOwner, event: PointerInputEvent) {
        if (event.button != null) owner.inputModeManager.requestInputMode(InputMode.Touch)
        val isInBounds = event.eventType != PointerEventType.Exit &&
            event.pointers.all { isInBounds(it.position) }
        processorOf(owner).process(event, ScenePositions, isInBounds = isInBounds)
    }

    /** Every owner covers the whole window, so this is the window's bounds. */
    private fun isInBounds(position: Offset): Boolean =
        position.x >= 0f && position.x < width && position.y >= 0f && position.y < height

    private fun processPress(event: PointerInputEvent) {
        gestureOwner?.let {
            send(it, event)
            return
        }
        val position = event.pointers.first().position
        for (layer in layers.asReversed().toList()) {
            // Within a layer, it takes the press; outside, it hears of it.
            if (layer.contains(position)) {
                send(layer.owner, event)
                gestureOwner = layer.owner
                return
            }
            layer.onOutsidePointerEvent(event)
            // A layer that takes the input around it stops it here.
            if (layer.consumePointerInputOutside) return
        }
        send(main, event)
        gestureOwner = main
    }

    private fun processRelease(event: PointerInputEvent) {
        // The owner the gesture started in takes its release, wherever it is.
        gestureOwner?.let { send(it, event) }
        if (!event.isGestureInProgress) {
            val owner = hoveredOwner(event)
            if (isInteractive(owner)) {
                processHover(event, owner)
            } else if (gestureOwner == null) {
                // Released outside the focused layer, below it or over nothing.
                focusedLayer?.onOutsidePointerEvent(event)
            }
        }
    }

    private fun processMove(event: PointerInputEvent) {
        var owner = when {
            event.isGestureInProgress -> gestureOwner
            // An Exit leaves every owner; none is entered or moved over.
            event.eventType == PointerEventType.Exit -> null
            else -> hoveredOwner(event)
        }
        // A blocked owner is left, not moved over.
        if (!isInteractive(owner)) owner = null
        if (processHover(event, owner)) return
        owner?.let { send(it, event.copy(eventType = PointerEventType.Move)) }
    }

    /**
     * Moves the hover from the owner last under a mouse to [owner]: an Exit to
     * the one and an Enter to the other, in place of the Move. False when the
     * owner is the same, or the pointer is not a mouse.
     */
    private fun processHover(event: PointerInputEvent, owner: KlioComposeOwner?): Boolean {
        if (event.pointers.any { it.type != PointerType.Mouse }) return false
        if (owner === lastHoverOwner) return false
        lastHoverOwner?.let { send(it, event.copy(eventType = PointerEventType.Exit)) }
        owner?.let { send(it, event.copy(eventType = PointerEventType.Enter)) }
        lastHoverOwner = owner
        return true
    }

    private fun processHoveredEvent(event: PointerInputEvent) {
        val owner = hoveredOwner(event)
        if (isInteractive(owner)) send(owner, event)
    }

    /** The owner under the pointer: the topmost layer holding it, else the content. */
    private fun hoveredOwner(event: PointerInputEvent): KlioComposeOwner {
        val position = event.pointers.first().position
        return layers.lastOrNull { it.contains(position) }?.owner ?: main
    }

    /** Whether no layer above [owner] takes the input around it. */
    private fun isInteractive(owner: KlioComposeOwner?): Boolean {
        if (owner == null) return true
        for (layer in layers.asReversed()) {
            if (layer.owner === owner) return true
            if (layer.consumePointerInputOutside) return false
        }
        return true
    }

    /** Whether [owner] is at or above the focused layer. */
    private fun isUnderFocusedLayer(owner: KlioComposeOwner): Boolean {
        val focused = focusedLayer ?: return true
        if (owner === main) return false
        for (layer in layers) {
            if (layer === focused) return true
            if (layer.owner === owner) return false
        }
        return true
    }

    private fun requestFocus(layer: KlioSceneLayer) {
        if (isUnderFocusedLayer(layer.owner)) focusedLayer = layer
    }

    private fun releaseFocus(layer: KlioSceneLayer) {
        if (layer === focusedLayer) focusedLayer = layers.lastOrNull { it.focusable }
    }

    private fun onOwnerRemoved(owner: KlioComposeOwner) {
        if (owner === lastHoverOwner) lastHoverOwner = null
        if (owner === gestureOwner) gestureOwner = null
    }

    // --- layers -------------------------------------------------------------

    private inner class KlioSceneLayer(
        density: Density,
        layoutDirection: LayoutDirection,
        focusable: Boolean,
        override var consumePointerInputOutside: Boolean,
    ) : ComposeSceneLayer {
        val owner = KlioComposeOwner(density, layoutDirection, main.windowInfo, main.coroutineContext)
            .also { it.scene = this@KlioScene }
        val processor = PointerInputEventProcessor(owner.root)
        private var composition: Composition? = null
        private var closed = false
        private var outsidePointerCallback: ((PointerEventType, PointerButton?) -> Unit)? = null
        private var onPreviewKeyEvent: ((KeyEvent) -> Boolean)? = null
        private var onKeyEvent: ((KeyEvent) -> Boolean)? = null

        override var density: Density
            get() = owner.density
            set(value) { owner.density = value }

        override var layoutDirection: LayoutDirection
            get() = owner.layoutDirection
            set(value) { owner.setLayoutDirection(value) }

        override var boundsInWindow: IntRect by mutableStateOf(IntRect.Zero)

        // Composition locals reach a layer through its parent composition
        // context, as on skiko, so this is kept only to be read back.
        override var compositionLocalContext: CompositionLocalContext? = null

        override var scrimColor: Color? by mutableStateOf(null)

        override var focusable: Boolean = focusable
            set(value) {
                field = value
                if (value) requestFocus(this) else releaseFocus(this)
            }

        init {
            layers.add(this)
            if (focusable) requestFocus(this)
        }

        fun contains(point: Offset): Boolean = boundsInWindow.contains(point.round())

        fun measureAndLayout(width: Int, height: Int) {
            owner.setRootConstraints(Constraints(maxWidth = width, maxHeight = height))
            owner.measureAndLayoutForFrame()
        }

        fun draw(canvas: Canvas, width: Int, height: Int) {
            scrimColor?.let { scrim ->
                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), Paint().also { it.color = scrim })
            }
            owner.drawTo(canvas)
        }

        override fun close() {
            if (closed) return
            closed = true
            layers.remove(this)
            releaseFocus(this)
            onOwnerRemoved(owner)
            composition?.dispose()
            composition = null
            owner.dispose()
        }

        override fun setContent(parentCompositionContext: CompositionContext, content: @Composable () -> Unit) {
            check(!closed) { "KlioSceneLayer is closed" }
            composition?.dispose()
            composition = Composition(KlioUiApplier(owner.root), parentCompositionContext).also {
                it.setContent { ProvideKlioCompositionLocals(owner) { content() } }
            }
        }

        override fun setKeyEventListener(
            onPreviewKeyEvent: ((KeyEvent) -> Boolean)?,
            onKeyEvent: ((KeyEvent) -> Boolean)?,
        ) {
            this.onPreviewKeyEvent = onPreviewKeyEvent
            this.onKeyEvent = onKeyEvent
        }

        override fun setOutsidePointerEventListener(
            onOutsidePointerEvent: ((eventType: PointerEventType, button: PointerButton?) -> Unit)?,
        ) {
            outsidePointerCallback = onOutsidePointerEvent
        }

        override fun calculateLocalPosition(positionInWindow: IntOffset): IntOffset = positionInWindow

        fun onOutsidePointerEvent(event: PointerInputEvent) {
            if (event.button == null && event.pointers.size != 1) return
            outsidePointerCallback?.invoke(event.eventType, event.button)
        }
    }
}
