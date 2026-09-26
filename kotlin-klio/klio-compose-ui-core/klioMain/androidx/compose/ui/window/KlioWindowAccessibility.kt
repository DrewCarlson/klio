// A window's accessibility: its content's semantics as the platform's
// assistive technologies read them (VoiceOver through NSAccessibility,
// Narrator through UI Automation, Orca through AT-SPI), as Compose
// Desktop's ComposeSceneAccessibility offers them through AWT's. Once an
// assistive client reads the window, each frame that changed the semantics
// sends the shim a snapshot of the tree, and what the client asks of a
// node (a click, focus, new text, a step of a slider) comes back as an
// event and runs the node's semantics action.
//
// The snapshot is a node per line, fields separated by tabs, text fields
// escaped (`\\`, `\t`, `\n`): id, parent id (-1 for a root), role, state
// flags, action flags, x, y, width, height (in the window's content), range
// minimum, maximum and current value, name, value, description. It is read
// by src/compose_ui/window_events.h's klioParseA11y.

package androidx.compose.ui.window

import androidx.compose.ui.platform.PlatformContext
import androidx.compose.ui.semantics.AccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsConfiguration
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.getAllSemanticsNodes
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.isHidden
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.util.fastAll
import androidx.compose.ui.util.fastJoinToString

/** The roles a node has for assistive technologies (window_events.h's KLIO_A11Y_ROLE_*). */
internal object A11yRole {
    const val UNKNOWN = 0
    const val BUTTON = 1
    const val CHECKBOX = 2
    const val SWITCH = 3
    const val RADIO_BUTTON = 4
    const val TAB = 5
    const val DROPDOWN = 6
    const val IMAGE = 7
    const val TEXT_FIELD = 8
    const val PASSWORD_FIELD = 9
    const val TEXT = 10
    const val SLIDER = 11
    const val PROGRESS = 12
    const val SCROLL_AREA = 13
    const val GROUP = 14
}

/** A node's states (KLIO_A11Y_STATE_*). */
internal object A11yState {
    const val ENABLED = 1
    const val FOCUSABLE = 2
    const val FOCUSED = 4
    const val SELECTED = 8
    const val CHECKED = 16
    const val MIXED = 32
    const val EDITABLE = 64
    const val EXPANDED = 128
    const val COLLAPSED = 256
    const val HEADING = 512
    const val CHECKABLE = 1024
}

/** The actions a node offers (KLIO_A11Y_ACTION_*), as bits of the snapshot and codes of an event. */
internal object A11yAction {
    const val CLICK = 1
    const val LONG_CLICK = 2
    const val FOCUS = 3
    const val SET_TEXT = 4
    const val INCREMENT = 5
    const val DECREMENT = 6
    const val EXPAND = 7
    const val COLLAPSE = 8
    const val DISMISS = 9
    const val SCROLL_FORWARD = 10
    const val SCROLL_BACKWARD = 11

    fun bit(action: Int) = 1 shl (action - 1)
}

internal class KlioWindowAccessibility(private val handle: Long) : PlatformContext.SemanticsOwnerListener {
    private val owners = mutableListOf<SemanticsOwner>()

    /** Whether the semantics changed since the last snapshot. */
    private var changed = true

    override fun onSemanticsOwnerAppended(semanticsOwner: SemanticsOwner) {
        owners.add(semanticsOwner)
        changed = true
    }

    override fun onSemanticsOwnerRemoved(semanticsOwner: SemanticsOwner) {
        owners.remove(semanticsOwner)
        changed = true
    }

    override fun onSemanticsChange(semanticsOwner: SemanticsOwner) {
        changed = true
    }

    override fun onLayoutChange(semanticsOwner: SemanticsOwner, semanticsNodeId: Int) {
        changed = true
    }

    /** An assistive client started reading the window: the next frame sends the whole tree. */
    fun onActivated() {
        changed = true
    }

    /** After a frame: sends the tree when it changed and an assistive client reads the window. */
    fun sync() {
        if (!changed || !__composeui_a11yActive(handle)) return
        changed = false
        __composeui_a11yUpdate(handle, snapshot())
    }

    fun snapshot(): String {
        val out = StringBuilder()
        for (owner in owners) {
            val root = owner.rootSemanticsNode
            append(out, root, -1)
        }
        return out.toString()
    }

    private fun append(out: StringBuilder, node: SemanticsNode, parent: Int) {
        val config = node.config
        val hidden = node.isHidden
        if (!hidden) {
            line(out, node, config, parent)
        }
        val childParent = if (hidden) parent else node.id
        for (child in traversalOrderedChildren(node, config)) append(out, child, childParent)
    }

    private fun line(out: StringBuilder, node: SemanticsNode, config: SemanticsConfiguration, parent: Int) {
        val role = roleOf(config)
        val bounds = node.boundsInWindow
        val range = config.getOrNull(SemanticsProperties.ProgressBarRangeInfo)
        out.append(node.id).append('\t')
            .append(parent).append('\t')
            .append(role).append('\t')
            .append(statesOf(config, role)).append('\t')
            .append(actionsOf(config)).append('\t')
            .append(bounds.left).append('\t')
            .append(bounds.top).append('\t')
            .append(bounds.width).append('\t')
            .append(bounds.height).append('\t')
            .append(range?.range?.start ?: 0f).append('\t')
            .append(range?.range?.endInclusive ?: 0f).append('\t')
            .append(range?.current ?: 0f).append('\t')
        escape(out, nameOf(config))
        out.append('\t')
        escape(out, valueOf(config, role))
        out.append('\t')
        escape(out, config.getOrNull(SemanticsProperties.ContentDescription)?.mergeText() ?: "")
        out.append('\n')
    }

    // The role of a node as Compose Desktop's ComposeAccessible computes it:
    // its semantics role, else what its properties make it.
    private fun roleOf(config: SemanticsConfiguration): Int {
        when (config.getOrNull(SemanticsProperties.Role)) {
            Role.Button -> return A11yRole.BUTTON
            Role.Checkbox -> return A11yRole.CHECKBOX
            Role.Switch -> return A11yRole.SWITCH
            Role.RadioButton -> return A11yRole.RADIO_BUTTON
            Role.Tab -> return A11yRole.TAB
            Role.DropdownList -> return A11yRole.DROPDOWN
            Role.Image -> return A11yRole.IMAGE
        }
        return when {
            config.getOrNull(SemanticsProperties.Password) != null -> A11yRole.PASSWORD_FIELD
            config.getOrNull(SemanticsActions.SetText) != null -> A11yRole.TEXT_FIELD
            config.getOrNull(SemanticsActions.ScrollBy) != null -> A11yRole.SCROLL_AREA
            config.getOrNull(SemanticsProperties.Text) != null -> A11yRole.TEXT
            config.getOrNull(SemanticsProperties.ProgressBarRangeInfo) != null ->
                if (config.getOrNull(SemanticsActions.SetProgress) != null) A11yRole.SLIDER else A11yRole.PROGRESS
            config.getOrNull(SemanticsProperties.IsContainer) != null -> A11yRole.GROUP
            config.getOrNull(SemanticsProperties.IsTraversalGroup) != null -> A11yRole.GROUP
            else -> A11yRole.UNKNOWN
        }
    }

    private fun statesOf(config: SemanticsConfiguration, role: Int): Int {
        var s = 0
        if (config.getOrNull(SemanticsProperties.Disabled) == null) s = s or A11yState.ENABLED
        if (config.getOrNull(SemanticsProperties.Focused) != null) s = s or A11yState.FOCUSABLE
        if (config.getOrNull(SemanticsProperties.Focused) == true) s = s or A11yState.FOCUSED
        if (config.getOrNull(SemanticsProperties.Selected) == true) s = s or A11yState.SELECTED
        when (config.getOrNull(SemanticsProperties.ToggleableState)) {
            ToggleableState.On -> s = s or A11yState.CHECKABLE or A11yState.CHECKED
            ToggleableState.Indeterminate -> s = s or A11yState.CHECKABLE or A11yState.MIXED
            ToggleableState.Off -> s = s or A11yState.CHECKABLE
            null -> if (role == A11yRole.RADIO_BUTTON || role == A11yRole.TAB) {
                s = s or A11yState.CHECKABLE
                if (config.getOrNull(SemanticsProperties.Selected) == true) s = s or A11yState.CHECKED
            }
        }
        if (config.getOrNull(SemanticsProperties.IsEditable) == true) s = s or A11yState.EDITABLE
        val canExpand = config.getOrNull(SemanticsActions.Expand) != null
        val canCollapse = config.getOrNull(SemanticsActions.Collapse) != null
        if (canCollapse) s = s or A11yState.EXPANDED
        if (canExpand) s = s or A11yState.COLLAPSED
        if (config.getOrNull(SemanticsProperties.Heading) != null) s = s or A11yState.HEADING
        return s
    }

    private fun actionsOf(config: SemanticsConfiguration): Int {
        var a = 0
        fun has(key: SemanticsPropertyKey<*>, action: Int) {
            if (config.getOrNull(key) != null) a = a or A11yAction.bit(action)
        }
        has(SemanticsActions.OnClick, A11yAction.CLICK)
        has(SemanticsActions.OnLongClick, A11yAction.LONG_CLICK)
        has(SemanticsActions.RequestFocus, A11yAction.FOCUS)
        has(SemanticsActions.SetText, A11yAction.SET_TEXT)
        if (config.getOrNull(SemanticsActions.SetProgress) != null) {
            a = a or A11yAction.bit(A11yAction.INCREMENT) or A11yAction.bit(A11yAction.DECREMENT)
        }
        has(SemanticsActions.Expand, A11yAction.EXPAND)
        has(SemanticsActions.Collapse, A11yAction.COLLAPSE)
        has(SemanticsActions.Dismiss, A11yAction.DISMISS)
        if (config.getOrNull(SemanticsActions.ScrollBy) != null) {
            a = a or A11yAction.bit(A11yAction.SCROLL_FORWARD) or A11yAction.bit(A11yAction.SCROLL_BACKWARD)
        }
        return a
    }

    // The accessible name Compose Desktop gives: the content description, else the text.
    private fun nameOf(config: SemanticsConfiguration): String =
        config.getOrNull(SemanticsProperties.ContentDescription)?.mergeText()
            ?: config.getOrNull(SemanticsProperties.Text)?.mergeText()
            ?: ""

    private fun valueOf(config: SemanticsConfiguration, role: Int): String = when (role) {
        A11yRole.TEXT_FIELD, A11yRole.PASSWORD_FIELD ->
            (config.getOrNull(SemanticsProperties.EditableText)?.text ?: "")
        else -> config.getOrNull(SemanticsProperties.StateDescription) ?: ""
    }

    private fun List<CharSequence>.mergeText() = fastJoinToString(", ")

    private fun escape(out: StringBuilder, s: String) {
        for (c in s) {
            when (c) {
                '\\' -> out.append("\\\\")
                '\t' -> out.append("\\t")
                '\n' -> out.append("\\n")
                else -> out.append(c)
            }
        }
    }

    /**
     * Runs what an assistive client asked of node [nodeId]: the semantics
     * action behind [action], with [text] for new text. False when the node
     * has no such action.
     */
    fun perform(nodeId: Int, action: Int, text: String): Boolean {
        val node = findNode(nodeId) ?: return false
        val config = node.config
        fun run(key: SemanticsPropertyKey<AccessibilityAction<() -> Boolean>>): Boolean =
            config.getOrNull(key)?.action?.invoke() ?: false
        return when (action) {
            A11yAction.CLICK -> run(SemanticsActions.OnClick)
            A11yAction.LONG_CLICK -> run(SemanticsActions.OnLongClick)
            A11yAction.FOCUS -> run(SemanticsActions.RequestFocus)
            A11yAction.SET_TEXT ->
                config.getOrNull(SemanticsActions.SetText)?.action?.invoke(AnnotatedString(text)) ?: false
            A11yAction.INCREMENT, A11yAction.DECREMENT -> {
                val range = config.getOrNull(SemanticsProperties.ProgressBarRangeInfo) ?: return false
                val setProgress = config.getOrNull(SemanticsActions.SetProgress)?.action ?: return false
                val span = range.range.endInclusive - range.range.start
                val step = if (range.steps > 0) span / (range.steps + 1) else span / 20f
                val next = (range.current + if (action == A11yAction.INCREMENT) step else -step)
                    .coerceIn(range.range.start, range.range.endInclusive)
                setProgress(next)
            }
            A11yAction.EXPAND -> run(SemanticsActions.Expand)
            A11yAction.COLLAPSE -> run(SemanticsActions.Collapse)
            A11yAction.DISMISS -> run(SemanticsActions.Dismiss)
            A11yAction.SCROLL_FORWARD, A11yAction.SCROLL_BACKWARD -> {
                val scrollBy = config.getOrNull(SemanticsActions.ScrollBy)?.action ?: return false
                val vertical = config.getOrNull(SemanticsProperties.VerticalScrollAxisRange) != null
                val amount = (if (vertical) node.size.height else node.size.width) * 0.8f
                val signed = if (action == A11yAction.SCROLL_FORWARD) amount else -amount
                if (vertical) scrollBy(0f, signed) else scrollBy(signed, 0f)
            }
            else -> false
        }
    }

    private fun findNode(nodeId: Int): SemanticsNode? {
        for (owner in owners) {
            owner.getAllSemanticsNodes(mergingEnabled = true).firstOrNull { it.id == nodeId }?.let { return it }
        }
        return null
    }
}

// The children of a node in the order a screen reader visits them, as
// Compose Desktop's ComposeAccessible orders them: by traversal index
// within a traversal group.
private fun traversalOrderedChildren(node: SemanticsNode, config: SemanticsConfiguration): List<SemanticsNode> {
    val children = node.replacedChildren
    if (config.getOrNull(SemanticsProperties.IsTraversalGroup) != true) return children
    if (children.fastAll { it.unmergedConfig.getOrNull(SemanticsProperties.TraversalIndex) == null }) return children
    return children.sortedBy { it.unmergedConfig.getOrNull(SemanticsProperties.TraversalIndex) ?: 0f }
}

/** Whether an assistive client reads the window, so its semantics are worth sending. */
internal fun __composeui_a11yActive(handle: Long): Boolean =
    error("intrinsic androidx.compose.ui.window.__composeui_a11yActive not installed")

/** Sends the window's semantics snapshot (the format above) to the shim. */
internal fun __composeui_a11yUpdate(handle: Long, snapshot: String): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_a11yUpdate not installed")
