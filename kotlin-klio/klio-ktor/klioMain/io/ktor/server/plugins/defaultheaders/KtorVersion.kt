/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The file upstream's `generateKtorVersionFile` Gradle task writes into the
// module's generated sources; the version is the pack's.

package io.ktor.server.plugins.defaultheaders

internal const val KTOR_VERSION: String = "3.5.2"
