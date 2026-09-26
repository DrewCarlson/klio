/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// Compose Desktop's window API over klio's native windows (SDL2 / Cocoa /
// Win32 via src/compose_ui): application, Window, DialogWindow and
// singleWindowApplication with desktop's signatures. Each window is a
// CanvasLayersComposeScene with a frame recomposer of its own, as a desktop
// window's scene mediator has, drawn onto the window's Skia surface, whose mouse, key, text
// and focus events reach its content as Compose Desktop sends AWT's
// (KlioWindowInput), and whose WindowState or DialogState follows the native
// window both ways. Desktop's windows are AWT frames; klio's scopes have no
// AWT window to hand out, so WindowScope carries none.

package androidx.compose.ui.window

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.CompositionContext
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCompositionContext
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.klioDrawToSurface
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.util.UpdateEffect
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.klio.KlioPlatformContext
import androidx.compose.ui.klio.KlioRecomposerDriver
import androidx.compose.ui.platform.DefaultArchitectureComponentsOwner
import androidx.compose.ui.platform.FrameRecomposer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.WindowInfoImpl
import androidx.compose.ui.scene.CanvasLayersComposeScene
import androidx.compose.ui.scene.ComposeScene
import androidx.compose.ui.scene.ComposeScenePointer
import androidx.compose.ui.scene.hasInvalidations
import org.jetbrains.skiko.currentNanoTime
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.enableSavedStateHandles
import kotlin.system.exitProcess
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** Opaque white, the background a desktop compose window starts from. */
private val WINDOW_BACKGROUND: Int = 0xFFFFFFFF.toInt()

/** A window's size when its state leaves a dimension unspecified. */
private const val DEFAULT_WIDTH = 800
private const val DEFAULT_HEIGHT = 600

// --- application ---------------------------------------------------------------

/** Receiver scope of an application's content. */
@Stable
interface ApplicationScope {
    /**
     * Close all windows created inside the application and cancel all launched effects
     * (they launch via [LaunchedEffect][androidx.compose.runtime.LaunchedEffect] and
     * [rememberCoroutineScope][androidx.compose.runtime.rememberCoroutineScope]).
     */
    fun exitApplication()
}

/**
 * An application of native windows: its content composition, the loop that
 * drives its frames and input, and its windows. The content stays composed
 * until [exitApplication]; the application ends when the content is gone and
 * its effects are done, as desktop's does.
 */
@OptIn(InternalComposeUiApi::class)
internal class KlioApplication(
    val loop: KlioLoopDispatcher?,
    val driver: KlioRecomposerDriver,
) : ApplicationScope {
    var isOpen by mutableStateOf(true)
    val windows = mutableListOf<KlioWindowHolder>()
    val trays = mutableListOf<KlioTray>()

    override fun exitApplication() {
        isOpen = false
    }

    fun open(
        parent: CompositionContext,
        width: Int,
        height: Int,
        title: String,
        content: @Composable () -> Unit,
    ): KlioWindowHolder? {
        // A hosted (mobile) surface is the OS's size; a desktop window opens at
        // the size asked for.
        val surfaceW = __composeui_surfaceWidth()
        val surfaceH = __composeui_surfaceHeight()
        val hosted = surfaceW > 0 && surfaceH > 0
        val w = if (hosted) surfaceW else width
        val h = if (hosted) surfaceH else height
        val handle = __composeui_winOpen(w, h, title)
        // As the desktop's AWT throws HeadlessException where it cannot show a
        // window, a window that cannot open fails, saying why.
        if (handle == 0L) {
            throw UnsupportedOperationException("A window cannot open: " + __composeui_winOpenError())
        }
        // The window is focused and sized before its content first composes,
        // as a desktop window's is: Popup and Dialog place by its size.
        val components = DefaultArchitectureComponentsOwner().apply { enableSavedStateHandles() }
        val platformContext = KlioPlatformContext(WindowInfoImpl().apply { isWindowFocused = true }, components)
        var holder: KlioWindowHolder? = null
        val invalidate = { holder?.dirty = true }
        val frameRecomposer = FrameRecomposer(driver.dispatcherContext, invalidate)
        val scene = CanvasLayersComposeScene(
            frameRecomposer = frameRecomposer,
            density = Density(1f),
            layoutDirection = LayoutDirection.Ltr,
            size = IntSize(w, h),
            platformContext = platformContext,
            invalidateLayout = invalidate,
            invalidateDraw = invalidate,
        )
        val created = KlioWindowHolder(handle, scene, frameRecomposer, platformContext, w, h, hosted)
        created.resize(w, h)
        created.updateLifecycleState()
        holder = created
        scene.setContent(parent) { content() }
        windows.add(created)
        return created
    }

    fun close(holder: KlioWindowHolder) {
        if (holder.closed) return
        holder.closed = true
        holder.updateLifecycleState()
        __composeui_winClose(holder.handle)
        holder.scene.close()
        holder.frameRecomposer.close()
        windows.remove(holder)
    }
}

/** The application a window composes in. */
internal val LocalKlioApplication = staticCompositionLocalOf<KlioApplication?> { null }

/** The application composition emits no UI nodes of its own. */
private class KlioNoopApplier : AbstractApplier<Unit>(Unit) {
    override fun insertTopDown(index: Int, instance: Unit) {}
    override fun insertBottomUp(index: Int, instance: Unit) {}
    override fun remove(index: Int, count: Int) {}
    override fun move(from: Int, to: Int, count: Int) {}
    override fun onClear() {}
}

/**
 * An entry point for the Compose application: runs [content], whose [Window]s
 * and [DialogWindow]s open native windows, until [ApplicationScope.exitApplication]
 * removes it and its effects end. With [exitProcessOnExit] the process then
 * exits; set it to `false` to run code after the application.
 */
fun application(
    exitProcessOnExit: Boolean = true,
    content: @Composable ApplicationScope.() -> Unit
) {
    val hosted = runApplication(content)
    if (exitProcessOnExit && !hosted) {
        exitProcess(0)
    }
}

/** Launches an application in this scope; the job completes when it ends. */
fun CoroutineScope.launchApplication(
    content: @Composable ApplicationScope.() -> Unit
): Job = launch {
    awaitApplication(content = content)
}

/** Runs an application and returns when it ends. */
suspend fun awaitApplication(
    content: @Composable ApplicationScope.() -> Unit
) {
    runApplication(content)
}

/**
 * Composes [content] and drives it: on a hosted (mobile) surface the OS's
 * frame source does, and this returns true at once; on the desktop the window
 * loop does until the application ends.
 */
private fun runApplication(content: @Composable ApplicationScope.() -> Unit): Boolean {
    val hosted = __composeui_isHosted()
    val loop = if (hosted) null else KlioLoopDispatcher()
    val driver = KlioRecomposerDriver(loop)
    val app = KlioApplication(loop, driver)
    val composition = Composition(KlioNoopApplier(), driver.recomposer)
    composition.setContent {
        if (app.isOpen) {
            CompositionLocalProvider(
                // Resources which are defined at the application level can use
                // density to calculate intrinsicSize.
                LocalDensity provides Density(1f),
                LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalKlioApplication provides app,
            ) {
                app.content()
            }
        }
    }
    if (hosted) {
        // The platform's frame source (e.g. iOS CADisplayLink) calls back once
        // per vsync on the resident interpreter, which keeps the application
        // alive.
        __composeui_setFrameCallback { frameHosted(app) }
        __composeui_setInputCallback { phase -> inputHosted(app, phase) }
        return true
    }
    // The recomposer shuts down once the content is gone and its effects end.
    driver.recomposer.close()
    while (!driver.isShutDown) {
        // State invalidated by effects or events marks every window for redraw.
        if (driver.frame()) {
            for (win in app.windows) win.dirty = true
        }
        val live = app.windows.toList()
        for (win in live) {
            if (win.needsRender) renderWindowFrame(win)
        }
        val timeout = loopTimeout(loop, driver, FRAME_MILLIS.toInt())
        if (live.isEmpty()) {
            // No window to wait on: wait for the loop's next timer, or a frame,
            // running the platform's events for the trays meanwhile.
            if (!driver.hasPendingWork) {
                if (app.trays.isEmpty()) runBlocking { delay(timeout.toLong()) }
                else __composeui_appWait(timeout)
            }
        } else {
            for (win in live) {
                if (win.closed) continue
                if (pumpWindow(win, timeout, app.blockerOf(win))) win.dirty = true
            }
        }
        for (tray in app.trays.toList()) tray.poll()
    }
    for (win in app.windows.toList()) app.close(win)
    composition.dispose()
    driver.close()
    return false
}

/**
 * How long a window loop waits for input: no longer than [cap], than the
 * loop's next timer, or than a frame while one is awaited.
 */
private fun loopTimeout(loop: KlioLoopDispatcher?, driver: KlioRecomposerDriver, cap: Int): Int {
    var timeout = cap.toLong()
    loop?.millisToNextTimer()?.let { timeout = minOf(timeout, it) }
    if (driver.hasPendingWork) timeout = minOf(timeout, FRAME_MILLIS)
    return timeout.toInt()
}

/** A frame's length at 60 frames a second, in whole milliseconds. */
private const val FRAME_MILLIS = 16L

// --- windows -------------------------------------------------------------------

/** Receiver scope of a window's content. */
@Stable
interface WindowScope

/** Receiver scope which is used by [Window]. */
@Stable
interface FrameWindowScope : WindowScope

/** Receiver scope for [singleWindowApplication]. */
@Stable
interface SingleWindowApplicationScope : ApplicationScope, FrameWindowScope

@Composable
internal fun SingleWindowApplicationScope(
    applicationScope: ApplicationScope,
    windowScope: FrameWindowScope
): SingleWindowApplicationScope {
    return remember(applicationScope, windowScope) {
        object : SingleWindowApplicationScope,
            ApplicationScope by applicationScope,
            FrameWindowScope by windowScope {}
    }
}

/** Receiver scope which is used by [DialogWindow]. */
@Stable
interface DialogWindowScope : WindowScope

/**
 * Modal dialogs block all input to some windows.
 *
 * [DialogModalityType] defines the which set of windows input is blocked to.
 */
@ExperimentalComposeUiApi
class DialogModalityType private constructor(val name: String) {
    override fun toString() = name

    companion object {
        /**
         * Indicates the dialog should be non-modal, i.e., should not block any windows.
         */
        val Modeless = DialogModalityType("Modeless")

        /**
         * Indicates the dialog should block windows from the same document, except its own
         * descendants.
         *
         * A document is a top-level window without an owner.
         */
        val DocumentModal = DialogModalityType("Document")

        /**
         * Indicates the dialog should block windows from the same application.
         */
        val ApplicationModal = DialogModalityType("Application")
    }
}

/**
 * One native window: its scene and frame recomposer, what its composable last
 * applied, and the input and state callbacks the composable keeps current.
 */
@OptIn(InternalComposeUiApi::class)
internal class KlioWindowHolder(
    val handle: Long,
    val scene: ComposeScene,
    val frameRecomposer: FrameRecomposer,
    val platformContext: KlioPlatformContext,
    /** The content area's size, which the scene lays out at. */
    var w: Int,
    var h: Int,
    /** Whether the OS's surface sizes the window (mobile). */
    val hosted: Boolean,
) {
    /** Whether an input event or a state change asks for the next frame. */
    var dirty: Boolean = true

    /** Whether the window draws a frame: it was asked to, or its scene has work. */
    val needsRender: Boolean
        get() = dirty || scene.hasInvalidations() || frameRecomposer.hasPendingWork()

    /** The content area is [width] x [height]: the scene lays out and the window info reports it. */
    fun resize(width: Int, height: Int) {
        w = width
        h = height
        val size = IntSize(width, height)
        platformContext.windowInfo.containerSize = size
        platformContext.windowInfo.containerDpSize = with(scene.density) { DpSize(width.toDp(), height.toDp()) }
        scene.size = size
        dirty = true
    }

    /** Whether the window is minimized, as its placement events report. */
    var isMinimized: Boolean = false

    /**
     * The window's lifecycle, as a desktop window's: destroyed once closed,
     * created while minimized, resumed while focused, and started otherwise.
     */
    fun updateLifecycleState() {
        platformContext.architectureComponentsOwner.setLifecycleState(
            when {
                closed -> Lifecycle.State.DESTROYED
                isMinimized -> Lifecycle.State.CREATED
                platformContext.windowInfo.isWindowFocused -> Lifecycle.State.RESUMED
                else -> Lifecycle.State.STARTED
            }
        )
    }

    var closed: Boolean = false
    var onCloseRequest: () -> Unit = {}

    /**
     * The window whose content composed this one: a dialog's owner. Its
     * native window opens after its content first composes, so it is read
     * through its ref.
     */
    var parentRef: WindowRef? = null
    val parentWindow: KlioWindowHolder? get() = parentRef?.holder

    /** A dialog's modality; null for a window. */
    var modality: DialogModalityType? = null

    /** Whether the window's unpainted pixels are see-through. */
    var transparent: Boolean = false
    val input = KlioWindowInput(scene, platformContext.windowInfo).also { input ->
        input.menuShortcut = { event -> menuBar?.shortcut(event) ?: false }
        input.onFocusChanged = { updateLifecycleState() }
    }

    /** The window state this window follows and reports to. */
    var state: KlioWindowStateAccess? = null

    // What the composable last applied to the native window, so it applies a
    // property only when it changes. The state's are desktop's appliedState:
    // what the window last took from the state or reported to it, so a
    // reported change is not sent back.
    var title: String? = null
    var visible: Boolean? = null
    var resizable: Boolean? = null
    var decorated: Boolean? = null
    var alwaysOnTop: Boolean? = null
    var menuBar: KlioMenuBar? = null
    var icon: Painter? = null
    var iconApplied: Boolean = false
    var appliedSize: DpSize? = null
    var appliedPosition: WindowPosition? = null
    var appliedPlacement: WindowPlacement? = null
    var appliedMinimized: Boolean? = null
}

/** The size, position and placement a window follows: a WindowState's or a DialogState's. */
internal interface KlioWindowStateAccess {
    var size: DpSize
    var position: WindowPosition
    var placement: WindowPlacement
    var isMinimized: Boolean
}

private class WindowStateAccess(val state: WindowState) : KlioWindowStateAccess {
    override var size: DpSize
        get() = state.size
        set(value) { state.size = value }
    override var position: WindowPosition
        get() = state.position
        set(value) { state.position = value }
    override var placement: WindowPlacement
        get() = state.placement
        set(value) { state.placement = value }
    override var isMinimized: Boolean
        get() = state.isMinimized
        set(value) { state.isMinimized = value }
}

/** A dialog has no placement: it is always floating and never minimized. */
private class DialogStateAccess(val state: DialogState) : KlioWindowStateAccess {
    override var size: DpSize
        get() = state.size
        set(value) { state.size = value }
    override var position: WindowPosition
        get() = state.position
        set(value) { state.position = value }
    override var placement: WindowPlacement
        get() = WindowPlacement.Floating
        set(_) {}
    override var isMinimized: Boolean
        get() = false
        set(_) {}
}

/**
 * Composes a platform window in the current composition. When Window enters
 * the composition, a new platform window is created and receives the focus;
 * when it leaves, the window is closed. Its size, position and placement
 * follow [state] and are reported back to it; the close button calls
 * [onCloseRequest] and leaves the window open.
 */
@Composable
fun Window(
    onCloseRequest: () -> Unit,
    state: WindowState = rememberWindowState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    undecorated: Boolean = false,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    onPreviewKeyEvent: (KeyEvent) -> Boolean = { false },
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    content: @Composable FrameWindowScope.() -> Unit
) {
    @OptIn(ExperimentalComposeUiApi::class)
    Window(
        onCloseRequest = onCloseRequest,
        state = state,
        visible = visible,
        title = title,
        icon = icon,
        decoration = windowDecorationFromFlag(undecorated),
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        content = content,
    )
}

/** [Window] with its decoration given as a [WindowDecoration]. */
@ExperimentalComposeUiApi
@Composable
fun Window(
    onCloseRequest: () -> Unit,
    state: WindowState = rememberWindowState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    decoration: WindowDecoration,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    onPreviewKeyEvent: (KeyEvent) -> Boolean = { false },
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    content: @Composable FrameWindowScope.() -> Unit
) {
    val scope = remember { object : FrameWindowScope {} }
    KlioPlatformWindow(
        scope = scope,
        access = remember(state) { WindowStateAccess(state) },
        onCloseRequest = onCloseRequest,
        visible = visible,
        title = title,
        icon = icon,
        decoration = decoration,
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        content = content,
    )
}

/**
 * Composes a platform dialog window in the current composition, as [Window]
 * does a frame. klio's dialogs block no other window.
 */
@Composable
fun DialogWindow(
    onCloseRequest: () -> Unit,
    state: DialogState = rememberDialogState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    undecorated: Boolean = false,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    onPreviewKeyEvent: ((KeyEvent) -> Boolean) = { false },
    onKeyEvent: ((KeyEvent) -> Boolean) = { false },
    content: @Composable DialogWindowScope.() -> Unit
) {
    @OptIn(ExperimentalComposeUiApi::class)
    DialogWindow(
        onCloseRequest = onCloseRequest,
        state = state,
        visible = visible,
        title = title,
        icon = icon,
        decoration = windowDecorationFromFlag(undecorated),
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        modalityType = DialogModalityType.DocumentModal,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        content = content,
    )
}

/** [DialogWindow] with its decoration and modality given. */
@ExperimentalComposeUiApi
@Composable
fun DialogWindow(
    onCloseRequest: () -> Unit,
    state: DialogState = rememberDialogState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    decoration: WindowDecoration = WindowDecoration.SystemDefault,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    modalityType: DialogModalityType,
    onPreviewKeyEvent: ((KeyEvent) -> Boolean) = { false },
    onKeyEvent: ((KeyEvent) -> Boolean) = { false },
    content: @Composable DialogWindowScope.() -> Unit
) {
    val scope = remember { object : DialogWindowScope {} }
    KlioPlatformWindow(
        scope = scope,
        access = remember(state) { DialogStateAccess(state) },
        onCloseRequest = onCloseRequest,
        visible = visible,
        title = title,
        icon = icon,
        decoration = decoration,
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        modality = modalityType,
        content = content,
    )
}

/**
 * An entry point for applications that only need a single top-level window:
 * [application] with one [Window], which closing exits.
 */
fun singleWindowApplication(
    state: WindowState = WindowState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    undecorated: Boolean = false,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    onPreviewKeyEvent: (KeyEvent) -> Boolean = { false },
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    exitProcessOnExit: Boolean = true,
    content: @Composable SingleWindowApplicationScope.() -> Unit
) {
    @OptIn(ExperimentalComposeUiApi::class)
    singleWindowApplication(
        state = state,
        visible = visible,
        title = title,
        icon = icon,
        decoration = windowDecorationFromFlag(undecorated),
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        exitProcessOnExit = exitProcessOnExit,
        content = content,
    )
}

/** [singleWindowApplication] with its window's decoration given. */
@ExperimentalComposeUiApi
fun singleWindowApplication(
    state: WindowState = WindowState(),
    visible: Boolean = true,
    title: String = "Untitled",
    icon: Painter? = null,
    decoration: WindowDecoration,
    transparent: Boolean = false,
    resizable: Boolean = true,
    enabled: Boolean = true,
    focusable: Boolean = true,
    alwaysOnTop: Boolean = false,
    onPreviewKeyEvent: (KeyEvent) -> Boolean = { false },
    onKeyEvent: (KeyEvent) -> Boolean = { false },
    exitProcessOnExit: Boolean = true,
    content: @Composable SingleWindowApplicationScope.() -> Unit
) = application(exitProcessOnExit = exitProcessOnExit) {
    Window(
        onCloseRequest = ::exitApplication,
        state = state,
        visible = visible,
        title = title,
        icon = icon,
        decoration = decoration,
        transparent = transparent,
        resizable = resizable,
        enabled = enabled,
        focusable = focusable,
        alwaysOnTop = alwaysOnTop,
        onPreviewKeyEvent = onPreviewKeyEvent,
        onKeyEvent = onKeyEvent,
        content = {
            with(SingleWindowApplicationScope(this@application, this@Window)) {
                content()
            }
        }
    )
}

/**
 * The native window a [Window] or [DialogWindow] composes: opened at its
 * state's size and position, kept to its properties and state as they change,
 * and reporting the user's resizes, moves and placement changes to the state.
 * As desktop's AwtWindow does, the window is created and its content set when
 * the composition applies, not while it composes, and its properties are
 * applied through [UpdateEffect], again whenever what they read changes; the
 * effect's coroutine keeps the application running while the window is open.
 */
@Composable
private fun <S : WindowScope> KlioPlatformWindow(
    scope: S,
    access: KlioWindowStateAccess,
    onCloseRequest: () -> Unit,
    visible: Boolean,
    title: String,
    icon: Painter?,
    decoration: WindowDecoration,
    transparent: Boolean,
    resizable: Boolean,
    enabled: Boolean,
    focusable: Boolean,
    alwaysOnTop: Boolean,
    onPreviewKeyEvent: (KeyEvent) -> Boolean,
    onKeyEvent: (KeyEvent) -> Boolean,
    modality: DialogModalityType? = null,
    content: @Composable S.() -> Unit,
) {
    check(!transparent || decoration != WindowDecoration.SystemDefault) {
        "Transparent window should be undecorated!"
    }
    val app = checkNotNull(LocalKlioApplication.current) {
        "A window is composed inside application { }"
    }
    val parent = rememberCompositionContext()
    // The window whose content composes this one, as a dialog's owner is.
    val parentWindow = LocalKlioWindowRef.current
    val currentContent by rememberUpdatedState(content)
    val currentTitle by rememberUpdatedState(title)
    val currentAccess by rememberUpdatedState(access)
    val windowRef = remember { WindowRef() }
    DisposableEffect(Unit) {
        val size = currentAccess.size
        val holder = app.open(
            parent,
            if (size.width.isSpecified) size.width.value.toInt() else DEFAULT_WIDTH,
            if (size.height.isSpecified) size.height.value.toInt() else DEFAULT_HEIGHT,
            currentTitle,
        ) {
            CompositionLocalProvider(LocalKlioWindowRef provides windowRef) {
                scope.currentContent()
            }
        }
        windowRef.holder = holder
        holder?.parentRef = parentWindow
        holder?.modality = modality
        if (holder != null && transparent) {
            holder.transparent = true
            __composeui_winSetFlag(holder.handle, WIN_TRANSPARENT, 1)
        }
        onDispose {
            if (holder != null) app.close(holder)
            windowRef.holder = null
        }
    }
    UpdateEffect {
        val holder = windowRef.holder ?: return@UpdateEffect
        holder.onCloseRequest = onCloseRequest
        holder.state = access
        holder.input.enabled = enabled
        holder.input.focusable = focusable
        holder.input.onPreviewKeyEvent = onPreviewKeyEvent
        holder.input.onKeyEvent = onKeyEvent
        applyWindowProperties(holder, title, visible, resizable, decoration, alwaysOnTop)
        applyWindowIcon(holder, icon)
        applyWindowState(holder, access.size, access.position, access.placement, access.isMinimized)
    }
}

/**
 * The native window a window composable made, once the composition applied
 * it, and the menu bar its content gives it.
 */
internal class WindowRef {
    var holder: KlioWindowHolder? = null
        set(value) {
            field = value
            value?.menuBar = menuBar
            menuBar?.sink = value?.let(::WindowMenuSink)
        }

    var menuBar: KlioMenuBar? = null
        set(value) {
            if (field === value) return
            field?.detach()
            field = value
            holder?.menuBar = value
            value?.sink = holder?.let(::WindowMenuSink)
        }
}

private fun applyWindowProperties(
    holder: KlioWindowHolder,
    title: String,
    visible: Boolean,
    resizable: Boolean,
    decoration: WindowDecoration,
    alwaysOnTop: Boolean,
) {
    if (holder.title != title) {
        holder.title = title
        __composeui_winSetTitle(holder.handle, title)
    }
    if (holder.hosted) return
    val decorated = decoration == WindowDecoration.SystemDefault
    if (holder.resizable != resizable) {
        // A window opens resizable.
        if (holder.resizable != null || !resizable) {
            __composeui_winSetFlag(holder.handle, WIN_RESIZABLE, if (resizable) 1 else 0)
        }
        holder.resizable = resizable
    }
    if (holder.decorated != decorated) {
        // A window opens decorated.
        if (holder.decorated != null || !decorated) {
            __composeui_winSetFlag(holder.handle, WIN_DECORATED, if (decorated) 1 else 0)
        }
        holder.decorated = decorated
    }
    if (holder.alwaysOnTop != alwaysOnTop) {
        if (holder.alwaysOnTop != null || alwaysOnTop) {
            __composeui_winSetFlag(holder.handle, WIN_ALWAYS_ON_TOP, if (alwaysOnTop) 1 else 0)
        }
        holder.alwaysOnTop = alwaysOnTop
    }
    if (holder.visible != visible) {
        // A window opens shown.
        if (holder.visible != null || !visible) {
            __composeui_winSetFlag(holder.handle, WIN_VISIBLE, if (visible) 1 else 0)
        }
        holder.visible = visible
    }
}

/**
 * A window's icon, as the desktop sets it: the painter drawn at 192 by 192
 * pixels (a size for painters with none of their own). A macOS window has no
 * icon of its own, so there it changes nothing.
 */
private fun applyWindowIcon(holder: KlioWindowHolder, icon: Painter?) {
    if (holder.iconApplied && holder.icon === icon) return
    holder.iconApplied = true
    holder.icon = icon
    if (icon == null || holder.hosted) return
    val surface = __composeui_iconSurface(ICON_SIZE, ICON_SIZE)
    if (surface == 0L) return
    val size = Size(ICON_SIZE.toFloat(), ICON_SIZE.toFloat())
    klioDrawToSurface(surface) {
        CanvasDrawScope().draw(holder.scene.density, LayoutDirection.Ltr, this, size) {
            with(icon) { draw(size) }
        }
    }
    __composeui_winSetIconSurface(holder.handle, surface)
    __composeui_iconSurfaceFree(surface)
}

private const val ICON_SIZE = 192

private fun applyWindowState(
    holder: KlioWindowHolder,
    size: DpSize,
    position: WindowPosition,
    placement: WindowPlacement,
    minimized: Boolean,
) {
    if (holder.hosted) return
    if (size != holder.appliedSize) {
        __composeui_winSetFrameSize(
            holder.handle,
            if (size.width.isSpecified) size.width.value.toInt() else DEFAULT_WIDTH,
            if (size.height.isSpecified) size.height.value.toInt() else DEFAULT_HEIGHT,
        )
        holder.appliedSize = size
    }
    if (position != holder.appliedPosition) {
        val target = when (position) {
            is WindowPosition.Absolute -> IntOffset(position.x.value.toInt(), position.y.value.toInt())
            is WindowPosition.Aligned -> {
                val packed = __composeui_winFrameSize(holder.handle)
                val frame = IntSize((packed shr 32).toInt(), packed.toInt())
                val screen = IntOffset(__composeui_screenBounds(0), __composeui_screenBounds(1))
                val screenSize = IntSize(__composeui_screenBounds(2), __composeui_screenBounds(3))
                screen + position.alignment.align(frame, screenSize, LayoutDirection.Ltr)
            }
            // The platform's own place, where the window opened.
            else -> null
        }
        if (target != null) __composeui_winSetPosition(holder.handle, target.x, target.y)
        holder.appliedPosition = position
    }
    if (placement != holder.appliedPlacement) {
        __composeui_winSetFlag(holder.handle, WIN_PLACEMENT, placement.ordinal)
        holder.appliedPlacement = placement
    }
    if (minimized != holder.appliedMinimized) {
        __composeui_winSetFlag(holder.handle, WIN_MINIMIZED, if (minimized) 1 else 0)
        holder.appliedMinimized = minimized
    }
}

/**
 * The window moved, was resized, or changed placement: the state takes the
 * window's own values, as desktop's component and window state listeners
 * give them.
 */
private fun reportFrame(holder: KlioWindowHolder, type: Int, v: DoubleArray) {
    if (type == WINDOW_EVENT_PLACEMENT) {
        holder.isMinimized = v[1] != 0.0
        holder.updateLifecycleState()
    }
    val state = holder.state ?: return
    when (type) {
        WINDOW_EVENT_RESIZE -> {
            val packed = __composeui_winFrameSize(holder.handle)
            val width = (packed shr 32).toInt()
            val height = packed.toInt()
            if (width > 0 && height > 0) {
                state.size = DpSize(width.dp, height.dp)
                holder.appliedSize = state.size
            }
        }
        WINDOW_EVENT_MOVE -> {
            state.position = WindowPosition(v[0].toInt().dp, v[1].toInt().dp)
            holder.appliedPosition = state.position
        }
        WINDOW_EVENT_PLACEMENT -> {
            state.placement = WindowPlacement.entries.getOrElse(v[0].toInt()) { WindowPlacement.Floating }
            state.isMinimized = v[1] != 0.0
            holder.appliedPlacement = state.placement
            holder.appliedMinimized = state.isMinimized
        }
    }
}

/**
 * One frame of a window, as a desktop window's scene renders one: the frame
 * recomposer's frame, then measure and layout, then the draw onto the
 * window's surface.
 */
@OptIn(InternalComposeUiApi::class)
private fun renderWindowFrame(holder: KlioWindowHolder) {
    // What this frame invalidates asks for the next one.
    holder.dirty = false
    holder.frameRecomposer.performFrame(currentNanoTime())
    holder.scene.measureAndLayout()
    val surface = __composeui_winSurface(holder.handle)
    if (surface == 0L) return
    // Desktop windows start white: content that draws no background of its
    // own (the default LocalContentColor is black) stays readable. A
    // transparent window starts clear, as the desktop's has no background.
    __composeui_winClear(holder.handle, if (holder.transparent) 0 else WINDOW_BACKGROUND)
    klioDrawToSurface(surface) { holder.scene.draw(this) }
    __composeui_winPresent(holder.handle)
}

/** The values of the event a window's poll last reported. */
private val windowEventValues = DoubleArray(WINDOW_EVENT_VALUES)

/**
 * The modal dialog that blocks [win]'s input, as AWT's modality has it: an
 * application-modal dialog blocks every window, a document-modal one the
 * windows of its document (the windows under the same top-level window), and
 * neither blocks its own descendants. Null when nothing blocks it.
 */
internal fun KlioApplication.blockerOf(win: KlioWindowHolder): KlioWindowHolder? {
    for (dialog in windows) {
        if (dialog === win || dialog.closed || dialog.visible == false) continue
        val modality = dialog.modality ?: continue
        if (modality == DialogModalityType.Modeless || win.isDescendantOf(dialog)) continue
        if (modality == DialogModalityType.ApplicationModal) return dialog
        if (win.documentRoot() === dialog.documentRoot()) return dialog
    }
    return null
}

private fun KlioWindowHolder.documentRoot(): KlioWindowHolder {
    var w = this
    while (true) w = w.parentWindow ?: return w
}

private fun KlioWindowHolder.isDescendantOf(ancestor: KlioWindowHolder): Boolean {
    var w = parentWindow
    while (w != null) {
        if (w === ancestor) return true
        w = w.parentWindow
    }
    return false
}

/**
 * Whether a blocked window drops an event: its pointer, key, text and menu
 * input, and its gaining focus. A press or a focus gained on it brings the
 * dialog that blocks it to the front instead, as the platforms' modal dialogs
 * come forward.
 */
private fun dropsBlocked(blocker: KlioWindowHolder, type: Int, v: DoubleArray): Boolean {
    val forward = when (type) {
        WINDOW_EVENT_POINTER -> v[0].toInt() == 1
        WINDOW_EVENT_FOCUS -> v[0] != 0.0
        WINDOW_EVENT_KEY, WINDOW_EVENT_TEXT, WINDOW_EVENT_MENU -> false
        else -> return false
    }
    if (forward) __composeui_winSetFlag(blocker.handle, WIN_FRONT, 1)
    return true
}

/** Drain one window's pending events; returns true when anything arrived. */
private fun pumpWindow(holder: KlioWindowHolder, timeoutMs: Int, blocker: KlioWindowHolder?): Boolean {
    var any = false
    val onResize: (Int, Int) -> Unit = { nw, nh ->
        holder.resize(nw, nh)
        renderWindowFrame(holder)
    }
    var timeout = timeoutMs
    while (!holder.closed) {
        val type = __composeui_winPollEvent(holder.handle, timeout, onResize, windowEventValues)
        timeout = 0
        if (type == WINDOW_EVENT_NONE) break
        any = true
        if (blocker != null && dropsBlocked(blocker, type, windowEventValues)) continue
        when (type) {
            WINDOW_EVENT_CLOSE -> holder.onCloseRequest()
            WINDOW_EVENT_RESIZE -> {
                holder.resize(windowEventValues[0].toInt(), windowEventValues[1].toInt())
                reportFrame(holder, type, windowEventValues)
            }
            WINDOW_EVENT_MOVE, WINDOW_EVENT_PLACEMENT -> reportFrame(holder, type, windowEventValues)
            WINDOW_EVENT_MENU -> {
                holder.menuBar?.perform(windowEventValues[0].toInt())
                holder.dirty = true
            }
            else -> {
                holder.input.send(type, windowEventValues)
                holder.dirty = true
            }
        }
    }
    return any
}

// --- hosted (mobile) surfaces --------------------------------------------------

/**
 * One frame under an OS-driven frame source: advance recomposition and redraw
 * every live window. Called by the platform's frame callback (not a loop);
 * returns whether the next frame is needed.
 */
private fun frameHosted(app: KlioApplication): Boolean {
    val changed = app.driver.frame()
    if (changed) {
        for (win in app.windows) win.dirty = true
    }
    val live = app.windows.toList()
    if (live.isEmpty()) return false
    // Redraw only windows with pending work (a recomposition this vsync, or an
    // input event marked them dirty), like the desktop loop.
    for (win in live) if (win.needsRender) renderWindowFrame(win)
    // Report whether the VM still needs the next frame: pending recomposition /
    // effects, or a window left un-rendered (e.g. no surface yet). When false the
    // OS frame source can skip re-entering the VM until input or a periodic pump.
    return app.driver.recomposer.hasPendingWork || live.any { it.needsRender }
}

/**
 * Dispatch the current hosted (mobile) multi-touch snapshot into every live
 * window's scene. The host holds the snapshot; this reads it back as one
 * [ComposeScenePointer] per active finger (each with its stable [PointerId])
 * so gestures spanning several fingers (drag, pinch, multi-tap) resolve.
 * [phase] is the primary event type (0=down, 1=move, 2=up, 3=cancel, 4=scroll);
 * positions are in the window's point coordinate space. The redraw happens on
 * the next frame callback (the pointer only marks the window dirty).
 */
private fun inputHosted(app: KlioApplication, phase: Int) {
    val n = __composeui_touchCount()
    if (n <= 0) return
    val eventType = when (phase) {
        0 -> PointerEventType.Press
        1 -> PointerEventType.Move
        4 -> PointerEventType.Scroll
        else -> PointerEventType.Release
    }
    val scrollDelta = if (phase == 4)
        Offset(__composeui_touchScrollX(0).toFloat(), __composeui_touchScrollY(0).toFloat())
    else Offset.Zero
    for (holder in app.windows.toList()) {
        val pointers = ArrayList<ComposeScenePointer>(n)
        for (i in 0 until n) {
            pointers.add(
                ComposeScenePointer(
                    id = PointerId(__composeui_touchId(i).toLong()),
                    position = Offset(__composeui_touchX(i).toFloat(), __composeui_touchY(i).toFloat()),
                    pressed = __composeui_touchDown(i),
                    type = PointerType.Touch,
                ),
            )
        }
        holder.scene.sendPointerEvent(eventType, pointers, scrollDelta = scrollDelta)
        holder.dirty = true
    }
}

// --- Host intrinsics (bound by FQN) --------------------------------------------

/** What `__composeui_winSetFlag` sets (window_events.h's KLIO_WIN_*). */
private const val WIN_RESIZABLE = 0
private const val WIN_DECORATED = 1
private const val WIN_ALWAYS_ON_TOP = 2
private const val WIN_VISIBLE = 3
private const val WIN_MINIMIZED = 4
private const val WIN_PLACEMENT = 5
private const val WIN_FRONT = 6
private const val WIN_TRANSPARENT = 7

// Sets one of a window's properties (WIN_*).
internal fun __composeui_winSetFlag(handle: Long, which: Int, value: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetFlag not installed")

// Moves the window frame's top-left to (x, y) on the screen.
internal fun __composeui_winSetPosition(handle: Long, x: Int, y: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetPosition not installed")

// The window frame's top-left: x in the high 32 bits, y in the low.
internal fun __composeui_winPosition(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winPosition not installed")

// Resizes the window's frame, title bar and border included.
internal fun __composeui_winSetFrameSize(handle: Long, width: Int, height: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetFrameSize not installed")

// The window frame's size: width in the high 32 bits, height in the low.
internal fun __composeui_winFrameSize(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winFrameSize not installed")

// A surface for drawing a window's icon, and freeing it.
internal fun __composeui_iconSurface(width: Int, height: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_iconSurface not installed")

internal fun __composeui_iconSurfaceFree(surface: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_iconSurfaceFree not installed")

// Sets a window's icon from the surface its painter was drawn on.
internal fun __composeui_winSetIconSurface(handle: Long, surface: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetIconSurface not installed")

// The main screen's area for windows: which 0 x, 1 y, 2 width, 3 height.
internal fun __composeui_screenBounds(which: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_screenBounds not installed")

internal fun __composeui_winOpen(width: Int, height: Int, title: String): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winOpen not installed")

// Why the last __composeui_winOpen answered 0.
internal fun __composeui_winOpenError(): String =
    error("intrinsic androidx.compose.ui.window.__composeui_winOpenError not installed")

// Waits up to timeoutMs for the window's next event, writes its values into
// [out] (WINDOW_EVENT_VALUES of them) and returns its type (WINDOW_EVENT_*).
internal fun __composeui_winPollEvent(
    handle: Long,
    timeoutMs: Int,
    onResize: (Int, Int) -> Unit,
    out: DoubleArray,
): Int = error("intrinsic androidx.compose.ui.window.__composeui_winPollEvent not installed")

// Queues an event on the window as if its platform had sent it.
internal fun __composeui_winPostEvent(handle: Long, type: Int, values: DoubleArray): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winPostEvent not installed")

internal fun __composeui_winClose(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winClose not installed")

internal fun __composeui_winSurface(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSurface not installed")

internal fun __composeui_winPresent(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winPresent not installed")

internal fun __composeui_winClear(handle: Long, argb: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winClear not installed")

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

// Register the touch callback with the host; the platform input source invokes
// it with the primary phase (0=down, 1=move, 2=up, 3=cancel) once the current
// multi-touch snapshot is staged, which the callback reads via the accessors below.
internal fun __composeui_setInputCallback(callback: (Int) -> Unit): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_setInputCallback not installed")

// The staged multi-touch snapshot: the number of active pointers and, per index,
// each pointer's stable id, position (surface points), and pressed state.
internal fun __composeui_touchCount(): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchCount not installed")
internal fun __composeui_touchId(index: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchId not installed")
internal fun __composeui_touchX(index: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchX not installed")
internal fun __composeui_touchY(index: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchY not installed")
internal fun __composeui_touchDown(index: Int): Boolean =
    error("intrinsic androidx.compose.ui.window.__composeui_touchDown not installed")

// The scroll delta (surface points) for a Scroll event (phase 4); 0 otherwise.
internal fun __composeui_touchScrollX(index: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchScrollX not installed")
internal fun __composeui_touchScrollY(index: Int): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_touchScrollY not installed")

// Show/hide the platform soft keyboard (driven by Compose text-field focus).
internal fun __composeui_showKeyboard(): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_showKeyboard not installed")
internal fun __composeui_hideKeyboard(): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_hideKeyboard not installed")

// Register the text-input callback; the platform invokes it with a kind
// (0=commit staged text, 1=backspace, 2=ime action) on each key event.
internal fun __composeui_setTextCallback(callback: (Int) -> Unit): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_setTextCallback not installed")

// The staged inserted text for a commit (kind 0).
internal fun __composeui_textInput(): String =
    error("intrinsic androidx.compose.ui.window.__composeui_textInput not installed")

// The hosted surface's size in points (mobile), or 0 when none is installed. A
// hosted Window fills these instead of its requested size.
internal fun __composeui_surfaceWidth(): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_surfaceWidth not installed")

internal fun __composeui_surfaceHeight(): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_surfaceHeight not installed")
