// Run with: klio run --feature io.ktor/http examples/ktor_content_type_by_extension.kt
// ktor keeps its extension <-> content-type tables as private top-level
// `by lazy` properties that only the pack's own functions read. The first
// read from inside the pack drives the file's deferred initializer and must
// still answer through the delegate's `getValue`, on a cold run and on a run
// served from the baked image alike.
import io.ktor.http.ContentType
import io.ktor.http.fileExtensions
import io.ktor.http.fromFileExtension
import io.ktor.http.defaultForFileExtension

fun main() {
    println(ContentType.fromFileExtension("txt"))
    println(ContentType.fromFileExtension("json").first())
    println(ContentType.Text.Plain.fileExtensions().take(3))
    println(ContentType.defaultForFileExtension("html"))
}
