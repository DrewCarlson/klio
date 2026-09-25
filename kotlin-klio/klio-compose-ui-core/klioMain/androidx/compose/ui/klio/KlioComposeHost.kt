/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The klio desktop host for the real androidx.compose.ui engine. This is klio's
// analogue of Compose Multiplatform's RootNodeOwner + ImageComposeScene: it hosts
// the root LayoutNode, provides the platform CompositionLocals, runs the
// measure/layout passes through the vendored MeasureAndLayoutDelegate, and draws
// the node tree onto a klio Skia canvas (KlioCanvas) — the same Canvas actual the
// engine already renders through. A headless render entry point rasterizes a
// @Composable to a PNG.

package androidx.compose.ui.klio

import androidx.collection.MutableIntObjectMap
import androidx.collection.mutableIntObjectMapOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.AutofillTree
import androidx.compose.ui.node.MeasureAndLayoutDelegate
import kotlinx.coroutines.Dispatchers
import androidx.compose.ui.focus.FocusOwner
import androidx.compose.ui.focus.FocusOwnerImpl
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.PlatformFocusOwner
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.GraphicsContext
import androidx.compose.ui.graphics.SkiaGraphicsContext
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.klioDrawToPng
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.input.InputModeManagerImpl
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.PointerIconService
import androidx.compose.ui.input.pointer.PointerInputEventProcessor
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.PositionCalculator
import androidx.compose.ui.input.rotary.RotaryScrollEvent
import androidx.compose.ui.scene.ComposeScenePointer
import androidx.compose.ui.scene.PointerEventResult
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerInputEventData
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.layout.RootMeasurePolicy
import androidx.compose.ui.modifier.ModifierLocalManager
import androidx.compose.ui.node.LayoutNode
import androidx.compose.ui.node.LayoutNodeDrawScope
import androidx.compose.ui.node.GraphicsLayerOwnerLayer
import androidx.compose.ui.node.OwnedLayer
import androidx.compose.ui.node.OwnedLayerManager
import androidx.compose.ui.node.setLightingInfo
import androidx.compose.ui.node.Owner
import androidx.compose.ui.node.OwnerSnapshotObserver
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.AccessibilityManager
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.platform.EmptyPlatformWindowInsets
import androidx.compose.ui.platform.LocalPlatformPrefetchScheduler
import androidx.compose.ui.platform.LocalPlatformWindowInsets
import androidx.compose.ui.scene.LocalComposeSceneContext
import androidx.compose.runtime.HostDefaultKey
import androidx.compose.runtime.HostDefaultProvider
import androidx.compose.runtime.LocalHostDefaultProvider
import androidx.compose.ui.platform.PlatformPrefetchRequest
import androidx.compose.ui.platform.PlatformPrefetchScheduler
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.DefaultAccessibilityManager
import androidx.compose.ui.platform.DefaultHapticFeedback
import androidx.compose.ui.platform.DefaultTextToolbar
import androidx.compose.ui.platform.DefaultUiApplier
import androidx.compose.ui.platform.LocalAccessibilityManager
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.createPlatformClipboard
import androidx.compose.ui.platform.createPlatformClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalGraphicsContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.ProvideCommonCompositionLocals
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.ViewConfiguration
import androidx.compose.ui.platform.WindowInfoImpl
import androidx.compose.ui.semantics.EmptySemanticsModifier
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.spatial.RectManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.input.TextInputService
import androidx.compose.ui.text.input.EditCommand
import androidx.compose.ui.text.input.CommitTextCommand
import androidx.compose.ui.text.input.BackspaceCommand
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.window.__composeui_showKeyboard
import androidx.compose.ui.window.__composeui_hideKeyboard
import androidx.compose.ui.window.__composeui_setTextCallback
import androidx.compose.ui.window.__composeui_textInput
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.SessionMutex
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.platform.PlatformTextInputSessionScope
import androidx.compose.ui.text.InternalTextApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

// ---------------------------------------------------------------------------
// Platform services. The haptic feedback, accessibility manager and text
// toolbar are skikoMain's defaults; the rest construct and satisfy the
// CompositionLocals / Owner surface.
// ---------------------------------------------------------------------------

internal object KlioViewConfiguration : ViewConfiguration {
    override val longPressTimeoutMillis: Long = 500L
    override val doubleTapTimeoutMillis: Long = 300L
    override val doubleTapMinTimeMillis: Long = 40L
    override val touchSlop: Float = 18f
    override val minimumTouchTargetSize: DpSize get() = DpSize(48.dp, 48.dp)
}

internal object KlioSoftwareKeyboardController : androidx.compose.ui.platform.SoftwareKeyboardController {
    override fun show() { __composeui_showKeyboard() }
    override fun hide() { __composeui_hideKeyboard() }
}

internal object KlioPointerIconService : PointerIconService {
    private var icon: PointerIcon? = null
    override fun getIcon(): PointerIcon = icon ?: PointerIcon.Default
    override fun setIcon(value: PointerIcon?) { icon = value }
}

internal class KlioUriHandler : UriHandler {
    override fun openUri(uri: String) {}
}

internal object KlioPlatformTextInputService : androidx.compose.ui.text.input.PlatformTextInputService {
    private var editCommand: ((List<EditCommand>) -> Unit)? = null
    private var imeAction: ((ImeAction) -> Unit)? = null
    private var callbackInstalled = false

    /** The text field an input method session serves, over the legacy one. */
    private var request: PlatformTextInputMethodRequest? = null

    // The platform (iOS UIKeyInput) invokes this with a kind after staging any
    // text: 0=commit inserted text, 1=backspace, 2=ime action (enter/done).
    private fun onKey(kind: Int) {
        val request = request
        val edit = request?.onEditCommand ?: editCommand ?: return
        when (kind) {
            0 -> {
                val text = __composeui_textInput()
                if (text.isNotEmpty()) edit(listOf(CommitTextCommand(text, 1)))
            }
            1 -> edit(listOf(BackspaceCommand()))
            2 -> if (request != null) {
                request.onImeAction?.invoke(request.imeOptions.imeAction)
            } else {
                imeAction?.invoke(ImeAction.Done)
            }
        }
    }

    private fun installCallback() {
        if (!callbackInstalled) {
            __composeui_setTextCallback { kind -> onKey(kind) }
            callbackInstalled = true
        }
    }

    /**
     * An input method session for [request], as a skiko PlatformContext starts
     * one: the platform's text reaches the field until the session is cancelled.
     */
    suspend fun startInputMethod(request: PlatformTextInputMethodRequest): Nothing {
        this.request = request
        installCallback()
        __composeui_showKeyboard()
        try {
            awaitCancellation()
        } finally {
            if (this.request === request) {
                this.request = null
                __composeui_hideKeyboard()
            }
        }
    }

    override fun startInput(
        value: androidx.compose.ui.text.input.TextFieldValue,
        imeOptions: androidx.compose.ui.text.input.ImeOptions,
        onEditCommand: (List<EditCommand>) -> Unit,
        onImeActionPerformed: (ImeAction) -> Unit,
    ) {
        editCommand = onEditCommand
        imeAction = onImeActionPerformed
        installCallback()
        __composeui_showKeyboard()
    }

    override fun stopInput() {
        editCommand = null
        imeAction = null
        __composeui_hideKeyboard()
    }

    override fun showSoftwareKeyboard() { __composeui_showKeyboard() }
    override fun hideSoftwareKeyboard() { __composeui_hideKeyboard() }
    override fun updateState(
        oldValue: androidx.compose.ui.text.input.TextFieldValue?,
        newValue: androidx.compose.ui.text.input.TextFieldValue,
    ) {}
}

// ---------------------------------------------------------------------------
// The Owner: hosts the root LayoutNode, runs measure/layout, draws the tree.
// Mirrors Compose Multiplatform's RootNodeOwner.OwnerImpl over the vendored
// commonMain engine.
// ---------------------------------------------------------------------------

internal class KlioComposeOwner(
    density: Density,
    layoutDirection: LayoutDirection,
    /** The window this owner is in; a scene's layers share their content's. */
    override val windowInfo: WindowInfoImpl = WindowInfoImpl(),
    /**
     * Where the nodes' coroutines run: the scene's effect context, whose frame
     * clock their animations await.
     */
    override val coroutineContext: kotlin.coroutines.CoroutineContext = Dispatchers.Unconfined,
) : Owner {

    private val platformFocusOwner = object : PlatformFocusOwner {
        override fun requestOwnerFocus(focusDirection: FocusDirection?, previouslyFocusedRect: Rect?): Boolean = true
        override fun clearOwnerFocus() {}
        override fun moveFocusInChildren(focusDirection: FocusDirection): Boolean = false
        override fun getEmbeddedViewFocusRect(): Rect? = null
    }

    private val rootSemanticsNode = EmptySemanticsModifier()

    override val focusOwner: FocusOwner = FocusOwnerImpl(platformFocusOwner, this)

    override val root: LayoutNode = LayoutNode().also {
        it.layoutDirection = layoutDirection
        it.measurePolicy = RootMeasurePolicy
        it.modifier = Modifier.then(focusOwner.modifier)
    }

    override val layoutNodes: MutableIntObjectMap<LayoutNode> = mutableIntObjectMapOf()
    override val sharedDrawScope = LayoutNodeDrawScope()
    override val rootForTest: RootForTest = object : RootForTest {
        override val density: Density get() = this@KlioComposeOwner.density
        override val semanticsOwner: SemanticsOwner get() = this@KlioComposeOwner.semanticsOwner
        @Suppress("DEPRECATION")
        override val textInputService: TextInputService get() = this@KlioComposeOwner.textInputService
        override fun sendKeyEvent(keyEvent: KeyEvent): Boolean =
            scene?.sendKeyEvent(keyEvent) ?: onKeyEvent(keyEvent)
    }

    override val hapticFeedBack = DefaultHapticFeedback
    override val inputModeManager: InputModeManager = InputModeManagerImpl(InputMode.Keyboard) { true }
    @Suppress("DEPRECATION")
    override val clipboardManager: ClipboardManager = createPlatformClipboardManager()
    override val clipboard: Clipboard = createPlatformClipboard()
    override val accessibilityManager: AccessibilityManager = DefaultAccessibilityManager()
    private val skiaGraphicsContext = SkiaGraphicsContext()
    override val graphicsContext: GraphicsContext get() = skiaGraphicsContext
    // No window-level retain scenario (configuration changes) exists here.
    override val retainedValuesStore: androidx.compose.runtime.retain.RetainedValuesStore =
        androidx.compose.runtime.retain.ForgetfulRetainedValuesStore
    override val textToolbar: TextToolbar = DefaultTextToolbar()

    @Suppress("DEPRECATION")
    override val autofillTree = AutofillTree()
    @Suppress("DEPRECATION")
    override val autofill: androidx.compose.ui.autofill.Autofill? get() = null
    override val autofillManager: androidx.compose.ui.autofill.AutofillManager? get() = null

    override var density: Density by mutableStateOf(density)

    @Suppress("DEPRECATION")
    override val textInputService = TextInputService(KlioPlatformTextInputService)
    override val softwareKeyboardController = KlioSoftwareKeyboardController
    override val pointerIconService: PointerIconService = KlioPointerIconService

    override val semanticsOwner = SemanticsOwner(root, rootSemanticsNode, layoutNodes)

    @Suppress("DEPRECATION")
    override val fontLoader: androidx.compose.ui.text.font.Font.ResourceLoader =
        androidx.compose.ui.text.platform.FontLoader()
    override val fontFamilyResolver: FontFamily.Resolver = createFontFamilyResolver()

    private var _layoutDirection by mutableStateOf(layoutDirection)
    override val layoutDirection: LayoutDirection get() = _layoutDirection

    fun setLayoutDirection(value: LayoutDirection) {
        _layoutDirection = value
        root.layoutDirection = value
    }

    /** The scene this owner draws in: its host's, or its layer's host's. */
    var scene: KlioScene? = null
    override val localeList: LocaleList get() = LocaleList.current

    override var showLayoutBounds: Boolean = false

    override val modifierLocalManager = ModifierLocalManager(this)
    private val _snapshotObserver = OwnerSnapshotObserver { it() }
    override val snapshotObserver get() = _snapshotObserver
    override val viewConfiguration: ViewConfiguration = KlioViewConfiguration
    override val rectManager = RectManager(layoutNodes)

    private val measureAndLayoutDelegate = MeasureAndLayoutDelegate(root)
    override val measureIteration: Long get() = measureAndLayoutDelegate.measureIteration

    private val dragAndDropManagerImpl = object : androidx.compose.ui.draganddrop.DragAndDropManager {
        override val modifier: Modifier = Modifier
        override fun isInterestedTarget(target: androidx.compose.ui.draganddrop.DragAndDropTarget): Boolean = false
        override fun registerTargetInterest(target: androidx.compose.ui.draganddrop.DragAndDropTarget) {}
        override val isRequestDragAndDropTransferRequired: Boolean get() = false
        override fun requestDragAndDropTransfer(node: androidx.compose.ui.draganddrop.DragAndDropNode, offset: Offset) {}
    }
    override val dragAndDropManager: androidx.compose.ui.draganddrop.DragAndDropManager get() = dragAndDropManagerImpl

    init {
        // The state a layout or draw reads invalidates it once changed, as
        // RootNodeOwner's observer does.
        _snapshotObserver.startObserving()
        root.attach(this)
    }

    fun dispose() {
        _snapshotObserver.stopObserving()
        skiaGraphicsContext.dispose()
    }

    /**
     * Whether a layer changed since the owner last drew: a window's loop draws
     * again while it is set, as RootNodeOwner requests a draw.
     */
    var needsDraw: Boolean = true
        private set

    private var lightingSize: IntSize? = null

    /**
     * Places the light the layers' shadows are cast by for a window of this
     * size, as RootNodeOwner does when its container size changes.
     */
    fun setContainerSize(size: IntSize) {
        if (lightingSize == size) return
        lightingSize = size
        skiaGraphicsContext.setLightingInfo(
            canvasOffset = Offset.Zero,
            density = density,
            containerSize = size,
        )
    }

    /** RootNodeOwner's OwnedLayerManagerImpl: the dirty layers, redrawn before the root. */
    private val ownedLayerManager = object : OwnedLayerManager {
        // OwnedLayers that are dirty and should be redrawn.
        private val dirtyLayers = mutableListOf<OwnedLayer>()

        // OwnedLayers that invalidated themselves during their last draw. They are
        // redrawn in the next frame.
        private var postponedDirtyLayers: MutableList<OwnedLayer>? = null

        private var isDrawingContent = false

        override fun createLayer(
            drawBlock: (canvas: Canvas, parentLayer: GraphicsLayer?) -> Unit,
            invalidateParentLayer: () -> Unit,
            explicitLayer: GraphicsLayer?,
        ): OwnedLayer = GraphicsLayerOwnerLayer(
            graphicsLayer = explicitLayer ?: skiaGraphicsContext.createGraphicsLayer(),
            context = if (explicitLayer != null) null else skiaGraphicsContext,
            layerManager = this,
            drawBlock = drawBlock,
            invalidateParentLayer = invalidateParentLayer,
        )

        override fun recycle(layer: OwnedLayer): Boolean {
            dirtyLayers -= layer
            return false
        }

        override fun notifyLayerIsDirty(layer: OwnedLayer, isDirty: Boolean) {
            if (!isDirty) {
                if (!isDrawingContent) {
                    dirtyLayers.remove(layer)
                    postponedDirtyLayers?.remove(layer)
                }
            } else if (!isDrawingContent) {
                dirtyLayers += layer
            } else {
                val postponed =
                    postponedDirtyLayers
                        ?: mutableListOf<OwnedLayer>().also { postponedDirtyLayers = it }
                postponed += layer
            }
        }

        override fun invalidate() {
            needsDraw = true
        }

        fun draw(canvas: Canvas) {
            isDrawingContent = true
            needsDraw = false

            // Drawing forms the frame's render commands, so the display lists
            // are brought up to date before it.
            if (dirtyLayers.isNotEmpty()) {
                for (i in 0 until dirtyLayers.size) {
                    dirtyLayers[i].updateDisplayList()
                }
            }
            dirtyLayers.clear()

            root.draw(canvas = canvas, graphicsLayer = null)

            // Layers invalidated while drawing are redrawn in the next frame.
            postponedDirtyLayers?.let { postponed ->
                if (postponed.isNotEmpty()) needsDraw = true
                dirtyLayers.addAll(postponed)
                postponed.clear()
            }

            isDrawingContent = false
        }
    }

    fun setRootConstraints(constraints: Constraints) {
        measureAndLayoutDelegate.updateRootConstraints(constraints)
    }

    /**
     * What a relayout tells its scene, so the pointer's position is sent again
     * over the moved content: the scene's input handler's onPointerUpdate, as
     * RootNodeOwner is given it.
     */
    var onPointerUpdate: () -> Unit = {}

    fun measureAndLayoutForFrame() {
        measureAndLayoutDelegate.measureAndLayout(onPointerUpdate)
        measureAndLayoutDelegate.dispatchOnPositionedCallbacks()
    }

    fun drawTo(canvas: Canvas) {
        ownedLayerManager.draw(canvas)
    }

    // --- Owner ---------------------------------------------------------------
    override fun onRequestMeasure(
        layoutNode: LayoutNode,
        affectsLookahead: Boolean,
        forceRequest: Boolean,
        scheduleMeasureAndLayout: Boolean,
    ) {
        if (affectsLookahead) measureAndLayoutDelegate.requestLookaheadRemeasure(layoutNode, forceRequest)
        else measureAndLayoutDelegate.requestRemeasure(layoutNode, forceRequest)
    }

    override fun onRequestRelayout(layoutNode: LayoutNode, affectsLookahead: Boolean, forceRequest: Boolean) {
        if (affectsLookahead) measureAndLayoutDelegate.requestLookaheadRelayout(layoutNode, forceRequest)
        else measureAndLayoutDelegate.requestRelayout(layoutNode, forceRequest)
    }

    override fun requestOnPositionedCallback(layoutNode: LayoutNode) {
        measureAndLayoutDelegate.requestOnPositionedCallback(layoutNode)
    }

    override fun onAttach(node: LayoutNode) {}
    override fun onPreAttach(node: LayoutNode) { layoutNodes[node.semanticsId] = node }
    override fun onPostAttach(node: LayoutNode) {}
    override fun onDetach(node: LayoutNode) {
        layoutNodes.remove(node.semanticsId)
        measureAndLayoutDelegate.onNodeDetached(node)
        _snapshotObserver.clear(node)
        rectManager.remove(node)
    }

    override fun measureAndLayout(sendPointerUpdate: Boolean) {
        measureAndLayoutDelegate.measureAndLayout(if (sendPointerUpdate) onPointerUpdate else null)
        measureAndLayoutDelegate.dispatchOnPositionedCallbacks()
    }

    override fun measureAndLayout(layoutNode: LayoutNode, constraints: Constraints) {
        measureAndLayoutDelegate.measureAndLayout(layoutNode, constraints)
        onPointerUpdate()
    }

    // --- input, as RootNodeOwner takes it ------------------------------------

    private val pointerInputEventProcessor = PointerInputEventProcessor(root)

    /** Every owner covers its window, so a position is in bounds within the window. */
    private fun isInBounds(position: Offset): Boolean {
        val size = windowInfo.containerSize
        return position.x >= 0f && position.x < size.width &&
            position.y >= 0f && position.y < size.height
    }

    fun onPointerInput(event: PointerInputEvent): PointerEventResult {
        if (event.button != null) {
            inputModeManager.requestInputMode(InputMode.Touch)
        }
        val isInBounds = event.eventType != PointerEventType.Exit &&
            event.pointers.all { isInBounds(it.position) }
        val result = pointerInputEventProcessor.process(
            event,
            IdentityPositionCalculator,
            isInBounds = isInBounds
        )
        return PointerEventResult(value = result.value)
    }

    fun onCancelPointerInput() {
        pointerInputEventProcessor.processCancel()
    }

    fun onKeyEvent(keyEvent: KeyEvent): Boolean {
        return focusOwner.dispatchKeyEvent(keyEvent) || handleFocusKeys(keyEvent)
    }

    private fun handleFocusKeys(keyEvent: KeyEvent): Boolean {
        val focusDirection = getFocusDirection(keyEvent)
        if (focusDirection == null || keyEvent.type != KeyEventType.KeyDown) return false

        inputModeManager.requestInputMode(InputMode.Keyboard)
        // Consume the key event if we moved focus.
        return focusOwner.moveFocus(focusDirection)
    }

    private fun getFocusDirection(keyEvent: KeyEvent): FocusDirection? {
        return when (keyEvent.key) {
            Key.Tab -> if (keyEvent.isShiftPressed) FocusDirection.Previous else FocusDirection.Next
            Key.DirectionCenter -> FocusDirection.Enter
            Key.Back -> FocusDirection.Exit
            else -> null
        }
    }

    fun onRotaryEvent(event: RotaryScrollEvent): Boolean {
        return focusOwner.dispatchRotaryEvent(event)
    }

    override fun forceMeasureTheSubtree(layoutNode: LayoutNode, affectsLookahead: Boolean) {
        measureAndLayoutDelegate.forceMeasureTheSubtree(layoutNode, affectsLookahead)
    }

    override fun createLayer(
        drawBlock: (Canvas, GraphicsLayer?) -> Unit,
        invalidateParentLayer: () -> Unit,
        explicitLayer: GraphicsLayer?,
    ): OwnedLayer = ownedLayerManager.createLayer(drawBlock, invalidateParentLayer, explicitLayer)

    // RootNodeOwner's text input sessions: a new session cancels the one before
    // it, and an input method request is served until its session ends.
    private val textInputSessionMutex = SessionMutex<TextInputSession>()

    private inner class TextInputSession(
        coroutineScope: CoroutineScope,
    ) : PlatformTextInputSessionScope, CoroutineScope by coroutineScope {
        private val innerSessionMutex = SessionMutex<Nothing?>()

        @OptIn(InternalTextApi::class)
        override suspend fun startInputMethod(request: PlatformTextInputMethodRequest): Nothing {
            innerSessionMutex.withSessionCancellingPrevious<Nothing>(
                sessionInitializer = { null }
            ) {
                coroutineScope {
                    // The legacy TextInputService is started and stopped with the
                    // session, as RootNodeOwner does, for LocalTextInputService's
                    // keyboard show and hide.
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        suspendCancellableCoroutine<Nothing> {
                            textInputService.startInput()
                            it.invokeOnCancellation {
                                textInputService.stopInput()
                            }
                        }
                    }
                    KlioPlatformTextInputService.startInputMethod(request)
                }
            }
        }
    }

    override suspend fun textInputSession(
        session: suspend PlatformTextInputSessionScope.() -> Nothing
    ): Nothing {
        textInputSessionMutex.withSessionCancellingPrevious<Nothing>(
            sessionInitializer = ::TextInputSession,
            session = session
        )
    }

    override fun onSemanticsChange() {}
    override fun onLayoutChange(layoutNode: LayoutNode) {}
    override fun onLayoutNodeDeactivated(layoutNode: LayoutNode) { rectManager.remove(layoutNode) }

    override fun calculatePositionInWindow(localPosition: Offset): Offset = localPosition
    override fun calculateLocalPosition(positionInWindow: Offset): Offset = positionInWindow
    override fun requestAutofill(node: LayoutNode) {}

    private val endApplyChangesListeners = ArrayList<(() -> Unit)?>()
    override fun onEndApplyChanges() {
        _snapshotObserver.clearInvalidObservations()
        while (endApplyChangesListeners.isNotEmpty()) {
            val listener = endApplyChangesListeners.removeAt(0)
            listener?.invoke()
        }
    }

    override fun registerOnEndApplyChangesListener(listener: () -> Unit) {
        if (listener !in endApplyChangesListeners) endApplyChangesListeners.add(listener)
    }

    override fun registerOnLayoutCompletedListener(listener: Owner.OnLayoutCompletedListener) {
        measureAndLayoutDelegate.registerOnLayoutCompletedListener(listener)
    }
}

private object IdentityPositionCalculator : PositionCalculator {
    override fun screenToLocal(positionOnScreen: Offset): Offset = positionOnScreen
    override fun localToScreen(localPosition: Offset): Offset = localPosition
}

// ---------------------------------------------------------------------------
// Provide the CompositionLocals from the owner: ui's own
// ProvideCommonCompositionLocals, inside the scene's (the ones skiko's
// ProvidePlatformCompositionLocals gives a scene's content).
// ---------------------------------------------------------------------------

// Prefetching is a latency optimisation: a lazy layout still composes every item
// it needs on demand. klio has no frame-idle slot to run requests in, so they are
// accepted and dropped.
@OptIn(InternalComposeUiApi::class)
internal object KlioPrefetchScheduler : PlatformPrefetchScheduler {
    override fun scheduleHighPriorityPrefetch(
        request: PlatformPrefetchRequest
    ) {}

    override fun scheduleLowPriorityPrefetch(
        request: PlatformPrefetchRequest
    ) {}
}

/** The defaults of a host without a scene: none. */
private object NoHostDefaults : HostDefaultProvider {
    @Suppress("UNCHECKED_CAST")
    override fun <T> getHostDefault(key: HostDefaultKey<T>): T = null as T
}

@OptIn(InternalComposeUiApi::class)
@Composable
internal fun ProvideKlioCompositionLocals(owner: KlioComposeOwner, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalPlatformPrefetchScheduler provides KlioPrefetchScheduler,
        LocalPlatformWindowInsets provides EmptyPlatformWindowInsets,
        LocalComposeSceneContext provides owner.scene,
        LocalHostDefaultProvider provides (owner.scene?.hostDefaultProvider ?: NoHostDefaults),
    ) {
        ProvideCommonCompositionLocals(owner, KlioUriHandler(), content)
    }
}

// ---------------------------------------------------------------------------
// Headless render entry point.
// ---------------------------------------------------------------------------

/**
 * A host's recomposer and frame clock. Headless, its compositions run on
 * Dispatchers.Unconfined, as an ImageComposeScene's do by default, and each
 * frame is 16.67 ms after the one before; a window's run on its loop's
 * [loop] dispatcher, whose work each frame runs, at the loop's clock.
 */
internal class KlioRecomposerDriver(
    private val loop: androidx.compose.ui.window.KlioLoopDispatcher? = null,
) {
    private val frameClock = BroadcastFrameClock()
    private val effectScope = CoroutineScope(frameClock + (loop ?: Dispatchers.Unconfined))
    val recomposer = Recomposer(effectScope.coroutineContext)
    private val runner = effectScope.launch { recomposer.runRecomposeAndApplyChanges() }

    /** The context effects and the nodes' coroutines run in, with the frame clock. */
    val effectContext: kotlin.coroutines.CoroutineContext get() = effectScope.coroutineContext
    private var frameNanos = 0L

    /** Whether the recomposer has shut down: it was closed and its compositions' effects ended. */
    val isShutDown: Boolean get() = runner.isCompleted

    /** Whether a frame has work: invalidations, frame awaiters or the loop's due work. */
    val hasPendingWork: Boolean
        get() = recomposer.hasPendingWork || frameClock.hasAwaiters || loop?.hasTasks == true

    fun frame(): Boolean {
        loop?.runPending()
        // Writes to the global snapshot since the last frame (a click handler's,
        // or the program's own between frames) invalidate what read them only
        // once they are applied, as skiko's FrameRecomposer applies them at the
        // start of each frame.
        Snapshot.sendApplyNotifications()
        loop?.runPending()
        // Idle fast path: with nothing invalidated and no frame-clock awaiter, a
        // sendFrame only wakes the recomposer's coroutine to find no work — an
        // expensive resume/suspend under the interpreter for zero benefit. Skip it
        // so a static scene between changes costs nothing.
        if (!recomposer.hasPendingWork && !frameClock.hasAwaiters) return false
        val before = recomposer.changeCount
        if (loop != null) frameNanos = loop.nowNanos()
        frameClock.sendFrame(frameNanos)
        loop?.runPending()
        if (loop == null) frameNanos += 16_666_666L
        return recomposer.changeCount != before
    }

    fun close() {
        recomposer.close()
        runner.cancel()
        frameClock.cancel()
    }
}

/**
 * Render [content] through the real androidx.compose.ui engine into a [width] x
 * [height] px PNG at [path] (at [density] px/dp). Returns false if no Skia backend
 * is present. This is klio's `renderComposeScene` equivalent.
 */
/**
 * A headless composition over the real ui engine, klio's analogue of
 * `ImageComposeScene`: compose once, then re-render frames, rasterize to PNG,
 * and send pointer and key input through the scene's input handler and the
 * engine's own hit testing, as ImageComposeScene sends it.
 */
class KlioComposeScene(
    private var width: Int,
    private var height: Int,
    density: Float = 1f,
) {
    private val recomposerDriver = KlioRecomposerDriver()
    private val recomposer = recomposerDriver.recomposer
    internal val owner = KlioComposeOwner(
        Density(density),
        LayoutDirection.Ltr,
        coroutineContext = recomposerDriver.effectContext,
    )
    private val scene = KlioScene(owner, width, height)
    private val composition = Composition(DefaultUiApplier(owner.root), recomposer)

    /** Set (or replace) the scene's content and run the first frame. */
    fun setContent(content: @Composable () -> Unit) {
        scene.onChangeContent()
        composition.setContent {
            ProvideKlioCompositionLocals(owner) { content() }
        }
        frame()
    }

    /** Recompose pending invalidations and run measure + layout. */
    fun frame() {
        scene.performTrampolineDispatch()
        recomposerDriver.frame()
        scene.measureAndLayout(width, height)
    }

    /** Press and release the primary button at ([x], [y]), then run a frame. */
    fun click(x: Float, y: Float) {
        sendPointerEvent(PointerEventType.Press, Offset(x, y))
        sendPointerEvent(PointerEventType.Release, Offset(x, y))
        frame()
    }

    /** Move the mouse to ([x], [y]), then run a frame. */
    fun hover(x: Float, y: Float) {
        sendPointerEvent(PointerEventType.Move, Offset(x, y))
        frame()
    }

    /**
     * Sends a pointer event to the content, as ImageComposeScene's
     * sendPointerEvent: [buttons] and [keyboardModifiers] default to the state
     * the scene tracks from the events before, [button] is the button whose
     * state this event changes.
     */
    fun sendPointerEvent(
        eventType: PointerEventType,
        position: Offset,
        scrollDelta: Offset = Offset(0f, 0f),
        timeMillis: Long = androidx.compose.ui.currentTimeMillis(),
        type: PointerType = PointerType.Mouse,
        buttons: PointerButtons? = null,
        keyboardModifiers: PointerKeyboardModifiers? = null,
        nativeEvent: Any? = null,
        button: PointerButton? = null,
    ) {
        scene.sendPointerEvent(
            eventType,
            position,
            scrollDelta,
            timeMillis,
            type,
            buttons,
            keyboardModifiers,
            nativeEvent,
            button,
        )
    }

    /** Sends an event of several pointers, as ImageComposeScene's sendPointerEvent. */
    @androidx.compose.ui.ExperimentalComposeUiApi
    fun sendPointerEvent(
        eventType: PointerEventType,
        pointers: List<ComposeScenePointer>,
        buttons: PointerButtons = PointerButtons(),
        keyboardModifiers: PointerKeyboardModifiers = PointerKeyboardModifiers(),
        scrollDelta: Offset = Offset(0f, 0f),
        timeMillis: Long = androidx.compose.ui.currentTimeMillis(),
        nativeEvent: Any? = null,
        button: PointerButton? = null,
        scaleGestureFactor: Float = 1f,
        panGestureOffset: Offset = Offset.Zero,
    ) {
        scene.sendPointerEvent(
            eventType,
            pointers,
            buttons,
            keyboardModifiers,
            scrollDelta,
            timeMillis,
            nativeEvent,
            button,
            scaleGestureFactor,
            panGestureOffset,
        )
    }

    /** Sends a key event to the focused content; true when it was consumed. */
    fun sendKeyEvent(event: KeyEvent): Boolean = scene.sendKeyEvent(event)

    fun resize(newWidth: Int, newHeight: Int) {
        width = newWidth
        height = newHeight
        frame()
    }

    /**
     * Renders the current frame into an [ImageBitmap] whose pixels can be read
     * back ([ImageBitmap.toPixelMap]); transparent without a Skia backend.
     */
    fun render(): androidx.compose.ui.graphics.ImageBitmap {
        frame()
        val bitmap = androidx.compose.ui.graphics.ImageBitmap(width, height)
        scene.draw(androidx.compose.ui.graphics.Canvas(bitmap))
        return bitmap
    }

    /** Rasterize the current frame to a PNG. False without a Skia backend. */
    fun renderToPng(path: String): Boolean {
        frame()
        return klioDrawToPng(width, height, path) { scene.draw(this) }
    }

    fun dispose() {
        scene.dispose()
        composition.dispose()
        recomposerDriver.close()
    }
}

fun renderComposeToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    content: @Composable () -> Unit,
): Boolean {
    val recomposerDriver = KlioRecomposerDriver()
    val recomposer = recomposerDriver.recomposer
    val owner = KlioComposeOwner(Density(density), LayoutDirection.Ltr, coroutineContext = recomposerDriver.effectContext)
    val scene = KlioScene(owner, width, height)
    val composition = Composition(DefaultUiApplier(owner.root), recomposer)
    composition.setContent {
        ProvideKlioCompositionLocals(owner) { content() }
    }
    recomposerDriver.frame()
    scene.measureAndLayout(width, height)
    val ok = klioDrawToPng(width, height, path) { scene.draw(this) }
    scene.dispose()
    composition.dispose()
    recomposerDriver.close()
    return ok
}
