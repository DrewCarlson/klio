/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// Upstream's JVM CompressionTest.kt on klio. The cases and assertions are
// upstream's, with the JVM-only pieces replaced: responses are decoded with
// GZipEncoder and DeflateEncoder instead of java.util.zip streams, the
// request bodies are encoded with them instead of the JVM-only `GZip` and
// `Deflate` values, and dates are GMTDate instead of java.time. The zstd
// encoder (ktor-server-compression-zstd, over zstd-jni) has no klio
// counterpart: its own cases are left out, `zstdStandard()` is `default()`,
// and the zstd lines of the mixed cases are removed. A body read as text uses
// decodeToString instead of the JVM's ByteArray.toString(Charset), and
// testRespondWrite is left out: respondTextWriter is built on java.io.Writer.

package io.ktor.server.plugins

import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.http.content.*
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.install
import io.ktor.server.http.*
import io.ktor.server.http.content.*
import io.ktor.server.plugins.cachingheaders.*
import io.ktor.server.plugins.compression.*
import io.ktor.server.plugins.conditionalheaders.*
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.sse.*
import io.ktor.server.testing.*
import io.ktor.util.*
import io.ktor.util.date.*
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestResult
import kotlinx.io.readByteArray
import kotlinx.serialization.Serializable
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

class CompressionTest {
    private val textToCompress = "text to be compressed\n".repeat(100)
    private val textToCompressAsBytes = textToCompress.encodeToByteArray()

    @Test
    fun testVaryHeaderPresent() = testApplication {
        install(Compression)

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip", "gzip", textToCompress, HttpHeaders.AcceptEncoding)
    }

    @Test
    fun testCompressionNotSpecified() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", null, null, textToCompress)
    }

    @Test
    fun testCompressionUnknownAcceptedEncodings() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "a,b,c", null, textToCompress)
    }

    @Test
    fun testCompressionDefaultDeflate() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "deflate", "deflate", textToCompress)
    }

    @Test
    fun testCompressionDefaultGzip() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip,deflate", "gzip", textToCompress)
    }

    @Test
    fun testAcceptStarContentEncodingGzip() = testApplication {
        install(Compression) {
            gzip()
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "*", "gzip", textToCompress)
    }

    @Test
    fun testShouldNotCompressVideoByDefault() = testApplication {
        install(Compression)

        routing {
            get("/") {
                call.respondText(textToCompress, ContentType.Video.MP4)
            }
        }

        handleAndAssert("/", "*", null, textToCompress)
    }

    @Test
    fun testGzipShouldNotCompressVideoByDefault() = testApplication {
        install(Compression) {
            gzip()
        }

        routing {
            get("/") {
                call.respondText(textToCompress, ContentType.Video.MP4)
            }
        }

        handleAndAssert("/", "*", null, textToCompress)
    }

    @Test
    fun testAcceptStarContentEncodingDeflate() = testApplication {
        install(Compression) {
            deflate()
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "*", "deflate", textToCompress)
    }

    @Test
    fun testUnknownEncodingListedEncoding() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "special,gzip,deflate", "gzip", textToCompress)
    }

    @Test
    fun testCustomEncoding() = testApplication {
        install(Compression) {
            default()
            encoder(
                object : ContentEncoder {
                    override val name: String = "special"

                    override fun encode(
                        source: ByteReadChannel,
                        coroutineContext: CoroutineContext
                    ) = source

                    override fun encode(
                        source: ByteWriteChannel,
                        coroutineContext: CoroutineContext
                    ) = source

                    override fun decode(
                        source: ByteReadChannel,
                        coroutineContext: CoroutineContext
                    ): ByteReadChannel = source
                }
            )
        }
        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        val response = client.get("/") {
            header(HttpHeaders.AcceptEncoding, "special")
        }
        assertEquals(HttpStatusCode.OK, response.status)
        assertEquals("special", response.headers[HttpHeaders.ContentEncoding])
        assertEquals(textToCompress, response.bodyAsBytes().decodeToString())
    }

    @Test
    fun testStatusCode() = testApplication {
        install(Compression)
        routing {
            get("/") {
                call.respondText(textToCompress, status = HttpStatusCode.Found)
            }
        }

        val response = client.config { followRedirects = false }.get("/") {
            header(HttpHeaders.AcceptEncoding, "*")
        }
        assertEquals(HttpStatusCode.Found, response.status)
    }

    @Test
    fun testMinSize() = testApplication {
        install(Compression) {
            minimumSize(10)
        }

        routing {
            get("/small") {
                call.respondText("0123")
            }
            get("/big") {
                call.respondText("01234567890123456789")
            }
            get("/stream") {
                call.respondText("stream content")
            }
        }

        handleAndAssert("/big", "gzip,deflate", "gzip", "01234567890123456789")
        handleAndAssert("/small", "gzip,deflate", null, "0123")
        handleAndAssert("/stream", "gzip,deflate", "gzip", "stream content")
    }

    @Test
    fun testMinSizeGzip() = testApplication {
        install(Compression) {
            gzip()
            minimumSize(10)
        }

        routing {
            get("/small") {
                call.respondText("0123")
            }
            get("/big") {
                call.respondText("01234567890123456789")
            }
            get("/stream") {
                call.respondText("stream content")
            }
        }

        handleAndAssert("/big", "gzip,deflate", "gzip", "01234567890123456789")
        handleAndAssert("/small", "gzip,deflate", null, "0123")
        handleAndAssert("/stream", "gzip,deflate", "gzip", "stream content")
    }

    @Test
    fun testMimeTypes() = testApplication {
        install(Compression) {
            default()
            matchContentType(ContentType.Text.Any)
            excludeContentType(ContentType.Text.VCard)
        }

        routing {
            get("/") {
                call.respondText(textToCompress, ContentType.parse(call.parameters["t"]!!))
            }
        }

        handleAndAssert("/?t=text/plain", "gzip,deflate", "gzip", textToCompress)
        handleAndAssert("/?t=text/vcard", "gzip,deflate", null, textToCompress)
        handleAndAssert("/?t=some/other", "gzip,deflate", null, textToCompress)
    }

    @Test
    fun testEncoderLevelCondition() = testApplication {
        install(Compression) {
            gzip {
                condition {
                    parameters["e"] == "1"
                }
            }
            deflate()
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/?e=1", "gzip", "gzip", textToCompress)
        handleAndAssert("/?e", "gzip", null, textToCompress)
        handleAndAssert("/?e", "gzip,deflate", "deflate", textToCompress)
    }

    @Test
    fun testEncoderPriority1() = testApplication {
        install(Compression) {
            gzip {
                priority = 10.0
            }
            deflate {
                priority = 1.0
            }
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip", "gzip", textToCompress)
        handleAndAssert("/", "deflate", "deflate", textToCompress)
        handleAndAssert("/", "gzip,deflate", "gzip", textToCompress)
    }

    @Test
    fun testEncoderPriority2() = testApplication {
        install(Compression) {
            gzip {
                priority = 1.0
            }
            deflate {
                priority = 10.0
            }
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip", "gzip", textToCompress)
        handleAndAssert("/", "deflate", "deflate", textToCompress)
        handleAndAssert("/", "gzip,deflate", "deflate", textToCompress)
    }

    @Test
    fun testEncoderQuality() = testApplication {
        install(Compression) {
            gzip()
            deflate()
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip", "gzip", textToCompress)
        handleAndAssert("/", "deflate", "deflate", textToCompress)
        handleAndAssert("/", "gzip;q=1,deflate;q=0.1", "gzip", textToCompress)
        handleAndAssert("/", "gzip;q=0.1,deflate;q=1", "deflate", textToCompress)
    }

    @Test
    fun testCustomCondition() = testApplication {
        install(Compression) {
            default()
            condition {
                parameters["compress"] == "true"
            }
        }

        routing {
            get("/") {
                call.respondText(textToCompress)
            }
        }

        handleAndAssert("/", "gzip,deflate", null, textToCompress)
        handleAndAssert("/?compress=true", "gzip,deflate", "gzip", textToCompress)
    }

    @Test
    fun testWithConditionalHeaders() = testApplication {
        val dateTime = GMTDate(getTimeMillis() / 1000 * 1000)

        install(ConditionalHeaders)
        install(CachingHeaders)
        install(Compression)

        routing {
            get("/") {
                call.respond(
                    object : OutgoingContent.ReadChannelContent() {
                        init {
                            versions += LastModifiedVersion(dateTime)
                            caching = CachingOptions(
                                cacheControl = CacheControl.NoCache(CacheControl.Visibility.Public),
                                expires = dateTime
                            )
                        }

                        override val contentType = ContentType.Text.Plain
                        override val contentLength = textToCompressAsBytes.size.toLong()
                        override fun readFrom() = ByteReadChannel(textToCompressAsBytes)
                    }
                )
            }
        }

        handleAndAssert("/", "gzip", "gzip", textToCompress).let { response ->
            assertEquals("text/plain", response.headers[HttpHeaders.ContentType])
            assertEquals(dateTime.toHttpDate(), response.headers[HttpHeaders.Expires])
            assertEquals("no-cache, public", response.headers[HttpHeaders.CacheControl])
            assertFalse { HttpHeaders.ContentLength in response.headers }
            assertEquals(dateTime.toHttpDate(), response.headers[HttpHeaders.LastModified])
        }

        client.get("/") {
            header(HttpHeaders.IfModifiedSince, dateTime.toHttpDate())
        }.let { response ->
            assertEquals(HttpStatusCode.NotModified, response.status)
        }

        client.get("/") {
            header(HttpHeaders.AcceptEncoding, "gzip")
            header(HttpHeaders.IfModifiedSince, dateTime.toHttpDate())
        }.let { response ->
            assertEquals(HttpStatusCode.NotModified, response.status)
        }

        client.get("/") {
            header(HttpHeaders.AcceptEncoding, "gzip")
            header(HttpHeaders.IfModifiedSince, GMTDate(dateTime.timestamp - 3_600_000).toHttpDate())
        }.let { response ->
            assertEquals(HttpStatusCode.OK, response.status)
            assertEquals("gzip", response.headers[HttpHeaders.ContentEncoding])
        }

        client.get("/") {
            header(HttpHeaders.IfModifiedSince, GMTDate(dateTime.timestamp - 3_600_000).toHttpDate())
        }.let { response ->
            assertEquals(HttpStatusCode.OK, response.status)
            assertNull(response.headers[HttpHeaders.ContentEncoding])
        }
    }

    @Test
    fun testLargeContent() = testApplication {
        val content = buildString {
            for (i in 1..16384) {
                append("test$i\n".padStart(10, ' '))
            }
        }

        install(Compression) {
            default()
        }
        routing {
            get("/") {
                call.respondText(content)
            }
        }

        handleAndAssert("/", "deflate", "deflate", content)
        handleAndAssert("/", "gzip", "gzip", content)
    }

    @Test
    fun testCompressionRespondBytes() = testApplication {
        install(Compression)

        routing {
            get("/") {
                call.respond(
                    object : OutgoingContent.WriteChannelContent() {
                        override suspend fun writeTo(channel: ByteWriteChannel) {
                            channel.writeStringUtf8("Hello!")
                        }
                    }
                )
            }
        }

        handleAndAssert("/", "gzip", "gzip", "Hello!")
    }

    @Test
    fun testIdentityRequested() = testApplication {
        install(Compression)

        routing {
            get("/text") {
                call.respondText(textToCompress)
            }
            get("/bytes") {
                call.respondBytes(textToCompressAsBytes, ContentType.Application.OctetStream)
            }
        }

        handleAndAssert("/text", "identity", "identity", textToCompress)
        handleAndAssert("/bytes", "identity", "identity", textToCompress)
    }

    @Test
    fun testCompressionRespondObjectWithIdentity() = testApplication {
        install(Compression)

        routing {
            get("/") {
                call.respond(
                    object : OutgoingContent.ByteArrayContent() {
                        override val headers: Headers
                            get() = Headers.build {
                                appendAll(super.headers)
                                append(HttpHeaders.ContentEncoding, "identity")
                            }

                        override fun bytes(): ByteArray = "Hello!".toByteArray()

                        override val contentLength: Long
                            get() = 6
                    }
                )
            }
        }

        handleAndAssert("/", "gzip", "identity", "Hello!")
    }

    @Test
    fun testCompressionUpgradeShouldNotBeCompressed() = testApplication {
        install(Compression)

        routing {
            get("/") {
                call.respond(
                    object : OutgoingContent.ProtocolUpgrade() {
                        override suspend fun upgrade(
                            input: ByteReadChannel,
                            output: ByteWriteChannel,
                            engineContext: CoroutineContext,
                            userContext: CoroutineContext
                        ): Job {
                            return coroutineScope {
                                launch { output.flushAndClose() }
                            }
                        }
                    }
                )
            }
        }

        client.get("/").let { response ->
            assertEquals(101, response.status.value)
            assertNull(response.headers[HttpHeaders.ContentEncoding])
        }
    }

    @Test
    fun testCompressionContentTypesShouldNotBeCompressed() = testApplication {
        install(Compression)

        routing {
            get("/event-stream") {
                call.respondText("events", ContentType.Text.EventStream)
            }
            get("/video") {
                call.respondBytes("video".toByteArray(), ContentType.Video.MPEG)
            }
            get("/multipart") {
                call.respondBytes(
                    ">>>\r\nContent-Disposition: form-data; name=\"title\"\r\n>>>--".toByteArray(),
                    ContentType.MultiPart.FormData.withParameter("boundary", ">>>")
                )
            }
        }

        client.get("/event-stream").let { response ->
            assertEquals(200, response.status.value)
            assertNull(response.headers[HttpHeaders.ContentEncoding])
            assertEquals("events", response.bodyAsText())
            assertEquals(ContentType.Text.EventStream, response.contentType()?.withoutParameters())
        }
        client.get("/video").let { response ->
            assertEquals(200, response.status.value)
            assertNull(response.headers[HttpHeaders.ContentEncoding])
            assertEquals("video", response.bodyAsText())
            assertEquals(ContentType.Video.MPEG, response.contentType())
        }
        client.get("/multipart").let { response ->
            assertEquals(200, response.status.value)
            assertNull(response.headers[HttpHeaders.ContentEncoding])
            assertEquals(ContentType.MultiPart.FormData, response.contentType()?.withoutParameters())
        }
    }

    @Test
    fun testSubrouteInstall() = testApplication {
        routing {
            route("1") {
                install(Compression) {
                    deflate()
                }
                get { call.respond(textToCompress) }
            }
            get("2") { call.respond(textToCompress) }
        }

        handleAndAssert("/1", "*", "deflate", textToCompress)
        handleAndAssert("/2", "*", null, textToCompress)
    }

    @Test
    fun testResponseShouldBeSentAfterCompression() = testApplication {
        install(Compression)
        routing {
            get("/isSent") {
                call.respond(textToCompress)
                assertTrue(call.response.isSent)
            }
        }

        client.get("/isSent") {
            headers {
                append(HttpHeaders.AcceptEncoding, "gzip")
            }
        }
    }

    @Test
    fun testDecoding() = testApplication {
        install(Compression) {
            default()
            maxEncodingChainLength = 5
        }
        routing {
            post("/identity") {
                val message = call.receiveText()
                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertEquals(listOf("identity"), call.request.appliedDecoders)

                call.respond(message)
            }
            post("/gzip") {
                val message = call.receiveText()

                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertEquals(listOf("gzip"), call.request.appliedDecoders)

                call.respond(message)
            }
            post("/deflate") {
                val message = call.receiveText()
                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertEquals(listOf("deflate"), call.request.appliedDecoders)
                call.respond(message)
            }
            post("/multiple") {
                val message = call.receiveText()
                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertEquals(listOf("identity", "deflate", "gzip"), call.request.appliedDecoders)
                call.respond(message)
            }
            post("/unknown") {
                assertEquals("unknown", call.request.headers[HttpHeaders.ContentEncoding])
                assertEquals(emptyList(), call.request.appliedDecoders)
                call.respond(call.receiveText())
            }
        }

        val responseIdentity = client.post("/identity") {
            setBody(Identity.encode(ByteReadChannel(textToCompressAsBytes)))
            header(HttpHeaders.ContentEncoding, "identity")
        }
        assertEquals(textToCompress, responseIdentity.bodyAsText())

        val responseGzip = client.post("/gzip") {
            setBody(GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)))
            header(HttpHeaders.ContentEncoding, "gzip")
        }
        assertEquals(textToCompress, responseGzip.bodyAsText())

        val responseDeflate = client.post("/deflate") {
            setBody(DeflateEncoder.encode(ByteReadChannel(textToCompressAsBytes)))
            header(HttpHeaders.ContentEncoding, "deflate")
        }
        assertEquals(textToCompress, responseDeflate.bodyAsText())

        val responseMultiple = client.post("/multiple") {
            setBody(
                Identity.encode(
                    DeflateEncoder.encode(
                        GZipEncoder.encode(
                            ByteReadChannel(
                                textToCompressAsBytes
                            )
                        )
                    )
                )
            )
            header(HttpHeaders.ContentEncoding, "identity,deflate,gzip")
        }
        assertEquals(textToCompress, responseMultiple.bodyAsText())

        val responseUnknown = client.post("/unknown") {
            setBody("unknown")
            header(HttpHeaders.ContentEncoding, "unknown")
        }
        assertEquals("unknown", responseUnknown.bodyAsText())
    }

    @Test
    fun testSkipCompressionForSSEResponse() = testApplication {
        install(Compression) {
            deflate {
                minimumSize(1024)
            }
        }
        install(SSE)

        routing {
            sse {
                send("Hello")
            }
        }

        client.get {
            header(HttpHeaders.AcceptEncoding, "*")
        }.apply {
            assertNull(headers[HttpHeaders.ContentEncoding], "SSE response shouldn't be compressed")
        }
    }

    @Test
    fun testDisableDecoding() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()

        install(Compression) {
            mode = CompressionConfig.Mode.CompressResponse
        }
        routing {
            post("/gzip") {
                assertEquals("gzip", call.request.headers[HttpHeaders.ContentEncoding])
                val body = call.receive<ByteArray>()
                assertContentEquals(compressed, body)
                call.respond(textToCompress)
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            header(HttpHeaders.ContentEncoding, "gzip")
            header(HttpHeaders.AcceptEncoding, "gzip")
        }
        assertContentEquals(compressed, response.body<ByteArray>())
    }

    @Test
    fun testDisableEncoding() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()

        install(Compression) {
            mode = CompressionConfig.Mode.DecompressRequest
        }
        routing {
            post("/gzip") {
                val body = call.receive<ByteArray>()

                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertContentEquals(textToCompressAsBytes, body)

                call.respond(textToCompressAsBytes)
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            header(HttpHeaders.ContentEncoding, "gzip")
            header(HttpHeaders.AcceptEncoding, "gzip")
        }
        assertContentEquals(textToCompressAsBytes, response.body<ByteArray>())
    }

    @Test
    fun testDisableCallEncoding() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()
        install(Compression)

        routing {
            post("/gzip") {
                call.suppressCompression()

                val body = call.receive<ByteArray>()

                assertEquals("gzip", call.request.appliedDecoders.first())
                assertNull(call.request.headers[HttpHeaders.ContentEncoding])
                assertContentEquals(textToCompressAsBytes, body)

                call.respond(textToCompressAsBytes)
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            header(HttpHeaders.ContentEncoding, "gzip")
            header(HttpHeaders.AcceptEncoding, "gzip")
        }
        assertContentEquals(textToCompressAsBytes, response.body<ByteArray>())
    }

    @Test
    fun testDisableCallDecoding() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()

        install(Compression)
        routing {
            post("/gzip") {
                call.suppressDecompression()
                assertEquals("gzip", call.request.headers[HttpHeaders.ContentEncoding])
                val body = call.receive<ByteArray>()
                assertContentEquals(compressed, body)
                call.respond(textToCompress)
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            header(HttpHeaders.ContentEncoding, "gzip")
            header(HttpHeaders.AcceptEncoding, "gzip")
        }
        assertContentEquals(compressed, response.body<ByteArray>())
    }

    @Test
    fun `body should be decompressed by compression plugin before receiving as ByteArray`() = testApplication {
        application {
            install(Compression) {
                mode = CompressionConfig.Mode.DecompressRequest
                gzip()
            }

            routing {
                post("/") {
                    val body = call.receive<ByteArray>()
                    call.respond(body)
                }
            }
        }

        val expectedBody = "deadbeef".hexToByteArray()

        val responseBytes = client.post("/") {
            val compressedBody = GZipEncoder.encode(ByteReadChannel(expectedBody)).readRemaining().readByteArray()
            setBody(compressedBody)
            header(HttpHeaders.ContentEncoding, "gzip")
        }.bodyAsBytes()

        assertEquals(expectedBody.toHexString(), responseBytes.toHexString())
    }

    @Test
    fun `body should be decompressed by compression plugin before receiving as multipart`() = testApplication {
        application {
            install(Compression) {
                mode = CompressionConfig.Mode.DecompressRequest
                gzip()
            }

            routing {
                post("/multipart") {
                    call.respondText(
                        buildString {
                            appendLine("START")
                            call.receiveMultipart().forEachPart { partData ->
                                if (partData is PartData.FormItem) {
                                    appendLine("${partData.name}=${partData.value}")
                                }
                                partData.dispose()
                            }
                            appendLine("END")
                        }
                    )
                }
            }
        }
        val multipart = MultiPartFormDataContent(
            formData {
                append("test", "test")
            }
        )
        val channel = ByteChannel()

        val multipartBytes = coroutineScope {
            launch {
                multipart.writeTo(channel)
            }
            channel.toByteArray()
        }
        val responseText = client.post("/multipart") {
            val compressedBody = GZipEncoder.encode(ByteReadChannel(multipartBytes)).readRemaining().readByteArray()
            setBody(compressedBody)
            header(
                HttpHeaders.ContentType,
                ContentType.MultiPart.FormData.withParameter("boundary", multipart.boundary)
            )
            header(HttpHeaders.ContentEncoding, "gzip")
        }.bodyAsText()

        assertEquals("START\ntest=test\nEND\n", responseText)
    }

    @Test
    fun `body should be decompressed by compression plugin before receiving with content negotiation`() {
        testApplication {
            @Serializable
            data class JsonBody(val test: String)

            application {
                install(ContentNegotiation) {
                    json()
                }

                install(Compression) {
                    mode = CompressionConfig.Mode.DecompressRequest
                    gzip()
                }

                routing {
                    post("/json") {
                        val body = call.receive<JsonBody>()
                        call.respondText(body.test)
                    }
                }
            }
            val expectedText = "This is a test"
            val responseText = client.post("/json") {
                val compressedBody = GZipEncoder.encode(
                    ByteReadChannel("""{"test": "$expectedText"}""".toByteArray())
                ).readRemaining().readByteArray()
                setBody(compressedBody)
                header(HttpHeaders.ContentType, ContentType.Application.Json)
                header(HttpHeaders.ContentEncoding, "gzip")
            }.bodyAsText()
            assertEquals(expectedText, responseText)
        }
    }

    @Test
    fun testRejectTooLongContentEncodingChain() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()

        install(Compression) {
            mode = CompressionConfig.Mode.DecompressRequest
            gzip()
            maxEncodingChainLength = 2
        }
        routing {
            post("/gzip") {
                call.respond(call.receive<ByteArray>())
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            // 6 encodings > limit of 2
            header(HttpHeaders.ContentEncoding, "gzip,gzip,gzip,gzip,gzip,gzip")
        }
        assertEquals(HttpStatusCode.BadRequest, response.status)
    }

    @Test
    fun testRejectDecompressionBomb() = testApplication {
        // Build a small payload that decompresses to a much larger one ("zip bomb"-like).
        val bombPlain = ByteArray(1024 * 1024) // 1 MiB of zeros
        val bombCompressed = GZipEncoder.encode(ByteReadChannel(bombPlain)).readRemaining().readByteArray()

        install(Compression) {
            mode = CompressionConfig.Mode.DecompressRequest
            gzip()
            maxDecodedContentLength = 16 * 1024 // 16 KiB cap, far below 1 MiB
        }
        routing {
            post("/gzip") {
                runCatching { call.receive<ByteArray>() }
                    .onSuccess { call.respond(HttpStatusCode.OK) }
                    .onFailure { call.respond(HttpStatusCode.PayloadTooLarge) }
            }
        }

        val response = client.post("/gzip") {
            setBody(bombCompressed)
            header(HttpHeaders.ContentEncoding, "gzip")
        }
        assertEquals(HttpStatusCode.PayloadTooLarge, response.status)
    }

    @Test
    fun testAllowDecodedContentBelowLimit() = testApplication {
        val compressed = GZipEncoder.encode(ByteReadChannel(textToCompressAsBytes)).readRemaining().readByteArray()

        install(Compression) {
            mode = CompressionConfig.Mode.DecompressRequest
            gzip()
            maxDecodedContentLength = textToCompressAsBytes.size.toLong() + 100
        }
        routing {
            post("/gzip") {
                val body = call.receive<ByteArray>()
                assertContentEquals(textToCompressAsBytes, body)
                call.respond(body)
            }
        }

        val response = client.post("/gzip") {
            setBody(compressed)
            header(HttpHeaders.ContentEncoding, "gzip")
        }
        assertEquals(HttpStatusCode.OK, response.status)
        assertContentEquals(textToCompressAsBytes, response.body<ByteArray>())
    }

    private suspend fun ApplicationTestBuilder.handleAndAssert(
        url: String,
        acceptHeader: String?,
        expectedEncoding: String?,
        expectedContent: String,
        expectedVary: String? = null,
    ): HttpResponse {
        val response = client.get(url) {
            if (acceptHeader != null) {
                header(HttpHeaders.AcceptEncoding, acceptHeader)
            }
        }

        assertEquals(HttpStatusCode.OK, response.status)
        if (expectedEncoding != null) {
            assertEquals(expectedEncoding, response.headers[HttpHeaders.ContentEncoding])
            when (expectedEncoding) {
                "gzip" -> {
                    assertEquals(expectedContent, response.readGzip())
                    assertNull(response.headers[HttpHeaders.ContentLength])
                }

                "deflate" -> {
                    assertEquals(expectedContent, response.readDeflate())
                    assertNull(response.headers[HttpHeaders.ContentLength])
                }

                "identity" -> {
                    assertEquals(expectedContent, response.readIdentity())
                    assertNotNull(response.headers[HttpHeaders.ContentLength])
                }

                else -> fail("unknown encoding $expectedEncoding")
            }
        } else {
            assertNull(response.headers[HttpHeaders.ContentEncoding], "content shouldn't be compressed")
            assertEquals(expectedContent, response.bodyAsText())
            assertNotNull(response.headers[HttpHeaders.ContentLength])
        }

        expectedVary?.let {
            assertEquals(response.headers[HttpHeaders.Vary], expectedVary)
        }

        return response
    }

    private suspend fun HttpResponse.readIdentity() = bodyAsChannel().readRemaining().readText()
    private suspend fun HttpResponse.readDeflate() =
        DeflateEncoder.decode(bodyAsChannel()).readRemaining().readText()

    private suspend fun HttpResponse.readGzip() = GZipEncoder.decode(bodyAsChannel()).readRemaining().readText()
}
