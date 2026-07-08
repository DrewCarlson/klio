// The real androidx.compose.ui.graphics.Color — the genuine upstream inline
// value class over a packed ULong, backed by the full color-science colorspace
// package (Rgb / ColorSpaces / the XYZ transforms), vendored verbatim. Channel
// decode, half-float packing, luminance, and the companion palette all run
// through the real code.
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

fun pct(x: Float): Int = (x * 100 + 0.5f).toInt()

fun main() {
    // Construct from a packed 0xAARRGGBB and read the sRGB channels back.
    val c = Color(0xFF3366CC)
    println("argb: r=${pct(c.red)} g=${pct(c.green)} b=${pct(c.blue)} a=${pct(c.alpha)}")

    // Construct from float channels.
    val teal = Color(red = 0.0f, green = 0.5f, blue = 0.5f)
    println("teal: g=${pct(teal.green)} b=${pct(teal.blue)}")

    // Construct from 8-bit integer channels.
    val orange = Color(red = 255, green = 128, blue = 0)
    println("orange: r=${pct(orange.red)} g=${pct(orange.green)} b=${pct(orange.blue)}")

    // Relative luminance (Y of CIE XYZ) — the perceptual channel weighting
    // (red ~0.21, green ~0.72, blue ~0.07).
    println("luminance white=${pct(Color.White.luminance())} black=${pct(Color.Black.luminance())}")
    println("luminance red=${pct(Color.Red.luminance())} green=${pct(Color.Green.luminance())} blue=${pct(Color.Blue.luminance())}")

    // copy() overrides selected channels; the companion palette are real Colors.
    val faded = Color.Red.copy(alpha = 0.5f)
    println("faded red: r=${pct(faded.red)} a=${pct(faded.alpha)}")
    println("space: ${Color.White.colorSpace.name}")
}
