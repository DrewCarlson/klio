import alpha.alphaState
import alpha.bumpAlpha
import beta.betaState
import beta.bumpBeta
import beta.counter

fun main() {
    println(alphaState())
    println(betaState())
    println(bumpAlpha())
    println(bumpBeta())
    println(bumpAlpha())
    println(bumpBeta())
    counter = 500
    println(bumpBeta())
    println(bumpAlpha())
}
