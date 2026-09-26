// Run with: klio run --include examples/compose_resources examples/compose_resources.kt
// painterResource reads the program's resources as it reads a Compose Desktop
// program's classpath resources: an SVG through skia's SVG DOM, an Android
// vector drawable (a gradient given as an aapt:attr child included), and a
// bitmap. The files are included with `--include`, at the path relative to
// this file's directory; useResource opens the same files as streams.
@file:Suppress("DEPRECATION")

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.res.loadImageBitmap
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.useResource
import androidx.compose.ui.unit.dp

fun hex(argb: Int) = (argb.toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')

fun main() {
    val bitmap = useResource("compose_resources/stripe.png") { loadImageBitmap(it) }
    println("stripe.png ${bitmap.width}x${bitmap.height}")
    val scene = KlioComposeScene(100, 100)
    scene.setContent {
        Column {
            val svg = painterResource("compose_resources/badge.svg")
            val vector = painterResource("compose_resources/arrow.xml")
            val png = painterResource("compose_resources/stripe.png")
            println("badge.svg ${svg.intrinsicSize}")
            println("arrow.xml ${vector.intrinsicSize}")
            println("stripe.png ${png.intrinsicSize}")
            Image(svg, null, Modifier.size(40.dp, 20.dp))
            Image(vector, null, Modifier.size(24.dp, 24.dp))
            Image(png, null, Modifier.size(4.dp, 2.dp))
        }
    }
    val image = scene.render()
    val pixels = image.toPixelMap()
    println("svg ${hex(pixels[5, 10].toArgb())} ${hex(pixels[30, 10].toArgb())}")
    println("vector ${hex(pixels[3, 30].toArgb())} ${hex(pixels[13, 30].toArgb())} ${hex(pixels[23, 30].toArgb())}")
    println("png ${hex(pixels[0, 44].toArgb())} ${hex(pixels[1, 44].toArgb())} ${hex(pixels[2, 44].toArgb())} ${hex(pixels[3, 44].toArgb())}")
    try {
        useResource("compose_resources/missing.svg") { it.readAllBytes() }
    } catch (e: IllegalArgumentException) {
        println(e.message)
    }
    scene.dispose()
}
