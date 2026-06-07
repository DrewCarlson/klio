fun <T, U> bad(): Int where T : U, U : T {
    return 0
}
