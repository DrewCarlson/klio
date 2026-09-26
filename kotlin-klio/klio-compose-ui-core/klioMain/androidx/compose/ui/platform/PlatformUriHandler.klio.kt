/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// LocalUriHandler's: a link opens with the platform's handler for it, as the
// desktop's opens it through java.awt.Desktop.

package androidx.compose.ui.platform

private class KlioUriHandler : UriHandler {
    override fun openUri(uri: String) {
        if (!__composeui_openUri(uri)) {
            throw IllegalArgumentException("The platform cannot open $uri")
        }
    }
}

internal actual fun createPlatformUriHandler(): UriHandler = KlioUriHandler()

// Opens a URI with the platform's handler; false when it could not.
internal fun __composeui_openUri(uri: String): Boolean =
    error("intrinsic androidx.compose.ui.platform.__composeui_openUri not installed")
