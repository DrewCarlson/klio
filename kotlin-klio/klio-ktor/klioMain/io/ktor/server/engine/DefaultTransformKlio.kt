/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The server's receive transformations for multipart bodies. Upstream's
// native actual refuses multipart ("Multipart is not supported in native");
// the JVM's parses it with ktor-http-cio's CIOMultipartDataBase, which is
// common code, so klio's actual is the JVM's without its InputStream case.

package io.ktor.server.engine

import io.ktor.http.*
import io.ktor.http.cio.*
import io.ktor.http.cio.internals.*
import io.ktor.http.content.*
import io.ktor.server.application.*
import io.ktor.server.plugins.UnsupportedMediaTypeException
import io.ktor.server.request.*
import io.ktor.util.pipeline.*
import io.ktor.utils.io.*
import kotlinx.coroutines.*

internal actual suspend fun PipelineContext<Any, PipelineCall>.defaultPlatformTransformations(
    query: Any
): Any? {
    val channel = query as? ByteReadChannel ?: return null

    return when (call.receiveType.type) {
        MultiPartData::class -> multiPartData(channel)
        else -> null
    }
}

@OptIn(InternalAPI::class)
internal actual fun PipelineContext<*, PipelineCall>.multiPartData(rc: ByteReadChannel): MultiPartData {
    val contentType = call.request.header(HttpHeaders.ContentType)
        ?: throw UnsupportedMediaTypeException(null)

    val contentLength = call.request.header(HttpHeaders.ContentLength)?.toLong()

    try {
        return CIOMultipartDataBase(
            coroutineContext + Dispatchers.Unconfined,
            rc,
            contentType,
            contentLength,
            formFieldLimit = call.formFieldLimit
        )
    } catch (_: UnsupportedMediaTypeExceptionCIO) {
        throw UnsupportedMediaTypeException(ContentType.parse(contentType))
    }
}
