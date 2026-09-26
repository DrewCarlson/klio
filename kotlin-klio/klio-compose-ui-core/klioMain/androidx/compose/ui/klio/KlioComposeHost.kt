// klio's hosts over upstream's scene. A klio window and the mobile surface
// give their CanvasLayersComposeScene a KlioPlatformContext (the platform's
// text input, the window's focus and size); the application's own
// composition runs on a KlioRecomposerDriver. KlioComposeScene and
// renderComposeToPng are the headless helpers examples and tests render with,
// over upstream's ImageComposeScene, as the same code runs on Compose Desktop.

package androidx.compose.ui.klio

import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.klioDrawToPng
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.input.pointer.KlioPointerIcon
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.platform.DefaultArchitectureComponentsOwner
import androidx.compose.ui.platform.DefaultInputModeManager
import androidx.compose.ui.platform.PlatformContext
import androidx.compose.ui.platform.PlatformDragAndDropManager
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.compose.ui.platform.WindowInfoImpl
import androidx.compose.ui.scene.ComposeScenePointer
import androidx.compose.ui.text.input.BackspaceCommand
import androidx.compose.ui.text.input.CommitTextCommand
import androidx.compose.ui.text.input.EditCommand
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.Density
import androidx.compose.ui.window.__composeui_hideKeyboard
import androidx.compose.ui.window.__composeui_setTextCallback
import androidx.compose.ui.window.__composeui_showKeyboard
import androidx.compose.ui.window.__composeui_textInput
import androidx.compose.ui.window.__composeui_winSetCursor
import androidx.compose.ui.window.KlioWindowAccessibility
import androidx.compose.ui.window.KlioWindowDragAndDrop
import androidx.compose.ui.window.KlioWindowTextInput
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import org.jetbrains.skiko.currentNanoTime

/**
 * The platform's text input on a mobile surface: the host stages the text of
 * each key the on-screen keyboard sends and calls back with its kind.
 */
@Suppress("DEPRECATION")
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

/**
 * What a klio window's or the mobile surface's scene knows of its platform:
 * the window's focus and size, its lifecycle, view model store and saved
 * state, the input mode, the text input (a desktop window's input method,
 * [windowTextInput], or the mobile platform's keyboard), and a desktop
 * window's accessibility.
 */
@OptIn(InternalComposeUiApi::class)
internal class KlioPlatformContext(
    override val windowInfo: WindowInfoImpl,
    override val architectureComponentsOwner: DefaultArchitectureComponentsOwner,
    val windowTextInput: KlioWindowTextInput? = null,
    /** A desktop window's accessibility, which its semantics owners report to. */
    val windowAccessibility: KlioWindowAccessibility? = null,
    /** A desktop window's handle, whose cursor follows the pointer icon; 0 for a hosted surface. */
    private val windowHandle: Long = 0L,
    /** A desktop window's drag and drop. */
    val windowDragAndDrop: KlioWindowDragAndDrop? = null,
) : PlatformContext {
    override val dragAndDropManager: PlatformDragAndDropManager
        get() = windowDragAndDrop ?: super.dragAndDropManager

    // The window shows the icon's system cursor, as the desktop sets its
    // component's AWT cursor.
    override fun setPointerIcon(pointerIcon: PointerIcon) {
        if (windowHandle != 0L) __composeui_winSetCursor(windowHandle, (pointerIcon as? KlioPointerIcon)?.kind ?: 0)
    }

    override val inputModeManager: InputModeManager = DefaultInputModeManager()

    override val semanticsOwnerListener: PlatformContext.SemanticsOwnerListener?
        get() = windowAccessibility

    @Suppress("DEPRECATION")
    override val textInputService: androidx.compose.ui.text.input.PlatformTextInputService
        get() = windowTextInput ?: KlioPlatformTextInputService

    override suspend fun startInputMethod(request: PlatformTextInputMethodRequest): Nothing =
        windowTextInput?.startInputMethod(request) ?: KlioPlatformTextInputService.startInputMethod(request)
}

/**
 * The application composition's recomposer and frame clock, as desktop's
 * awaitApplication runs its own on the main dispatcher. A window loop's
 * compositions run on the loop's [loop] dispatcher, whose work each frame
 * runs, at the loop's clock; a hosted surface's on Dispatchers.Unconfined.
 */
internal class KlioRecomposerDriver(
    private val loop: androidx.compose.ui.window.KlioLoopDispatcher? = null,
) {
    // A frame awaited from another thread wakes the window loop.
    private val frameClock = BroadcastFrameClock { loop?.wake() }
    private val effectScope = CoroutineScope(frameClock + (loop ?: Dispatchers.Unconfined))
    val recomposer = Recomposer(effectScope.coroutineContext)
    private val runner = effectScope.launch { recomposer.runRecomposeAndApplyChanges() }

    /** The dispatcher the windows' scenes run their frame recomposers on. */
    val dispatcherContext: kotlin.coroutines.CoroutineContext = loop ?: Dispatchers.Unconfined

    private var frameNanos = 0L

    /** Whether the recomposer has shut down: it was closed and its compositions' effects ended. */
    val isShutDown: Boolean get() = runner.isCompleted

    /** Whether a frame has work: invalidations, frame awaiters or the loop's due work. */
    val hasPendingWork: Boolean
        get() = recomposer.hasPendingWork || frameClock.hasAwaiters || loop?.hasTasks == true

    /** Whether the next frame has work: invalidations or frame awaiters. */
    val wantsFrame: Boolean
        get() = recomposer.hasPendingWork || frameClock.hasAwaiters

    /** Runs the loop's queued work and due timers, and applies the snapshot writes made since. */
    fun runTasks() {
        loop?.runPending()
        // Writes to the global snapshot since the last frame (a click handler's,
        // or the program's own between frames) invalidate what read them only
        // once they are applied.
        Snapshot.sendApplyNotifications()
        loop?.runPending()
    }

    fun frame(): Boolean {
        runTasks()
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
 * A headless scene over upstream's [ImageComposeScene]: compose once, then
 * render frames 16.67 ms apart, rasterize them to PNGs, and send pointer and
 * key input, as the same helper does over Compose Desktop's.
 */
class KlioComposeScene(private val width: Int, private val height: Int, density: Float = 1f) {
    private val scene = ImageComposeScene(width, height, Density(density))
    private var nanos = 0L

    private fun nextFrame(): org.jetbrains.skia.Image {
        val image = scene.render(nanos)
        nanos += 16_666_666L
        return image
    }

    /** Set (or replace) the scene's content and render the first frame. */
    fun setContent(content: @Composable () -> Unit) {
        scene.setContent(content)
        nextFrame()
    }

    /** Render the next frame. */
    fun frame() {
        nextFrame()
    }

    /** Render the next frame as an [ImageBitmap] whose pixels can be read back. */
    fun render(): ImageBitmap = nextFrame().toComposeImageBitmap()

    /** Render the next frame to a PNG. False without a Skia backend. */
    fun renderToPng(path: String): Boolean {
        val image = nextFrame().toComposeImageBitmap()
        return klioDrawToPng(width, height, path) { drawImage(image, Offset.Zero, Paint()) }
    }

    /** Press and release the primary button at ([x], [y]), then render a frame. */
    fun click(x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Press, Offset(x, y))
        scene.sendPointerEvent(PointerEventType.Release, Offset(x, y))
        nextFrame()
    }

    /** Move the mouse to ([x], [y]), then render a frame. */
    fun hover(x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Move, Offset(x, y))
        nextFrame()
    }

    fun sendPointerEvent(
        eventType: PointerEventType,
        position: Offset,
        scrollDelta: Offset = Offset(0f, 0f),
        timeMillis: Long = currentNanoTime() / 1_000_000L,
        type: PointerType = PointerType.Mouse,
        buttons: PointerButtons? = null,
        keyboardModifiers: PointerKeyboardModifiers? = null,
        nativeEvent: Any? = null,
        button: PointerButton? = null,
    ) = scene.sendPointerEvent(eventType, position, scrollDelta, timeMillis, type, buttons, keyboardModifiers, nativeEvent, button)

    /** Sends an event of several pointers, as ImageComposeScene's sendPointerEvent. */
    @ExperimentalComposeUiApi
    fun sendPointerEvent(
        eventType: PointerEventType,
        pointers: List<ComposeScenePointer>,
        buttons: PointerButtons = PointerButtons(),
        keyboardModifiers: PointerKeyboardModifiers = PointerKeyboardModifiers(),
        scrollDelta: Offset = Offset(0f, 0f),
        timeMillis: Long = currentNanoTime() / 1_000_000L,
        nativeEvent: Any? = null,
        button: PointerButton? = null,
    ) = scene.sendPointerEvent(eventType, pointers, buttons, keyboardModifiers, scrollDelta, timeMillis, nativeEvent, button)

    /** Sends a key event to the focused content; true when it was consumed. */
    fun sendKeyEvent(event: KeyEvent): Boolean = scene.sendKeyEvent(event)

    fun dispose() = scene.close()
}

/**
 * Renders [content] once into a [width] x [height] px PNG at [path], at
 * [density] px/dp. False without a Skia backend.
 */
fun renderComposeToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    content: @Composable () -> Unit,
): Boolean {
    val scene = ImageComposeScene(width, height, Density(density), content = content)
    val image = scene.render().toComposeImageBitmap()
    scene.close()
    return klioDrawToPng(width, height, path) { drawImage(image, Offset.Zero, Paint()) }
}
