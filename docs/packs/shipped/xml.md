# klio.xml

The `klio.xml` pack is the part of the JVM's XML APIs a DOM parse needs,
under klio's name (klio names JVM-only classes `klio.*`): a document
builder in the shape of `javax.xml.parsers`, the tree it builds in the
shape of `org.w3c.dom`, and its input and error in the shape of
`org.xml.sax`. It ships in-repo under `kotlin-klio/klio-xml`. Compose's
`loadXmlImageVector` and `painterResource("….xml")` parse vector drawables
through it.

| Package              | Surface                                                                  |
|----------------------|--------------------------------------------------------------------------|
| `klio.xml.parsers`   | `DocumentBuilderFactory` (`isNamespaceAware`, `isIgnoringElementContentWhitespace`), `DocumentBuilder.parse(InputSource \| InputStream)` |
| `klio.xml.dom`       | `Node`, `Element` (`getAttribute`, `getAttributeNS`, `lookupPrefix`, `getElementsByTagName`), `Attr`, `Text`, `Document`, `NodeList` |
| `klio.xml.sax`       | `InputSource`, `SAXException`, `SAXParseException` (line and column)     |

The parser reads well-formed XML 1.0 in UTF-8: elements, attributes,
namespace declarations (resolved when the factory is namespace aware),
text, CDATA sections, the five predefined entities and character
references. Comments, processing instructions and a document type
declaration are read past; a document that is not well-formed throws
`SAXParseException`. `klio.io.InputStream` and `ByteArrayInputStream`,
which it reads, are in the stdlib.

```kotlin
import klio.io.ByteArrayInputStream
import klio.xml.parsers.DocumentBuilderFactory
import klio.xml.sax.InputSource

fun main() {
    val doc = DocumentBuilderFactory.newInstance()
        .apply { isNamespaceAware = true }
        .newDocumentBuilder()
        .parse(InputSource(ByteArrayInputStream("""<a xmlns:p="urn:p" p:x="1"/>""".encodeToByteArray())))
    println(doc.documentElement.getAttributeNS("urn:p", "x")) // 1
}
```

`examples/xml_dom.kt` shows the rest.
