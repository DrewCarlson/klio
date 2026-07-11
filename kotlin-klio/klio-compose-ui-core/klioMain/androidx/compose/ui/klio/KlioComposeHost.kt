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
import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.klioDrawToPng
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.input.InputModeManagerImpl
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.PointerIconService
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputEvent
import androidx.compose.ui.input.pointer.PointerInputEventData
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputEventProcessor
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.PositionCalculator
import androidx.compose.ui.layout.RootMeasurePolicy
import androidx.compose.ui.modifier.ModifierLocalManager
import androidx.compose.ui.node.LayoutNode
import androidx.compose.ui.node.LayoutNodeDrawScope
import androidx.compose.ui.node.OwnedLayer
import androidx.compose.ui.node.Owner
import androidx.compose.ui.node.OwnerSnapshotObserver
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.AccessibilityManager
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalAccessibilityManager
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalClipboardManager
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
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.ViewConfiguration
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.WindowInfoImpl
import androidx.compose.ui.semantics.EmptySemanticsModifier
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.spatial.RectManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.input.TextInputService
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

// ---------------------------------------------------------------------------
// The applier that builds the LayoutNode tree from emitted ComposeNodes.
// ---------------------------------------------------------------------------

internal class KlioUiApplier(root: LayoutNode) : AbstractApplier<LayoutNode>(root) {
    override fun insertTopDown(index: Int, instance: LayoutNode) {
        // no-op: the tree is built bottom-up
    }

    override fun insertBottomUp(index: Int, instance: LayoutNode) {
        current.insertAt(index, instance)
    }

    override fun remove(index: Int, count: Int) {
        current.removeAt(index, count)
    }

    override fun move(from: Int, to: Int, count: Int) {
        current.move(from, to, count)
    }

    override fun onClear() {
        root.removeAll()
    }

    override fun onEndChanges() {
        super.onEndChanges()
        (root.owner as? KlioComposeOwner)?.onEndApplyChanges()
    }
}

// ---------------------------------------------------------------------------
// A direct-draw OwnedLayer: applies the node's placement offset and its
// graphicsLayer transform to the canvas, then replays the node's draw block.
// (No display-list caching; klio draws immediately to a raster surface.)
// ---------------------------------------------------------------------------

internal class KlioOwnedLayer(
    private val drawBlock: (Canvas, GraphicsLayer?) -> Unit,
) : OwnedLayer {
    private var size = IntSize.Zero
    private var position = IntOffset.Zero
    private var translationX = 0f
    private var translationY = 0f
    private var scaleX = 1f
    private var scaleY = 1f
    private var rotationZ = 0f
    private var pivotFractionX = 0.5f
    private var pivotFractionY = 0.5f
    private var clip = false

    override var frameRate: Float = 0f
    override var isFrameRateFromParent: Boolean = false

    override fun updateLayerProperties(scope: androidx.compose.ui.graphics.ReusableGraphicsLayerScope) {
        translationX = scope.translationX
        translationY = scope.translationY
        scaleX = scope.scaleX
        scaleY = scope.scaleY
        rotationZ = scope.rotationZ
        pivotFractionX = scope.transformOrigin.pivotFractionX
        pivotFractionY = scope.transformOrigin.pivotFractionY
        clip = scope.clip
    }

    override fun isInLayer(position: Offset): Boolean = true
    override fun move(position: IntOffset) { this.position = position }
    override fun resize(size: IntSize) { this.size = size }

    override fun drawLayer(canvas: Canvas, parentLayer: GraphicsLayer?) {
        canvas.save()
        canvas.translate(position.x.toFloat(), position.y.toFloat())
        val hasTransform =
            translationX != 0f || translationY != 0f || scaleX != 1f || scaleY != 1f || rotationZ != 0f
        if (hasTransform) {
            val cx = pivotFractionX * size.width
            val cy = pivotFractionY * size.height
            canvas.translate(cx + translationX, cy + translationY)
            if (rotationZ != 0f) canvas.rotate(rotationZ)
            if (scaleX != 1f || scaleY != 1f) canvas.scale(scaleX, scaleY)
            canvas.translate(-cx, -cy)
        }
        if (clip) {
            canvas.clipRect(0f, 0f, size.width.toFloat(), size.height.toFloat())
        }
        drawBlock(canvas, parentLayer)
        canvas.restore()
    }

    override fun updateDisplayList() {}
    override fun invalidate() {}
    override fun destroy() {}
    override fun mapOffset(point: Offset, inverse: Boolean): Offset = point
    override fun mapBounds(rect: androidx.compose.ui.geometry.MutableRect, inverse: Boolean) {}
    override fun reuseLayer(drawBlock: (Canvas, GraphicsLayer?) -> Unit, invalidateParentLayer: () -> Unit) {}
    override fun transform(matrix: Matrix) {}
    override fun inverseTransform(matrix: Matrix) {}
    override val underlyingMatrix: Matrix = Matrix()
}

// ---------------------------------------------------------------------------
// Minimal graphics context. GraphicsLayer compositing is a distinct advanced
// path; the Text/Surface/Button render path does not create graphics layers.
// ---------------------------------------------------------------------------

internal class KlioGraphicsContext : GraphicsContext {
    override fun createGraphicsLayer(): GraphicsLayer =
        throw UnsupportedOperationException("klio: GraphicsLayer compositing not yet supported")

    override fun releaseGraphicsLayer(layer: GraphicsLayer) {}

    override val shadowContext: androidx.compose.ui.graphics.ShadowContext
        get() = throw UnsupportedOperationException("klio: drop-shadow context not yet supported")
}

// ---------------------------------------------------------------------------
// Minimal platform services. These construct and satisfy the CompositionLocals /
// Owner surface; the ones on the render path (density, layout direction, font
// resolver, view configuration, window info, graphics) are fully real.
// ---------------------------------------------------------------------------

internal object KlioHapticFeedback : androidx.compose.ui.hapticfeedback.HapticFeedback {
    override fun performHapticFeedback(hapticFeedbackType: androidx.compose.ui.hapticfeedback.HapticFeedbackType) {}
}

internal object KlioAccessibilityManager : AccessibilityManager {
    override fun calculateRecommendedTimeoutMillis(
        originalTimeoutMillis: Long,
        containsIcons: Boolean,
        containsText: Boolean,
        containsControls: Boolean,
    ): Long = originalTimeoutMillis
}

internal object KlioTextToolbar : TextToolbar {
    override fun showMenu(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
    ) {}

    override fun hide() {}
    override val status: TextToolbarStatus get() = TextToolbarStatus.Hidden
}

internal object KlioClipboard : Clipboard {
    private var entry: androidx.compose.ui.platform.ClipEntry? = null
    override suspend fun getClipEntry(): androidx.compose.ui.platform.ClipEntry? = entry
    override suspend fun setClipEntry(clipEntry: androidx.compose.ui.platform.ClipEntry?) { entry = clipEntry }
    override val nativeClipboard: androidx.compose.ui.platform.NativeClipboard
        get() = throw UnsupportedOperationException("klio: no native clipboard")
}

@Suppress("DEPRECATION")
internal object KlioClipboardManager : ClipboardManager {
    private var text: androidx.compose.ui.text.AnnotatedString? = null
    override fun getText(): androidx.compose.ui.text.AnnotatedString? = text
    override fun setText(annotatedString: androidx.compose.ui.text.AnnotatedString) { text = annotatedString }
}

internal object KlioViewConfiguration : ViewConfiguration {
    override val longPressTimeoutMillis: Long = 500L
    override val doubleTapTimeoutMillis: Long = 300L
    override val doubleTapMinTimeMillis: Long = 40L
    override val touchSlop: Float = 18f
    override val minimumTouchTargetSize: DpSize get() = DpSize(48.dp, 48.dp)
}

internal object KlioSoftwareKeyboardController : androidx.compose.ui.platform.SoftwareKeyboardController {
    override fun show() {}
    override fun hide() {}
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
    override fun startInput(
        value: androidx.compose.ui.text.input.TextFieldValue,
        imeOptions: androidx.compose.ui.text.input.ImeOptions,
        onEditCommand: (List<androidx.compose.ui.text.input.EditCommand>) -> Unit,
        onImeActionPerformed: (androidx.compose.ui.text.input.ImeAction) -> Unit,
    ) {}

    override fun stopInput() {}
    override fun showSoftwareKeyboard() {}
    override fun hideSoftwareKeyboard() {}
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
        override fun sendKeyEvent(keyEvent: androidx.compose.ui.input.key.KeyEvent): Boolean = false
    }

    override val hapticFeedBack = KlioHapticFeedback
    override val inputModeManager: InputModeManager = InputModeManagerImpl(InputMode.Keyboard) { true }
    @Suppress("DEPRECATION")
    override val clipboardManager: ClipboardManager = KlioClipboardManager
    override val clipboard: Clipboard = KlioClipboard
    override val accessibilityManager: AccessibilityManager = KlioAccessibilityManager
    override val graphicsContext: GraphicsContext = KlioGraphicsContext()
    override val textToolbar: TextToolbar = KlioTextToolbar

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
    override val windowInfo: WindowInfo = WindowInfoImpl()

    override val fontLoader: androidx.compose.ui.text.font.Font.ResourceLoader
        get() = throw UnsupportedOperationException("klio: use fontFamilyResolver")
    override val fontFamilyResolver: FontFamily.Resolver = createFontFamilyResolver()

    private var _layoutDirection by mutableStateOf(layoutDirection)
    override val layoutDirection: LayoutDirection get() = _layoutDirection
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

    override val coroutineContext: kotlin.coroutines.CoroutineContext =
        Dispatchers.Unconfined

    init {
        root.attach(this)
    }

    fun setRootConstraints(constraints: Constraints) {
        measureAndLayoutDelegate.updateRootConstraints(constraints)
    }

    fun measureAndLayoutForFrame() {
        measureAndLayoutDelegate.measureAndLayout(null)
        measureAndLayoutDelegate.dispatchOnPositionedCallbacks()
    }

    fun drawTo(canvas: Canvas) {
        root.draw(canvas, null)
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
        measureAndLayoutDelegate.measureAndLayout(null)
        measureAndLayoutDelegate.dispatchOnPositionedCallbacks()
    }

    override fun measureAndLayout(layoutNode: LayoutNode, constraints: Constraints) {
        measureAndLayoutDelegate.measureAndLayout(layoutNode, constraints)
    }

    override fun forceMeasureTheSubtree(layoutNode: LayoutNode, affectsLookahead: Boolean) {
        measureAndLayoutDelegate.forceMeasureTheSubtree(layoutNode, affectsLookahead)
    }

    override fun createLayer(
        drawBlock: (Canvas, GraphicsLayer?) -> Unit,
        invalidateParentLayer: () -> Unit,
        explicitLayer: GraphicsLayer?,
    ): OwnedLayer = KlioOwnedLayer(drawBlock)

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

// ---------------------------------------------------------------------------
// Provide the platform CompositionLocals from the owner (klio's analogue of
// ProvideCommonCompositionLocals — the retain/autofill locals klio does not
// model are omitted).
// ---------------------------------------------------------------------------

@Composable
internal fun ProvideKlioCompositionLocals(owner: KlioComposeOwner, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalDensity provides owner.density,
        LocalLayoutDirection provides owner.layoutDirection,
        LocalFontFamilyResolver providesDefault owner.fontFamilyResolver,
        LocalViewConfiguration provides owner.viewConfiguration,
        LocalWindowInfo provides owner.windowInfo,
        LocalHapticFeedback provides owner.hapticFeedBack,
        LocalInputModeManager provides owner.inputModeManager,
        LocalTextToolbar provides owner.textToolbar,
        LocalClipboardManager provides owner.clipboardManager,
        LocalClipboard provides owner.clipboard,
        LocalAccessibilityManager provides owner.accessibilityManager,
        LocalFocusManager provides owner.focusOwner,
        LocalGraphicsContext provides owner.graphicsContext,
        LocalUriHandler provides (KlioUriHandler() as UriHandler),
        content = content,
    )
}

// ---------------------------------------------------------------------------
// Headless render entry point.
// ---------------------------------------------------------------------------

/**
 * Render [content] through the real androidx.compose.ui engine into a [width] x
 * [height] px PNG at [path] (at [density] px/dp). Returns false if no Skia backend
 * is present. This is klio's `renderComposeScene` equivalent.
 */
/**
 * A headless composition over the real ui engine — klio's analogue of
 * `ImageComposeScene`: compose once, then re-render frames, rasterize to PNG,
 * and dispatch synthetic pointer input through the engine's own hit testing
 * (`PointerInputEventProcessor`), driving `clickable`/`Button` semantics
 * exactly as a native window does.
 */
class KlioComposeScene(
    private var width: Int,
    private var height: Int,
    density: Float = 1f,
) {
    private val recomposer = Recomposer()
    internal val owner = KlioComposeOwner(Density(density), LayoutDirection.Ltr)
    private val composition = Composition(KlioUiApplier(owner.root), recomposer)
    private val pointerProcessor = PointerInputEventProcessor(owner.root)
    private var uptime = 0L

    /** Set (or replace) the scene's content and run the first frame. */
    fun setContent(content: @Composable () -> Unit) {
        composition.setContent {
            ProvideKlioCompositionLocals(owner) { content() }
        }
        frame()
    }

    private object IdentityPositions : PositionCalculator {
        override fun screenToLocal(positionOnScreen: Offset): Offset = positionOnScreen
        override fun localToScreen(localPosition: Offset): Offset = localPosition
    }

    /** Recompose pending invalidations and run measure + layout. */
    fun frame() {
        recomposer.recompose()
        owner.setRootConstraints(Constraints(maxWidth = width, maxHeight = height))
        owner.measureAndLayoutForFrame()
    }

    private fun pointer(x: Float, y: Float, down: Boolean, hover: Boolean) {
        uptime += 8
        val position = Offset(x, y)
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
            IdentityPositions,
        )
    }

    /** Press + release at ([x], [y]) through the engine's hit testing, then re-frame. */
    fun click(x: Float, y: Float) {
        pointer(x, y, down = true, hover = false)
        pointer(x, y, down = false, hover = false)
        frame()
    }

    /** Move the hover pointer to ([x], [y]), then re-frame. */
    fun hover(x: Float, y: Float) {
        pointer(x, y, down = false, hover = true)
        frame()
    }

    fun resize(newWidth: Int, newHeight: Int) {
        width = newWidth
        height = newHeight
        frame()
    }

    /** Rasterize the current frame to a PNG. False without a Skia backend. */
    fun renderToPng(path: String): Boolean {
        frame()
        return klioDrawToPng(width, height, path) { owner.drawTo(this) }
    }

    fun dispose() {
        composition.dispose()
        recomposer.close()
    }
}

fun renderComposeToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    content: @Composable () -> Unit,
): Boolean {
    val recomposer = Recomposer()
    val owner = KlioComposeOwner(Density(density), LayoutDirection.Ltr)
    val composition = Composition(KlioUiApplier(owner.root), recomposer)
    composition.setContent {
        ProvideKlioCompositionLocals(owner) { content() }
    }
    recomposer.recompose()
    owner.setRootConstraints(Constraints(maxWidth = width, maxHeight = height))
    owner.measureAndLayoutForFrame()
    val ok = klioDrawToPng(width, height, path) { owner.drawTo(this) }
    composition.dispose()
    recomposer.close()
    return ok
}
