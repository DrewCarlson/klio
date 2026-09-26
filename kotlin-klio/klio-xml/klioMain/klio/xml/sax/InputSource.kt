/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The input a document builder reads and the error it throws, in the shape
// of org.xml.sax's.

package klio.xml.sax

import klio.io.InputStream

/** A document's input: a byte stream, read as UTF-8, or text. */
class InputSource() {
    var byteStream: InputStream? = null
    var characterStream: String? = null

    constructor(byteStream: InputStream) : this() {
        this.byteStream = byteStream
    }

    internal fun readText(): String =
        characterStream ?: byteStream?.readAllBytes()?.decodeToString()
            ?: throw IllegalArgumentException("an InputSource has neither a byte stream nor text")
}

/** A document that is not well-formed: what is wrong and where. */
open class SAXException(message: String?) : Exception(message)

class SAXParseException(
    message: String,
    val lineNumber: Int,
    val columnNumber: Int,
) : SAXException("$message (line $lineNumber, column $columnNumber)")
