// Color space conversion through the vendored androidx.compose.ui.graphics
// colorspace module: RGB<->XYZ<->Lab connectors with chromatic adaptation,
// the Oklab-backed lerp, and alpha compositing in linear space.

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import kotlin.math.abs

fun main() {
    val c = Color(0.2f, 0.4f, 0.6f, 1.0f)
    val rt = c.convert(ColorSpaces.CieXyz).convert(ColorSpaces.Srgb)
    println("xyz roundtrip=" + (abs(rt.red - 0.2f) < 0.001f && abs(rt.green - 0.4f) < 0.001f && abs(rt.blue - 0.6f) < 0.001f))

    val lab = Color.Red.convert(ColorSpaces.CieLab)
    println("red lab a>0=" + (lab.green > 0f))

    val p3 = Color.Green.convert(ColorSpaces.DisplayP3).convert(ColorSpaces.Srgb)
    println("p3 roundtrip=" + (abs(p3.green - 1f) < 0.001f))

    val over = Color(1f, 0f, 0f, 0.5f).compositeOver(Color.White)
    println("composite=" + over.red + "," + over.green + "," + over.blue)

    val mid = lerp(Color.Red, Color.Blue, 0.5f)
    println("lerp has both=" + (mid.red > 0f && mid.blue > 0f))

    println("luminance=" + Color.White.luminance() + " " + Color.Black.luminance())
}
