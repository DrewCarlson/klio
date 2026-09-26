/*
 * Copyright 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// ui's desktopMain Tray.desktop.kt (v1.12.0) over the platform's own tray
// icon in place of AWT's SystemTray and TrayIcon: a status item in the macOS
// menu bar, a Windows notification area icon, and on X11 an icon docked in
// the desktop's system tray (the XEmbed tray protocol AWT's X11 SystemTray
// speaks). Its menu is the desktop's AWT popup menu (no icons, mnemonics,
// shortcuts or radio button items), its action and menu choices run on the
// application loop, and a notification shows as the platform's, as
// TrayIcon.displayMessage shows it. Where there is no tray (no tray on the X
// display, no X display), Tray says so on standard error, as the desktop's
// does.
package androidx.compose.ui.window

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ComposableOpenTarget
import androidx.compose.runtime.Composition
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCompositionContext
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.klioDrawToSurface
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.input.key.__composeui_hostOs
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.receiveAsFlow

/**
 * `true` if the platform supports tray icons in the taskbar
 */
val isTraySupported: Boolean get() = __composeui_traySupported()

// TODO(demin): add mouse click/double-click/right click listeners (can we use PointerInputEvent?)
/**
 * Adds tray icon to the platform taskbar if it is supported.
 *
 * If tray icon isn't supported by the platform, in the "standard" error output stream
 * will be printed an error.
 *
 * See [isTraySupported] to know if tray icon is supported
 * (for example to show/hide an option in the application settings)
 *
 * @param icon Icon of the tray
 * @param state State to control tray and show notifications
 * @param tooltip Hint/tooltip that will be shown to the user
 * @param menu Context menu of the tray that will be shown to the user on the mouse click (right
 * click on Windows, left click on macOs).
 * If it doesn't contain any items then context menu will not be shown.
 * @param onAction Action performed when user clicks on the tray icon (double click on Windows,
 * right click on macOs)
 */
@Suppress("unused")
@Composable
@ComposableOpenTarget(-1)
fun ApplicationScope.Tray(
    icon: Painter,
    state: TrayState = rememberTrayState(),
    tooltip: String? = null,
    onAction: () -> Unit = {},
    menu: @Composable @MenuComposable MenuScope.() -> Unit = {}
) {
    if (!isTraySupported) {
        DisposableEffect(Unit) {
            // We should notify developer, but shouldn't throw an exception.
            // If we would throw an exception, some application wouldn't work on some platforms at
            // all, if developer doesn't check that application crashes.
            //
            // We can do this because we don't return anything in Tray function, and following
            // code doesn't depend on something that is created/calculated in this function.
            __composeui_printErr(
                "Tray is not supported on the current platform. " +
                    "Use the global property `isTraySupported` to check."
            )
            onDispose {}
        }
        return
    }

    val app = LocalKlioApplication.current
    val currentOnAction by rememberUpdatedState(onAction)
    val tray = remember { KlioTray { currentOnAction() } }
    val currentMenu by rememberUpdatedState(menu)

    val composition = rememberCompositionContext()
    val coroutineScope = rememberCoroutineScope()

    DisposableEffect(Unit) {
        tray.open()
        app?.trays?.add(tray)

        val content = currentMenu
        val menuComposition = Composition(KlioMenuApplier(tray.menu.root, tray.menu::sync), composition)
        menuComposition.setContent {
            MenuScope(KlioMenuScope(tray = true)).content()
        }
        tray.menu.sink = tray

        state.notificationFlow
            .onEach(tray::notify)
            .launchIn(coroutineScope)

        onDispose {
            menuComposition.dispose()
            app?.trays?.remove(tray)
            tray.close()
        }
    }

    SideEffect {
        tray.setIcon(icon)
        tray.setTooltip(tooltip)
    }
}

/**
 * Creates a [WindowState] that is remembered across compositions.
 */
@Composable
fun rememberTrayState() = remember {
    TrayState()
}

/**
 * A state object that can be hoisted to control tray and show notifications.
 *
 * In most cases, this will be created via [rememberTrayState].
 */
class TrayState {
    private val notificationChannel = Channel<Notification>(0)

    /**
     * Flow of notifications sent by [sendNotification].
     * This flow doesn't have a buffer, so all previously sent notifications will not appear in
     * this flow.
     */
    val notificationFlow: Flow<Notification>
        get() = notificationChannel.receiveAsFlow()

    /**
     * Send notification to tray. If [TrayState] is attached to [Tray], notification will be sent to
     * the platform. If [TrayState] is not attached then notification will be lost.
     */
    fun sendNotification(notification: Notification) {
        notificationChannel.trySend(notification)
    }
}

/**
 * A platform tray icon: its icon and tooltip as the Tray composable sets
 * them, its menu, and its action and menu choices polled on the loop.
 */
internal class KlioTray(private val onAction: () -> Unit) : KlioMenuSink {
    private var handle: Long = 0L
    private var icon: Painter? = null
    private var iconSet = false
    private var tooltip: String? = null
    private var tooltipSet = false
    val menu = KlioMenuBar()

    override val isOpen: Boolean get() = handle != 0L

    fun open() {
        handle = __composeui_trayOpen()
    }

    fun close() {
        menu.sink = null
        if (handle != 0L) __composeui_trayClose(handle)
        handle = 0L
    }

    /**
     * The icon drawn at the size the desktop draws it (Tray.desktop.kt's
     * iconSize): 16 points on Windows, 22 elsewhere, at twice their pixels.
     */
    fun setIcon(painter: Painter) {
        if (!isOpen || (iconSet && icon === painter)) return
        icon = painter
        iconSet = true
        val px = if (__composeui_hostOs() == "windows") 32 else 44
        val surface = __composeui_iconSurface(px, px)
        if (surface == 0L) return
        val size = Size(px.toFloat(), px.toFloat())
        klioDrawToSurface(surface) {
            CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, this, size) {
                with(painter) { draw(size) }
            }
        }
        __composeui_traySetIcon(handle, surface)
        __composeui_iconSurfaceFree(surface)
    }

    fun setTooltip(text: String?) {
        if (!isOpen || (tooltipSet && tooltip == text)) return
        tooltip = text
        tooltipSet = true
        __composeui_traySetTooltip(handle, text)
    }

    fun notify(notification: Notification) {
        if (!isOpen) return
        __composeui_trayNotify(handle, notification.title, notification.message, notification.type.ordinal)
    }

    override fun setMenu(spec: String) {
        if (isOpen) __composeui_traySetMenu(handle, spec)
    }

    // An AWT popup menu takes no icons (Item says so before one gets here).
    override fun setIcon(id: Int, icon: Painter) {}

    /** Runs the action and the menu choices the platform reported. */
    fun poll() {
        while (isOpen) {
            when (__composeui_trayPollEvent(handle, trayEventValues)) {
                WINDOW_EVENT_MENU -> menu.perform(trayEventValues[0].toInt())
                TRAY_EVENT_ACTION -> onAction()
                else -> return
            }
        }
    }
}

private const val TRAY_EVENT_ACTION = 18

private val trayEventValues = DoubleArray(WINDOW_EVENT_VALUES)

internal fun __composeui_traySupported(): Boolean =
    error("intrinsic androidx.compose.ui.window.__composeui_traySupported not installed")

internal fun __composeui_trayOpen(): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_trayOpen not installed")

internal fun __composeui_trayClose(handle: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_trayClose not installed")

internal fun __composeui_traySetIcon(handle: Long, surface: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_traySetIcon not installed")

internal fun __composeui_traySetTooltip(handle: Long, text: String?): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_traySetTooltip not installed")

internal fun __composeui_traySetMenu(handle: Long, spec: String): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_traySetMenu not installed")

// type: 0 none, 1 info, 2 warning, 3 error (Notification.Type's order).
internal fun __composeui_trayNotify(handle: Long, title: String, message: String, type: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_trayNotify not installed")

// The tray's next event (WINDOW_EVENT_MENU with the item's id, or its action),
// its values written into [values]; 0 when it has none.
internal fun __composeui_trayPollEvent(handle: Long, values: DoubleArray): Int =
    error("intrinsic androidx.compose.ui.window.__composeui_trayPollEvent not installed")

// Runs the platform's events for up to the timeout while no window polls them.
internal fun __composeui_appWait(timeoutMs: Int): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_appWait not installed")

// Writes a line on standard error.
internal fun __composeui_printErr(message: String): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_printErr not installed")
