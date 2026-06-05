// klio's `HttpClientEngine` implementation for the upstream client core (the
// "custom actual" the architecture calls for). It drives the request through
// the host `__kktor_request` binding (backed by `ureq` in
// klio-ktor-client/src/lib.rs) and wraps the response bytes in a buffered,
// read-side `ByteReadChannel` — the shape `HttpResponse` drains. Gated under
// the `client-upstream` feature (the stage-3 swap of `shim/client`).

package io.ktor.client.engine.klio

import io.ktor.client.engine.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.http.content.*
import io.ktor.util.date.GMTDate
import io.ktor.utils.io.*
import kotlin.coroutines.coroutineContext

public class KlioClientEngineConfig : HttpClientEngineConfig()

/**
 * Engine factory: `HttpClient(KlioClient) { … }`.
 */
public object KlioClient : HttpClientEngineFactory<KlioClientEngineConfig> {
    override fun create(block: KlioClientEngineConfig.() -> Unit): HttpClientEngine =
        KlioClientEngine(KlioClientEngineConfig().apply(block))
}

public class KlioClientEngine(
    override val config: KlioClientEngineConfig,
) : HttpClientEngineBase("klio") {

    override val supportedCapabilities: Set<HttpClientEngineCapability<*>> = emptySet()

    override suspend fun execute(data: HttpRequestData): HttpResponseData {
        val bodyText = when (val body = data.body) {
            is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
            else -> ""
        }
        val flat = ArrayList<String>()
        data.headers.forEach { key, values ->
            for (value in values) {
                flat.add(key)
                flat.add(value)
            }
        }
        val parts = __kktor_request(
            data.method.value,
            data.url.toString(),
            bodyText,
            flat.toTypedArray(),
        )
        val statusCode = HttpStatusCode.fromValue(parts[0].toInt())
        val respHeaders = HeadersBuilder()
        var i = 3
        while (i + 1 < parts.size) {
            respHeaders.append(parts[i], parts[i + 1])
            i += 2
        }
        return HttpResponseData(
            statusCode = statusCode,
            requestTime = GMTDate(),
            headers = respHeaders.build(),
            version = HttpProtocolVersion.HTTP_1_1,
            body = ByteReadChannel(parts[1].encodeToByteArray()),
            callContext = coroutineContext,
        )
    }
}
