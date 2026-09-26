// The part of the W3C DOM (org.w3c.dom on the JVM) a namespace-aware parse
// yields: elements with their attributes and children, text, and the
// document. Nodes are built by klio.xml.parsers.DocumentBuilder and read
// only.

package klio.xml.dom

/** A node of a document tree. */
abstract class Node internal constructor() {
    /** The node's qualified name: an element's tag, `#text` or `#document`. */
    abstract val nodeName: String

    /** One of the node type constants. */
    abstract val nodeType: Short

    /** The node's namespace URI, or null for none. */
    open val namespaceURI: String? get() = null

    /** The node's local name (its name without a prefix), or null for a node without one. */
    open val localName: String? get() = null

    /** The node's text, or null for a document or an element. */
    open val nodeValue: String? get() = null

    internal val children = mutableListOf<Node>()

    /** The node's children, in document order. */
    val childNodes: NodeList get() = NodeList(children)

    /** The node's parent, or null for the document or a node not in a tree. */
    var parentNode: Node? = null
        internal set

    val firstChild: Node? get() = children.firstOrNull()
    val lastChild: Node? get() = children.lastOrNull()

    fun hasChildNodes(): Boolean = children.isNotEmpty()

    /** The text of the node and all its descendants, concatenated. */
    open val textContent: String?
        get() = buildString { appendText(this@Node) }

    private fun StringBuilder.appendText(node: Node) {
        if (node is Text) append(node.data)
        for (child in node.children) appendText(child)
    }

    companion object {
        const val ELEMENT_NODE: Short = 1
        const val ATTRIBUTE_NODE: Short = 2
        const val TEXT_NODE: Short = 3
        const val CDATA_SECTION_NODE: Short = 4
        const val PROCESSING_INSTRUCTION_NODE: Short = 7
        const val COMMENT_NODE: Short = 8
        const val DOCUMENT_NODE: Short = 9
    }
}

/** The children of a node. */
class NodeList internal constructor(private val nodes: List<Node>) {
    /** The number of nodes. */
    val length: Int get() = nodes.size

    /** The node at [index], which is below [length]. */
    fun item(index: Int): Node = nodes[index]
}

/** An attribute of an element. */
class Attr internal constructor(
    /** The attribute's qualified name, as written. */
    val name: String,
    override val namespaceURI: String?,
    override val localName: String,
    /** The attribute's value, entity references replaced. */
    val value: String,
) : Node() {
    override val nodeName: String get() = name
    override val nodeType: Short get() = ATTRIBUTE_NODE
    override val nodeValue: String get() = value
    override val textContent: String get() = value

    /** The attribute's prefix, or null for none. */
    val prefix: String? get() = name.substringBefore(':', "").ifEmpty { null }
}

/** An element: its tag, attributes and children. */
class Element internal constructor(
    /** The element's qualified name, as written. */
    val tagName: String,
    override val namespaceURI: String?,
    override val localName: String,
    internal val attributeList: List<Attr>,
    /** The namespace declarations in scope at the element: prefix ("" for the default) to URI. */
    internal val namespaces: Map<String, String>,
) : Node() {
    override val nodeName: String get() = tagName
    override val nodeType: Short get() = ELEMENT_NODE

    /** The prefix of the element's name, or null for none. */
    val prefix: String? get() = tagName.substringBefore(':', "").ifEmpty { null }

    /** The value of the attribute of qualified name [name], or "" when the element has none. */
    fun getAttribute(name: String): String = attributeList.firstOrNull { it.name == name }?.value ?: ""

    /**
     * The value of the attribute of local name [localName] in [namespaceURI],
     * or "" when the element has none.
     */
    fun getAttributeNS(namespaceURI: String?, localName: String): String =
        getAttributeNodeNS(namespaceURI, localName)?.value ?: ""

    fun getAttributeNode(name: String): Attr? = attributeList.firstOrNull { it.name == name }

    fun getAttributeNodeNS(namespaceURI: String?, localName: String): Attr? =
        attributeList.firstOrNull { it.namespaceURI == namespaceURI && it.localName == localName }

    fun hasAttribute(name: String): Boolean = getAttributeNode(name) != null

    fun hasAttributeNS(namespaceURI: String?, localName: String): Boolean =
        getAttributeNodeNS(namespaceURI, localName) != null

    /** The number of the element's attributes, namespace declarations included. */
    val attributeCount: Int get() = attributeList.size

    /** The element's attribute at [index], in the order written. */
    fun attributeAt(index: Int): Attr? = attributeList.getOrNull(index)

    /** The prefix bound to [namespaceURI] at the element, or null when none is. */
    fun lookupPrefix(namespaceURI: String?): String? {
        if (namespaceURI == null) return null
        return namespaces.entries.firstOrNull { it.value == namespaceURI && it.key.isNotEmpty() }?.key
    }

    /** The namespace URI bound to [prefix] (null for the default) at the element, or null. */
    fun lookupNamespaceURI(prefix: String?): String? = namespaces[prefix ?: ""]

    /** The element's descendants of qualified name [name] ("*" for all), in document order. */
    fun getElementsByTagName(name: String): NodeList = NodeList(descendants(this) { name == "*" || it.tagName == name })
}

/** Text between elements, or a CDATA section's. */
class Text internal constructor(
    /** The text, entity references replaced. */
    val data: String,
) : Node() {
    override val nodeName: String get() = "#text"
    override val nodeType: Short get() = TEXT_NODE
    override val nodeValue: String get() = data
}

/** A parsed document: its root element. */
class Document internal constructor() : Node() {
    override val nodeName: String get() = "#document"
    override val nodeType: Short get() = DOCUMENT_NODE
    override val textContent: String? get() = null

    /** The document's root element. */
    val documentElement: Element
        get() = children.filterIsInstance<Element>().first()

    /** The document's elements of qualified name [name] ("*" for all), in document order. */
    fun getElementsByTagName(name: String): NodeList = NodeList(
        listOf(documentElement).filter { name == "*" || it.tagName == name } +
            descendants(documentElement) { name == "*" || it.tagName == name }
    )
}

private fun descendants(root: Node, keep: (Element) -> Boolean): List<Node> {
    val out = mutableListOf<Node>()
    fun walk(node: Node) {
        for (child in node.children) {
            if (child is Element) {
                if (keep(child)) out.add(child)
                walk(child)
            }
        }
    }
    walk(root)
    return out
}
