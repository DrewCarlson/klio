/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.text.font

// The native target resolves fonts with the default interceptor on every OS.
internal actual fun createPlatformResolveInterceptor(): PlatformResolveInterceptor =
    PlatformResolveInterceptor.Default
