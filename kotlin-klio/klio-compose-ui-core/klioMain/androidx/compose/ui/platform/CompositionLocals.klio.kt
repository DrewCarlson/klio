// Adapted from compose-multiplatform-core skikoMain (v1.12.0),
// androidx/compose/ui/platform/CompositionLocals.skiko.kt. The skiko file also
// provides the locals of a skiko ComposeScene's PlatformContext (screen reader,
// window insets, lifecycle and saved-state owners); klio's host has no
// PlatformContext and provides its own locals (ProvideKlioCompositionLocals), so
// only the platform-independent declarations are kept.
/*
 * Copyright 2024 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package androidx.compose.ui.platform

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.InternalComposeUiApi
import androidx.lifecycle.LifecycleOwner

/**
 * The CompositionLocal containing the current [LifecycleOwner].
 */
@Deprecated(
    "Moved to lifecycle-runtime-compose library in androidx.lifecycle.compose package.",
    ReplaceWith("androidx.lifecycle.compose.LocalLifecycleOwner"),
    level = DeprecationLevel.HIDDEN
)
actual val LocalLifecycleOwner get() = androidx.lifecycle.compose.LocalLifecycleOwner

/**
 * The window insets of the current scene, which klio's host provides as none,
 * as a desktop window has.
 */
@InternalComposeUiApi
val LocalPlatformWindowInsets = staticCompositionLocalOf<PlatformWindowInsets> {
    error("CompositionLocal LocalPlatformWindowInsets not present")
}

/**
 * The CompositionLocal providing prefetch scheduler associated with the current scene.
 */
@InternalComposeUiApi
val LocalPlatformPrefetchScheduler = staticCompositionLocalOf<PlatformPrefetchScheduler> {
    error("CompositionLocal LocalPlatformPrefetchScheduler not present")
}
