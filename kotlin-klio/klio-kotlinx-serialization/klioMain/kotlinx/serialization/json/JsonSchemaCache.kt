// klio actual for `Json.schemaCache` (upstream Json.kt `expect`): the cache
// lives on the Json instance itself, as jvmMain does.

package kotlinx.serialization.json

import kotlinx.serialization.json.internal.DescriptorSchemaCache

internal actual val Json.schemaCache: DescriptorSchemaCache
    get() = this._schemaCache
