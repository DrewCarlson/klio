// klio.xml parses a document into a DOM, as javax.xml.parsers and
// org.w3c.dom do on the JVM: a namespace-aware parse resolves prefixes to
// namespace URIs for elements and attributes, entity and character
// references and CDATA sections become text, comments are read past, and a
// document that is not well-formed throws SAXParseException with where.
import klio.io.ByteArrayInputStream
import klio.xml.dom.Element
import klio.xml.parsers.DocumentBuilderFactory
import klio.xml.sax.InputSource
import klio.xml.sax.SAXParseException

const val ANDROID = "http://schemas.android.com/apk/res/android"

fun parse(xml: String, namespaces: Boolean = true) = DocumentBuilderFactory.newInstance()
    .apply { isNamespaceAware = namespaces }
    .newDocumentBuilder()
    .parse(InputSource(ByteArrayInputStream(xml.encodeToByteArray())))

fun show(e: Element, depth: Int = 0) {
    println("  ".repeat(depth) + "${e.tagName} (${e.namespaceURI}, ${e.localName})")
    for (i in 0 until e.childNodes.length) {
        val child = e.childNodes.item(i)
        if (child is Element) show(child, depth + 1)
        else if (!child.textContent.isNullOrBlank()) println("  ".repeat(depth + 1) + "text \"${child.textContent}\"")
    }
}

fun main() {
    val doc = parse(
        """<?xml version="1.0" encoding="utf-8"?>
        <!-- a vector drawable -->
        <vector xmlns:android="$ANDROID" xmlns:aapt="http://schemas.android.com/aapt"
            android:width="24dp" android:height="24dp">
          <path android:pathData="M0,0L10,10" android:fillColor="#FF0000"/>
          <aapt:attr name="android:fillColor"><gradient android:type="linear"/></aapt:attr>
          <label>1 &lt; 2 &amp;&amp; &#x41;<![CDATA[<raw>]]></label>
        </vector>"""
    )
    val root = doc.documentElement
    show(root)
    println(root.getAttributeNS(ANDROID, "width"))
    println("[" + root.getAttributeNS(ANDROID, "missing") + "]")
    println(root.getAttribute("android:height"))
    println(root.lookupPrefix(ANDROID))
    println(parse("<a xmlns:p='urn:p'><p:b/></a>", namespaces = false).documentElement.firstChild?.nodeName)
    for (bad in listOf("<a><b></a>", "<a x=1/>", "<a>&nope;</a>", "")) {
        try {
            parse(bad)
        } catch (e: SAXParseException) {
            println("not well-formed: ${e.message}")
        }
    }
}
