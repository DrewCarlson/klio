/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// A document builder in the shape of javax.xml.parsers': a factory makes a
// builder, which parses a whole document into klio.xml.dom nodes. It reads
// well-formed XML 1.0 in UTF-8: elements, attributes, namespace declarations
// (resolved when the factory is namespace aware), text, CDATA sections, the
// five predefined entities and character references; comments, processing
// instructions and a document type declaration are read past. Input that is
// not well-formed throws SAXParseException naming the line and column.

package klio.xml.parsers

import klio.io.InputStream
import klio.xml.dom.Attr
import klio.xml.dom.Document
import klio.xml.dom.Element
import klio.xml.dom.Node
import klio.xml.dom.Text
import klio.xml.sax.InputSource
import klio.xml.sax.SAXParseException

/** Makes document builders. */
class DocumentBuilderFactory private constructor() {
    /** Whether builders resolve namespaces: element and attribute namespace URIs and local names. */
    var isNamespaceAware: Boolean = false

    /** Whether builders drop whitespace-only text between elements. */
    var isIgnoringElementContentWhitespace: Boolean = false

    fun newDocumentBuilder(): DocumentBuilder =
        DocumentBuilder(isNamespaceAware, isIgnoringElementContentWhitespace)

    companion object {
        fun newInstance(): DocumentBuilderFactory = DocumentBuilderFactory()
    }
}

/** Parses documents. */
class DocumentBuilder internal constructor(
    private val namespaceAware: Boolean,
    private val ignoreWhitespace: Boolean,
) {
    fun isNamespaceAware(): Boolean = namespaceAware

    fun parse(source: InputSource): Document = parseText(source.readText())

    fun parse(stream: InputStream): Document = parseText(stream.readAllBytes().decodeToString())

    private fun parseText(text: String): Document =
        XmlReader(text, namespaceAware, ignoreWhitespace).document()
}

private const val XML_NS = "http://www.w3.org/XML/1998/namespace"
private const val XMLNS_NS = "http://www.w3.org/2000/xmlns/"

private class XmlReader(
    private val s: String,
    private val namespaceAware: Boolean,
    private val ignoreWhitespace: Boolean,
) {
    private var i = 0

    fun document(): Document {
        val doc = Document()
        if (s.startsWith("﻿")) i = 1
        misc(doc)
        if (i >= s.length || s[i] != '<') fail("the document has no root element")
        append(doc, element(mapOf("xml" to XML_NS)))
        misc(doc)
        if (i < s.length) fail("content after the root element")
        return doc
    }

    // Comments, processing instructions, a document type declaration and
    // whitespace, around the root element.
    private fun misc(doc: Document) {
        while (true) {
            skipSpace()
            when {
                s.startsWith("<?", i) -> skipPast("?>")
                s.startsWith("<!--", i) -> skipPast("-->")
                s.startsWith("<!DOCTYPE", i) -> doctype()
                else -> return
            }
        }
    }

    private fun doctype() {
        var depth = 0
        while (i < s.length) {
            when (s[i]) {
                '[' -> depth++
                ']' -> depth--
                '>' -> if (depth == 0) {
                    i++
                    return
                }
            }
            i++
        }
        fail("an unterminated document type declaration")
    }

    private fun element(outer: Map<String, String>): Element {
        expect('<')
        val name = name()
        val raw = mutableListOf<Pair<String, String>>()
        while (true) {
            val spaced = skipSpace()
            if (i >= s.length) fail("an unterminated start tag <$name>")
            if (s[i] == '/' || s[i] == '>') break
            if (!spaced) fail("attributes of <$name> must be separated by whitespace")
            val attr = name()
            skipSpace()
            expect('=')
            skipSpace()
            val value = attributeValue()
            if (raw.any { it.first == attr }) fail("the attribute $attr of <$name> is repeated")
            raw.add(attr to value)
        }
        var scope = outer
        if (namespaceAware) {
            val declared = raw.filter { it.first == "xmlns" || it.first.startsWith("xmlns:") }
            if (declared.isNotEmpty()) {
                scope = outer.toMutableMap().apply {
                    for ((attr, value) in declared) put(attr.substringAfter("xmlns", "").removePrefix(":"), value)
                }
            }
        }
        val attrs = raw.map { (attr, value) ->
            if (!namespaceAware) {
                Attr(attr, null, attr, value)
            } else if (attr == "xmlns" || attr.startsWith("xmlns:")) {
                Attr(attr, XMLNS_NS, if (attr == "xmlns") "xmlns" else attr.substringAfter(':'), value)
            } else if (':' in attr) {
                val prefix = attr.substringBefore(':')
                val uri = scope[prefix] ?: fail("the prefix $prefix of $attr is not declared")
                Attr(attr, uri, attr.substringAfter(':'), value)
            } else {
                Attr(attr, null, attr, value)
            }
        }
        val element = if (!namespaceAware) {
            Element(name, null, name, attrs, emptyMap())
        } else {
            val prefix = name.substringBefore(':', "")
            val uri = scope[prefix]?.ifEmpty { null }
            if (prefix.isNotEmpty() && uri == null) fail("the prefix $prefix of <$name> is not declared")
            Element(name, uri, name.substringAfter(':'), attrs, scope)
        }
        if (s.startsWith("/>", i)) {
            i += 2
            return element
        }
        expect('>')
        content(element, scope)
        if (!s.startsWith("</", i)) fail("<$name> is not closed")
        i += 2
        val end = name()
        if (end != name) fail("</$end> closes <$name>")
        skipSpace()
        expect('>')
        return element
    }

    private fun content(parent: Element, scope: Map<String, String>) {
        val text = StringBuilder()
        fun flush() {
            if (text.isEmpty()) return
            val t = text.toString()
            text.clear()
            if (ignoreWhitespace && t.isBlank()) return
            append(parent, Text(t))
        }
        while (true) {
            if (i >= s.length) fail("<${parent.tagName}> is not closed")
            val c = s[i]
            when {
                s.startsWith("</", i) -> {
                    flush()
                    return
                }
                s.startsWith("<!--", i) -> {
                    flush()
                    skipPast("-->")
                }
                s.startsWith("<![CDATA[", i) -> {
                    val end = s.indexOf("]]>", i + 9)
                    if (end < 0) fail("an unterminated CDATA section")
                    text.append(s, i + 9, end)
                    i = end + 3
                }
                s.startsWith("<?", i) -> {
                    flush()
                    skipPast("?>")
                }
                c == '<' -> {
                    flush()
                    append(parent, element(scope))
                }
                c == '&' -> text.append(reference())
                else -> {
                    text.append(c)
                    i++
                }
            }
        }
    }

    private fun append(parent: Node, child: Node) {
        child.parentNode = parent
        parent.children.add(child)
    }

    private fun attributeValue(): String {
        if (i >= s.length) fail("an attribute value is missing")
        val quote = s[i]
        if (quote != '"' && quote != '\'') fail("an attribute value must be quoted")
        i++
        val out = StringBuilder()
        while (true) {
            if (i >= s.length) fail("an unterminated attribute value")
            val c = s[i]
            when {
                c == quote -> {
                    i++
                    return out.toString()
                }
                c == '<' -> fail("'<' in an attribute value")
                c == '&' -> out.append(reference())
                // Attribute-value normalization: whitespace characters become spaces.
                c == '\t' || c == '\n' || c == '\r' -> {
                    out.append(' ')
                    i++
                }
                else -> {
                    out.append(c)
                    i++
                }
            }
        }
    }

    private fun reference(): String {
        val end = s.indexOf(';', i)
        if (end < 0) fail("an unterminated entity reference")
        val ref = s.substring(i + 1, end)
        i = end + 1
        return when {
            ref == "lt" -> "<"
            ref == "gt" -> ">"
            ref == "amp" -> "&"
            ref == "quot" -> "\""
            ref == "apos" -> "'"
            ref.startsWith("#x") -> codePoint(ref.substring(2).toIntOrNull(16), ref)
            ref.startsWith("#") -> codePoint(ref.substring(1).toIntOrNull(), ref)
            else -> fail("the entity &$ref; is not declared")
        }
    }

    private fun codePoint(cp: Int?, ref: String): String {
        if (cp == null || cp < 0 || cp > 0x10FFFF) fail("&$ref; is not a character")
        if (cp < 0x10000) return cp.toChar().toString()
        val v = cp - 0x10000
        return charArrayOf(((v shr 10) + 0xD800).toChar(), ((v and 0x3FF) + 0xDC00).toChar()).concatToString()
    }

    private fun name(): String {
        val start = i
        while (i < s.length && isNameChar(s[i], i == start)) i++
        if (i == start) fail("a name is expected")
        return s.substring(start, i)
    }

    private fun isNameChar(c: Char, first: Boolean): Boolean =
        c.isLetter() || c == '_' || c == ':' || c.code >= 0x80 ||
            (!first && (c.isDigit() || c == '-' || c == '.'))

    private fun skipSpace(): Boolean {
        val start = i
        while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        return i > start
    }

    private fun skipPast(end: String) {
        val at = s.indexOf(end, i)
        if (at < 0) fail("an unterminated ${if (end == "-->") "comment" else "declaration"}")
        i = at + end.length
    }

    private fun expect(c: Char) {
        if (i >= s.length || s[i] != c) fail("'$c' is expected")
        i++
    }

    private fun fail(message: String): Nothing {
        var line = 1
        var column = 1
        for (k in 0 until minOf(i, s.length)) {
            if (s[k] == '\n') {
                line++
                column = 1
            } else {
                column++
            }
        }
        throw SAXParseException(message, line, column)
    }
}
