/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// A klio host's scene: its content's owner and the layers Popup and Dialog
// open above it, each with an owner and composition of its own, in the one
// window coordinate space. It lays them out, draws them in order, takes input
// through skiko's ComposeSceneInputHandler as BaseComposeScene does, and
// routes it to its owners as CanvasLayersComposeScene does.

package androidx.compose.ui.klio

import androidx.compose.ui.platform.DefaultUiApplier
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
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.currentTimeMillis
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.rotary.RotaryScrollEvent
import androidx.compose.ui.scene.ComposeSceneContext
import androidx.compose.ui.scene.ComposeSceneInputHandler
import androidx.compose.ui.scene.ComposeSceneLayer
import androidx.compose.ui.scene.ComposeScenePointer
import androidx.compose.ui.scene.PointerEventResult
import androidx.compose.ui.scene.merging
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

private fun PointerInputEvent.isMouseOrSingleTouch() = button != null || pointers.size == 1

@OptIn(InternalComposeUiApi::class)
internal class KlioScene(val main: KlioComposeOwner, width: Int, height: Int) : ComposeSceneContext {
    /** The scene's input: the pointer and key state it tracks and the synthetic events it adds. */
    val inputHandler: ComposeSceneInputHandler = ComposeSceneInputHandler(
        prepareForPointerInputEvent = ::doMeasureAndLayout,
        processPointerInputEvent = ::processPointerInputEvent,
        cancelPointerInput = ::processCancelPointerInput,
        processKeyEvent = ::processKeyEvent,
    )

    /**
     * A pointer position update a layout asked for, run with the work the next
     * frame or input event flushes first, as BaseComposeScene dispatches it to
     * its FrameRecomposer.
     */
    private var pointerUpdateScheduled = false

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
        main.onPointerUpdate = inputHandler::onPointerUpdate
        // The platform toolkit starts with the first scene, and its key texts with it.
        androidx.compose.ui.input.key.platformKeyTextsLoaded = true
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
        main.setContainerSize(IntSize(width, height))
    }

    /** Whether a layer of the content or of a layer above it changed since the last draw. */
    val needsDraw: Boolean get() = main.needsDraw || layers.any { it.owner.needsDraw }

    /** Measures and lays out the content and every layer over a window of this size. */
    fun measureAndLayout(width: Int, height: Int) {
        setSize(width, height)
        main.setRootConstraints(Constraints(maxWidth = width, maxHeight = height))
        main.measureAndLayoutForFrame()
        for (layer in layers.toList()) layer.measureAndLayout(width, height)
        // Synthetic events are sent after measure and layout complete.
        if (inputHandler.needUpdatePointerPosition) pointerUpdateScheduled = true
    }

    /** Lays out what is pending in every owner at its current size. */
    private fun doMeasureAndLayout() {
        main.measureAndLayoutForFrame()
        for (layer in layers.toList()) layer.owner.measureAndLayoutForFrame()
    }

    /**
     * Runs the work its compositions' dispatcher has queued, as a
     * FrameRecomposer's trampoline dispatcher is flushed: a window's loop
     * dispatcher's queue. Headless, compositions run on Dispatchers.Unconfined
     * and nothing waits.
     */
    var flushDispatcher: () -> Unit = {}

    /**
     * Runs the work queued for the start of the next frame or input event: the
     * pointer update a layout scheduled, and the work the compositions'
     * dispatcher queued, so an input handler resumed by one event runs before
     * the next event comes.
     */
    fun performTrampolineDispatch() {
        if (pointerUpdateScheduled) {
            pointerUpdateScheduled = false
            inputHandler.updatePointerPosition()
        }
        flushDispatcher()
    }

    /** New content: the pointer state tracked for the old content is dropped. */
    fun onChangeContent() {
        inputHandler.onChangeContent()
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

    // --- input ----------------------------------------------------------------

    /** Sends a mouse, touch or stylus event at [position], as ComposeScene's sendPointerEvent. */
    fun sendPointerEvent(
        eventType: PointerEventType,
        position: Offset,
        scrollDelta: Offset = Offset.Zero,
        timeMillis: Long = currentTimeMillis(),
        type: PointerType = PointerType.Mouse,
        buttons: PointerButtons? = null,
        keyboardModifiers: PointerKeyboardModifiers? = null,
        nativeEvent: Any? = null,
        button: PointerButton? = null,
        scaleGestureFactor: Float = 1f,
        panGestureOffset: Offset = Offset.Zero,
    ): PointerEventResult = inputHandler.onPointerEvent(
        eventType = eventType,
        position = position,
        scrollDelta = scrollDelta,
        timeMillis = timeMillis,
        type = type,
        buttons = buttons,
        keyboardModifiers = keyboardModifiers,
        nativeEvent = nativeEvent,
        button = button,
        scaleGestureFactor = scaleGestureFactor,
        panGestureOffset = panGestureOffset,
    ).also {
        performTrampolineDispatch()
    }

    /** Sends an event of several pointers, as ComposeScene's sendPointerEvent. */
    fun sendPointerEvent(
        eventType: PointerEventType,
        pointers: List<ComposeScenePointer>,
        buttons: PointerButtons = PointerButtons(),
        keyboardModifiers: PointerKeyboardModifiers = PointerKeyboardModifiers(),
        scrollDelta: Offset = Offset.Zero,
        timeMillis: Long = currentTimeMillis(),
        nativeEvent: Any? = null,
        button: PointerButton? = null,
        scaleGestureFactor: Float = 1f,
        panGestureOffset: Offset = Offset.Zero,
    ): PointerEventResult = inputHandler.onPointerEvent(
        eventType = eventType,
        pointers = pointers,
        buttons = buttons,
        keyboardModifiers = keyboardModifiers,
        scrollDelta = scrollDelta,
        timeMillis = timeMillis,
        nativeEvent = nativeEvent,
        button = button,
        scaleGestureFactor = scaleGestureFactor,
        panGestureOffset = panGestureOffset,
    ).also {
        performTrampolineDispatch()
    }

    fun cancelPointerInput() {
        inputHandler.cancelPointerInput()
    }

    /** Sends a key event to the focused layer, or the content; true when it was consumed. */
    fun sendKeyEvent(keyEvent: KeyEvent): Boolean =
        inputHandler.onKeyEvent(keyEvent).also {
            performTrampolineDispatch()
        }

    fun sendRotaryScrollEvent(
        verticalScrollPixels: Float,
        horizontalScrollPixels: Float,
        timeMillis: Long = currentTimeMillis(),
    ): Boolean {
        val event = RotaryScrollEvent(
            verticalScrollPixels = verticalScrollPixels,
            horizontalScrollPixels = horizontalScrollPixels,
            uptimeMillis = timeMillis
        )
        return processRotaryScrollEvent(event).also {
            performTrampolineDispatch()
        }
    }

    private fun processKeyEvent(keyEvent: KeyEvent): Boolean =
        focusedLayer?.onKeyEvent(keyEvent) ?: main.onKeyEvent(keyEvent)

    private fun processRotaryScrollEvent(event: RotaryScrollEvent): Boolean =
        focusedLayer?.onRotaryEvent(event) ?: main.onRotaryEvent(event)

    private fun processCancelPointerInput() {
        main.onCancelPointerInput()
        for (layer in layers.toList()) layer.owner.onCancelPointerInput()
        // Every ongoing gesture is cancelled.
        gestureOwner = null
    }

    /** Routes a pointer event to the owners that take it. */
    private fun processPointerInputEvent(event: PointerInputEvent): PointerEventResult {
        val result = when (event.eventType) {
            PointerEventType.Press -> processPress(event)
            PointerEventType.Release -> processRelease(event)
            PointerEventType.Move -> processMove(event)
            PointerEventType.Enter -> processMove(event)
            PointerEventType.Exit -> processMove(event)
            PointerEventType.Scroll -> processHoveredEvent(event)
            PointerEventType.PanStart,
            PointerEventType.PanMove,
            PointerEventType.PanEnd -> processHoveredEvent(event)
            PointerEventType.ScaleStart,
            PointerEventType.ScaleChange,
            PointerEventType.ScaleEnd -> processHoveredEvent(event)
            // No side effects from an event of no known type.
            PointerEventType.Unknown -> return processUnknownEvent(event)
            else -> PointerEventResult(anyMovementConsumed = false)
        }
        // A gesture ends with its last pressed pointer or button.
        if (!event.isGestureInProgress) gestureOwner = null
        return result
    }

    private fun processPress(event: PointerInputEvent): PointerEventResult {
        gestureOwner?.let { return it.onPointerInput(event) }
        val position = event.pointers.first().position
        for (layer in layers.asReversed().toList()) {
            // Within a layer, it takes the press; outside, it hears of it.
            if (layer.contains(position)) {
                val result = layer.owner.onPointerInput(event)
                gestureOwner = layer.owner
                return result
            }
            layer.onOutsidePointerEvent(event)
            // A layer that takes the input around it stops it here.
            if (layer.consumePointerInputOutside) return PointerEventResult(anyMovementConsumed = false)
        }
        val result = main.onPointerInput(event)
        gestureOwner = main
        return result
    }

    private fun processRelease(event: PointerInputEvent): PointerEventResult {
        // The owner the gesture started in takes its release, wherever it is.
        val result = gestureOwner?.onPointerInput(event)
        if (!event.isGestureInProgress) {
            val owner = hoveredOwner(event)
            if (isInteractive(owner)) {
                processHover(event, owner)?.let { return it }
            } else if (gestureOwner == null) {
                // Released outside the focused layer, below it or over nothing.
                focusedLayer?.onOutsidePointerEvent(event)
            }
        }
        return result ?: PointerEventResult(anyMovementConsumed = false)
    }

    private fun processMove(event: PointerInputEvent): PointerEventResult {
        var owner = when {
            event.isGestureInProgress -> gestureOwner
            // An Exit leaves every owner; none is entered or moved over.
            event.eventType == PointerEventType.Exit -> null
            else -> hoveredOwner(event)
        }
        // A blocked owner is left, not moved over.
        if (!isInteractive(owner)) owner = null
        processHover(event, owner)?.let { return it }
        return owner?.onPointerInput(event.copy(eventType = PointerEventType.Move))
            ?: PointerEventResult(anyMovementConsumed = false)
    }

    /**
     * Moves the hover from the owner last under a mouse to [owner]: an Exit to
     * the one and an Enter to the other, in place of the Move. Null when the
     * owner is the same, or the pointer is not a mouse.
     */
    private fun processHover(event: PointerInputEvent, owner: KlioComposeOwner?): PointerEventResult? {
        if (event.pointers.any { it.type != PointerType.Mouse }) return null
        if (owner === lastHoverOwner) return null
        val lastHoverOwnerResult =
            lastHoverOwner?.onPointerInput(event.copy(eventType = PointerEventType.Exit))
                ?: PointerEventResult(anyMovementConsumed = false)
        val ownerResult = owner?.onPointerInput(event.copy(eventType = PointerEventType.Enter))
            ?: PointerEventResult(anyMovementConsumed = false)
        lastHoverOwner = owner
        // Changing the hover replaces the Move, so it counts as consumed.
        return lastHoverOwnerResult.merging(ownerResult)
    }

    private fun processHoveredEvent(event: PointerInputEvent): PointerEventResult {
        val owner = hoveredOwner(event)
        return if (isInteractive(owner)) owner.onPointerInput(event)
        else PointerEventResult(anyMovementConsumed = false)
    }

    private fun processUnknownEvent(event: PointerInputEvent): PointerEventResult =
        gestureOwner?.onPointerInput(event) ?: processHoveredEvent(event)

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
            .also {
                it.scene = this@KlioScene
                it.onPointerUpdate = inputHandler::onPointerUpdate
            }
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
                inputHandler.onPointerUpdate()
            }

        init {
            layers.add(this)
            if (focusable) requestFocus(this)
            inputHandler.onPointerUpdate()
        }

        fun contains(point: Offset): Boolean = boundsInWindow.contains(point.round())

        fun measureAndLayout(width: Int, height: Int) {
            owner.setContainerSize(IntSize(width, height))
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
            inputHandler.onPointerUpdate()
            composition?.dispose()
            composition = null
            owner.dispose()
        }

        override fun setContent(parentCompositionContext: CompositionContext, content: @Composable () -> Unit) {
            check(!closed) { "KlioSceneLayer is closed" }
            composition?.dispose()
            composition = Composition(DefaultUiApplier(owner.root), parentCompositionContext).also {
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

        fun onKeyEvent(keyEvent: KeyEvent): Boolean {
            return onPreviewKeyEvent?.invoke(keyEvent) == true ||
                owner.onKeyEvent(keyEvent) ||
                onKeyEvent?.invoke(keyEvent) == true
        }

        fun onRotaryEvent(event: RotaryScrollEvent): Boolean {
            return owner.onRotaryEvent(event)
        }

        override fun setOutsidePointerEventListener(
            onOutsidePointerEvent: ((eventType: PointerEventType, button: PointerButton?) -> Unit)?,
        ) {
            outsidePointerCallback = onOutsidePointerEvent
        }

        override fun calculateLocalPosition(positionInWindow: IntOffset): IntOffset = positionInWindow

        fun onOutsidePointerEvent(event: PointerInputEvent) {
            if (!event.isMouseOrSingleTouch()) return
            outsidePointerCallback?.invoke(event.eventType, event.button)
        }
    }
}
