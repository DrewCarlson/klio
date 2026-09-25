/*
 * Copyright 2014-2026 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The static-content marker from upstream's JVM StaticContent.kt, which the
// plugins read (CallLogging's `disableForStaticContent`). The static file and
// resource routes themselves are built on java.io.File and the class path,
// and klio does not serve them yet.

package io.ktor.server.http.content

import io.ktor.server.application.*
import io.ktor.util.*

/**
 * Attribute that is added by static routes to the call's attributes containing the path to the requested file
 * when a static file or resource is handled. The value is typically the resolved file path or the requested
 * relative resource path.
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.server.http.content.StaticFileLocationProperty)
 */
public val StaticFileLocationProperty: AttributeKey<String> = AttributeKey("StaticFileLocation")

/**
 * Returns `true` if static content is being served for this call.
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.server.http.content.isStaticContent)
 */
public fun ApplicationCall.isStaticContent(): Boolean = attributes.contains(StaticFileLocationProperty)
