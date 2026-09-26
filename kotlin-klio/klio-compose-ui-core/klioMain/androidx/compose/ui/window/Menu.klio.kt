/*
 * Copyright 2021 The Android Open Source Project
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

// ui's desktopMain Menu.desktop.kt (v1.12.0) over the platform's own menus
// in place of Swing's and AWT's: MenuBarScope and MenuScope are the
// desktop's, their nodes compose into a tree the window hands the Skia shim
// (an NSMenu main menu on macOS, as the desktop's screen menu bar is; a Win32
// menu bar), and a chosen item runs its action on the window loop, as a
// Swing action runs on the event thread. A check box or radio button item
// keeps the state its composition gives it: choosing it calls back, as the
// desktop's ComposeState makes Swing's stateful items stateless. Key
// shortcuts are matched as Swing matches a menu bar's accelerators, after the
// window's content leaves the key (on macOS, whether it does or not, as the
// screen menu bar sees the key after the program). The JMenuBar, JMenu and
// java.awt.Menu setContent functions have no counterpart: those are AWT's.
package androidx.compose.ui.window

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.Composition
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCompositionContext
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.klioDrawToSurface
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyShortcut
import androidx.compose.ui.input.key.isMacOs
import androidx.compose.ui.input.key.matches
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.unit.LayoutDirection

/**
 * Adds the menu bar to the window: the application's main menu while the
 * window is focused on macOS, the window's menu bar elsewhere.
 */
@Composable
fun FrameWindowScope.MenuBar(content: @Composable @MenuComposable MenuBarScope.() -> Unit) {
    val window = LocalKlioWindowRef.current ?: return
    val parentComposition = rememberCompositionContext()

    DisposableEffect(Unit) {
        val bar = KlioMenuBar()
        val composition = Composition(KlioMenuApplier(bar.root, bar::sync), parentComposition)
        composition.setContent {
            MenuBarScope().content()
        }
        window.menuBar = bar
        onDispose {
            window.menuBar = null
            composition.dispose()
        }
    }
}

/**
 * Receiver scope which is used by [FrameWindowScope.MenuBar].
 */
class MenuBarScope internal constructor() {
    /**
     * Adds menu to the menu bar
     *
     * @param text text of the menu that will be shown on the menu bar
     * @param enabled is this menu item can be chosen
     * @param mnemonic character that corresponds to some key on the keyboard.
     * When this key and Alt modifier will be pressed - menu will be open.
     * If the character is found within the item's text, the first occurrence
     * of it will be underlined.
     * @param content content of the menu (sub menus, items, separators, etc)
     */
    @Composable
    @MenuComposable
    fun Menu(
        text: String,
        mnemonic: Char? = null,
        enabled: Boolean = true,
        content: @Composable @MenuComposable MenuScope.() -> Unit
    ) {
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = { KlioMenuNode(KlioMenuNode.MENU) },
            update = {
                set(text) { this.text = it }
                set(enabled) { this.enabled = it }
                set(mnemonic) { this.mnemonic = it }
            },
            content = {
                MenuScope(KlioMenuScope(tray = false)).content()
            }
        )
    }
}

internal interface MenuScopeImpl {
    @Composable
    @MenuComposable
    fun Menu(
        text: String,
        enabled: Boolean,
        mnemonic: Char?,
        content: @Composable @MenuComposable MenuScope.() -> Unit
    )

    @Composable
    @MenuComposable
    fun Separator()

    @Composable
    @MenuComposable
    fun Item(
        text: String,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onClick: () -> Unit
    )

    @Composable
    @MenuComposable
    fun CheckboxItem(
        text: String,
        checked: Boolean,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onCheckedChange: (Boolean) -> Unit
    )

    @Composable
    @MenuComposable
    fun RadioButtonItem(
        text: String,
        selected: Boolean,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onClick: () -> Unit
    )
}

/**
 * The menu scope of a window's menu bar, as the desktop's Swing one, or of a
 * tray's menu ([tray]), which is an AWT popup menu on the desktop: it takes
 * no icons, mnemonics, shortcuts or radio button items, and says so as the
 * desktop's does.
 */
internal class KlioMenuScope(private val tray: Boolean) : MenuScopeImpl {
    @Composable
    @MenuComposable
    override fun Menu(
        text: String,
        enabled: Boolean,
        mnemonic: Char?,
        content: @Composable @MenuComposable MenuScope.() -> Unit
    ) {
        if (tray && mnemonic != null) {
            throw UnsupportedOperationException("java.awt.Menu doesn't support mnemonic")
        }
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = { KlioMenuNode(KlioMenuNode.MENU) },
            update = {
                set(text) { this.text = it }
                set(enabled) { this.enabled = it }
                set(mnemonic) { this.mnemonic = it }
            },
            content = {
                MenuScope(this).content()
            }
        )
    }

    @Composable
    @MenuComposable
    override fun Separator() {
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = { KlioMenuNode(KlioMenuNode.SEPARATOR) },
            update = {}
        )
    }

    private fun checkTray(icon: Painter?, mnemonic: Char?, shortcut: KeyShortcut?) {
        if (!tray) return
        if (icon != null) {
            throw UnsupportedOperationException("java.awt.Menu doesn't support icon")
        }
        if (mnemonic != null) {
            throw UnsupportedOperationException("java.awt.Menu doesn't support mnemonic")
        }
        if (shortcut != null) {
            throw UnsupportedOperationException("java.awt.Menu doesn't support shortcut")
        }
    }

    @Composable
    @MenuComposable
    override fun Item(
        text: String,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onClick: () -> Unit
    ) {
        checkTray(icon, mnemonic, shortcut)
        val currentOnClick by rememberUpdatedState(onClick)
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = {
                KlioMenuNode(KlioMenuNode.ITEM).apply { action = { currentOnClick() } }
            },
            update = {
                set(text) { this.text = it }
                set(icon) { this.icon = it }
                set(enabled) { this.enabled = it }
                set(mnemonic) { this.mnemonic = it }
                set(shortcut) { this.shortcut = it }
            }
        )
    }

    @Composable
    @MenuComposable
    override fun CheckboxItem(
        text: String,
        checked: Boolean,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onCheckedChange: (Boolean) -> Unit
    ) {
        checkTray(icon, mnemonic, shortcut)
        val currentOnCheckedChange by rememberUpdatedState(onCheckedChange)
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = {
                KlioMenuNode(KlioMenuNode.CHECKBOX).apply {
                    // The item's state is its composition's: a click asks for the other.
                    action = { currentOnCheckedChange(!state) }
                }
            },
            update = {
                set(text) { this.text = it }
                set(checked) { this.state = it }
                set(icon) { this.icon = it }
                set(enabled) { this.enabled = it }
                set(mnemonic) { this.mnemonic = it }
                set(shortcut) { this.shortcut = it }
            }
        )
    }

    @Composable
    @MenuComposable
    override fun RadioButtonItem(
        text: String,
        selected: Boolean,
        icon: Painter?,
        enabled: Boolean,
        mnemonic: Char?,
        shortcut: KeyShortcut?,
        onClick: () -> Unit
    ) {
        if (tray) {
            throw UnsupportedOperationException("java.awt.Menu doesn't support RadioButtonItem")
        }
        val currentOnClick by rememberUpdatedState(onClick)
        ComposeNode<KlioMenuNode, KlioMenuApplier>(
            factory = {
                KlioMenuNode(KlioMenuNode.RADIO).apply { action = { currentOnClick() } }
            },
            update = {
                set(text) { this.text = it }
                set(selected) { this.state = it }
                set(icon) { this.icon = it }
                set(enabled) { this.enabled = it }
                set(mnemonic) { this.mnemonic = it }
                set(shortcut) { this.shortcut = it }
            }
        )
    }
}

// we use `class MenuScope` and `interface MenuScopeImpl` instead of just `interface MenuScope`
// because of b/165812010
/**
 * Receiver scope which is used by [MenuBarScope.Menu], [Tray]
 */
class MenuScope internal constructor(private val impl: MenuScopeImpl) {
    /**
     * Adds sub menu to the menu
     *
     * @param text text of the menu that will be shown in the menu
     * @param enabled is this menu item can be chosen
     * @param mnemonic character that corresponds to some key on the keyboard.
     * When this key will be pressed - menu will be open.
     * If the character is found within the item's text, the first occurrence
     * of it will be underlined.
     * @param content content of the menu (sub menus, items, separators, etc)
     */
    @Composable
    @MenuComposable
    fun Menu(
        text: String,
        enabled: Boolean = true,
        mnemonic: Char? = null,
        content: @Composable @MenuComposable MenuScope.() -> Unit
    ): Unit = impl.Menu(
        text,
        enabled,
        mnemonic,
        content
    )

    /**
     * Adds separator to the menu
     */
    @Composable
    @MenuComposable
    fun Separator() = impl.Separator()

    /**
     * Adds item to the menu
     *
     * @param text text of the item that will be shown in the menu
     * @param icon icon of the item
     * @param enabled is this item item can be chosen
     * @param mnemonic character that corresponds to some key on the keyboard.
     * When this key will be pressed - [onClick] will be triggered.
     * If the character is found within the item's text, the first occurrence
     * of it will be underlined.
     * @param shortcut key combination which triggers [onClick] action without
     * navigating the menu hierarchy.
     * @param onClick action that should be performed when the user clicks on the item
     */
    @Composable
    @MenuComposable
    fun Item(
        text: String,
        icon: Painter? = null,
        enabled: Boolean = true,
        mnemonic: Char? = null,
        shortcut: KeyShortcut? = null,
        onClick: () -> Unit
    ): Unit = impl.Item(text, icon, enabled, mnemonic, shortcut, onClick)

    /**
     * Adds item with checkbox to the menu
     *
     * @param text text of the item that will be shown in the menu
     * @param checked whether checkbox is checked or unchecked
     * @param icon icon of the item
     * @param enabled is this item item can be chosen
     * @param mnemonic character that corresponds to some key on the keyboard.
     * When this key will be pressed - [onCheckedChange] will be triggered.
     * If the character is found within the item's text, the first occurrence
     * of it will be underlined.
     * @param shortcut key combination which triggers [onCheckedChange] action without
     * navigating the menu hierarchy.
     * @param onCheckedChange callback to be invoked when checkbox is being clicked,
     * therefore the change of checked state in requested
     */
    @Composable
    @MenuComposable
    fun CheckboxItem(
        text: String,
        checked: Boolean,
        icon: Painter? = null,
        enabled: Boolean = true,
        mnemonic: Char? = null,
        shortcut: KeyShortcut? = null,
        onCheckedChange: (Boolean) -> Unit
    ): Unit = impl.CheckboxItem(
        text, checked, icon, enabled, mnemonic, shortcut, onCheckedChange
    )

    /**
     * Adds item with radio button to the menu
     *
     * @param text text of the item that will be shown in the menu
     * @param selected boolean state for this button: either it is selected or not
     * @param icon icon of the item
     * @param enabled is this item item can be chosen
     * @param mnemonic character that corresponds to some key on the keyboard.
     * When this key will be pressed - [onClick] will be triggered.
     * If the character is found within the item's text, the first occurrence
     * of it will be underlined.
     * @param shortcut key combination which triggers [onClick] action without
     * navigating the menu hierarchy.
     * @param onClick callback to be invoked when the radio button is being clicked
     */
    @Composable
    @MenuComposable
    fun RadioButtonItem(
        text: String,
        selected: Boolean,
        icon: Painter? = null,
        enabled: Boolean = true,
        mnemonic: Char? = null,
        shortcut: KeyShortcut? = null,
        onClick: () -> Unit
    ): Unit = impl.RadioButtonItem(
        text, selected, icon, enabled, mnemonic, shortcut, onClick
    )
}

/** A menu, item or separator of a menu bar or a tray's menu. */
internal class KlioMenuNode(val kind: Int) {
    val id: Int = nextId++
    var parent: KlioMenuNode? = null
    val children = mutableListOf<KlioMenuNode>()
    var text: String = ""
    var enabled: Boolean = true
    var mnemonic: Char? = null
    var shortcut: KeyShortcut? = null
    var icon: Painter? = null
    /** A check box item's checked, a radio button item's selected. */
    var state: Boolean = false
    var action: () -> Unit = {}

    /** Whether it and every menu it is in can be chosen. */
    val isEnabled: Boolean
        get() {
            var node: KlioMenuNode? = this
            while (node != null && node.kind != ROOT) {
                if (!node.enabled) return false
                node = node.parent
            }
            return true
        }

    companion object {
        const val ROOT = 0
        const val MENU = 1
        const val ITEM = 2
        const val CHECKBOX = 3
        const val RADIO = 4
        const val SEPARATOR = 5

        private var nextId = 1
    }
}

internal class KlioMenuApplier(
    root: KlioMenuNode,
    private val onChanged: () -> Unit,
) : AbstractApplier<KlioMenuNode>(root) {
    override fun insertTopDown(index: Int, instance: KlioMenuNode) {
        instance.parent = current
        current.children.add(index, instance)
    }

    override fun insertBottomUp(index: Int, instance: KlioMenuNode) {
        // Ignored as the tree is built top-down.
    }

    override fun remove(index: Int, count: Int) {
        current.children.remove(index, count)
    }

    override fun move(from: Int, to: Int, count: Int) {
        current.children.move(from, to, count)
    }

    override fun onClear() {
        root.children.clear()
    }

    override fun onEndChanges() {
        onChanged()
    }
}

/** Where a menu tree goes: a window's platform menu bar, or a tray's menu. */
internal interface KlioMenuSink {
    val isOpen: Boolean

    /** Sets the platform menu from its entries (window_events.h), or removes it for "". */
    fun setMenu(spec: String)

    fun setIcon(id: Int, icon: Painter)
}

/** A window's platform menu bar. */
internal class WindowMenuSink(private val window: KlioWindowHolder) : KlioMenuSink {
    override val isOpen: Boolean get() = !window.closed

    override fun setMenu(spec: String) {
        __composeui_winSetMenu(window.handle, spec)
    }

    override fun setIcon(id: Int, icon: Painter) {
        val px = if (isMacOs) 32 else 16
        val surface = __composeui_iconSurface(px, px)
        if (surface == 0L) return
        val size = Size(px.toFloat(), px.toFloat())
        klioDrawToSurface(surface) {
            CanvasDrawScope().draw(window.scene.density, LayoutDirection.Ltr, this, size) {
                with(icon) { draw(size) }
            }
        }
        __composeui_winSetMenuIcon(window.handle, id, surface)
        __composeui_iconSurfaceFree(surface)
    }
}

/**
 * A menu tree (a window's menu bar, a tray's menu): its composed nodes,
 * handed to the platform whenever they change, and the actions and shortcuts
 * of its items.
 */
internal class KlioMenuBar {
    val root = KlioMenuNode(KlioMenuNode.ROOT)
    private var byId: Map<Int, KlioMenuNode> = emptyMap()
    var sink: KlioMenuSink? = null
        set(value) {
            field = value
            sync()
        }

    /** Hands the tree to the platform. */
    fun sync() {
        val target = sink ?: return
        if (!target.isOpen) return
        val spec = StringBuilder()
        val ids = HashMap<Int, KlioMenuNode>()
        val withIcons = ArrayList<KlioMenuNode>()
        fun add(node: KlioMenuNode, depth: Int) {
            for (child in node.children) {
                ids[child.id] = child
                if (child.icon != null && child.kind != KlioMenuNode.MENU) withIcons.add(child)
                spec.append(depth).append('\t')
                spec.append(KIND_CODES[child.kind]).append('\t')
                spec.append(child.id).append('\t')
                spec.append(if (child.enabled) 1 else 0).append('\t')
                spec.append(if (child.state) 1 else 0).append('\t')
                spec.append(child.mnemonic?.code ?: 0).append('\t')
                val shortcut = child.shortcut
                spec.append(shortcut?.key?.nativeKeyCode ?: 0).append('\t')
                spec.append(if (shortcut != null) modifiersOf(shortcut) else 0).append('\t')
                spec.append(child.text.replace('\t', ' ').replace('\n', ' ')).append('\n')
                if (child.kind == KlioMenuNode.MENU) add(child, depth + 1)
            }
        }
        add(root, 0)
        byId = ids
        target.setMenu(spec.toString())
        for (node in withIcons) target.setIcon(node.id, node.icon ?: continue)
    }

    /** Removes the platform menu. */
    fun detach() {
        val target = sink ?: return
        if (target.isOpen) target.setMenu("")
        sink = null
    }

    /** Runs the action of the item the platform reports chosen. */
    fun perform(id: Int) {
        val node = byId[id] ?: return
        if (node.kind == KlioMenuNode.MENU || node.kind == KlioMenuNode.SEPARATOR) return
        if (!node.isEnabled) return
        node.action()
    }

    /**
     * Runs the action of the first item, depth first, whose shortcut the key
     * press is, as a menu bar's accelerators are matched; returns whether one
     * was.
     */
    fun shortcut(event: KeyEvent): Boolean {
        fun find(node: KlioMenuNode): KlioMenuNode? {
            for (child in node.children) {
                if (!child.enabled) continue
                if (child.kind == KlioMenuNode.MENU) {
                    find(child)?.let { return it }
                } else if (child.shortcut?.matches(event) == true) {
                    return child
                }
            }
            return null
        }
        val node = find(root) ?: return false
        node.action()
        return true
    }

    private companion object {
        val KIND_CODES = charArrayOf('-', 'm', 'i', 'c', 'r', 's')

        fun modifiersOf(shortcut: KeyShortcut): Int {
            var mods = 0
            if (shortcut.shift) mods = mods or 1
            if (shortcut.ctrl) mods = mods or 2
            if (shortcut.alt) mods = mods or 4
            if (shortcut.meta) mods = mods or 8
            return mods
        }
    }
}

/** Whether a menu bar's shortcut runs even when the window's content took the key. */
internal val menuShortcutsAfterConsumedKeys: Boolean get() = isMacOs

/** The window a menu bar composes for. */
internal val LocalKlioWindowRef = staticCompositionLocalOf<WindowRef?> { null }

// Sets a window's menu bar from its entries (window_events.h), or removes it
// for an empty spec.
internal fun __composeui_winSetMenu(handle: Long, spec: String): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetMenu not installed")

// Sets the icon of a window's menu item from the surface its painter was
// drawn on.
internal fun __composeui_winSetMenuIcon(handle: Long, id: Int, surface: Long): Long =
    error("intrinsic androidx.compose.ui.window.__composeui_winSetMenuIcon not installed")
