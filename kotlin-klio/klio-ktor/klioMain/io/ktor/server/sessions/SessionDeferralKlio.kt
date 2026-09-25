/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copy of ktor-server-sessions' posix `SessionDeferral.posix.kt`: the
// deferred-sessions flag read from the process environment through the host
// instead of cinterop `getenv`.

package io.ktor.server.sessions

import io.ktor.util.__kktor_getenv

internal actual fun isDeferredSessionsEnabled(): Boolean =
    __kktor_getenv(SESSIONS_DEFERRED_FLAG)?.toBoolean() == true
