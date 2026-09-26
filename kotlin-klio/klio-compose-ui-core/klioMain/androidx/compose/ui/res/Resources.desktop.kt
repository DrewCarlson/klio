// Vendored from compose-multiplatform-core desktopMain (v1.12.0),
// androidx/compose/ui/res/Resources.desktop.kt, reading the program's
// resources (klio.bundle.Resources) where the JVM reads its class loader's.
/*
 * Copyright 2021 The Android Open Source Project
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

package androidx.compose.ui.res

import klio.bundle.Resources
import klio.io.ByteArrayInputStream
import klio.io.InputStream

/**
 * Open [InputStream] from a resource stored in resources for the application, calls the [block]
 * callback giving it a InputStream and closes stream once the processing is
 * complete.
 *
 * @param resourcePath  path of resource
 * @return object that was returned by [block]
 *
 * @throws IllegalArgumentException if there is no [resourcePath] in resources
 */
@Suppress("DEPRECATION")
@Deprecated("Migrate to the Compose resources library. See https://www.jetbrains.com/help/kotlin-multiplatform-dev/compose-images-resources.html")
inline fun <T> useResource(
    resourcePath: String,
    block: (InputStream) -> T
): T = openResource(resourcePath).use(block)

/**
 * Open [InputStream] from a resource stored in resources for the application.
 *
 * @param resourcePath  path of resource
 *
 * @throws IllegalArgumentException if there is no [resourcePath] in resources
 */
@PublishedApi
@Suppress("DEPRECATION")
@Deprecated("Migrate to the Compose resources library. See https://www.jetbrains.com/help/kotlin-multiplatform-dev/compose-images-resources.html")
internal fun openResource(
    resourcePath: String,
): InputStream = ClassLoaderResourceLoader.load(resourcePath)

/**
 * Resource loader over the program's resources: the files `--include` (or the
 * manifest's `[application] include`) names, embedded in its bundle or read
 * from disk under `klio run`, as the JVM's class loader serves its classpath's.
 */
private object ClassLoaderResourceLoader {
    fun load(resourcePath: String): InputStream {
        val path = resourcePath.removePrefix("/")
        require(Resources.exists(path)) { "Resource $resourcePath not found" }
        return ByteArrayInputStream(Resources.readBytes(path))
    }
}
