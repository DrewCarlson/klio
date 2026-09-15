# A sample klio project

Used by the plugin's self-check, and as the project to open when trying the IDE
integration by hand.

```sh
klio run src/main/kotlin/Main.kt
klio test .
```

What each file is there to show:

| File | Shows |
|------|-------|
| `Main.kt` | stdlib resolution, KDoc hover, go to definition into materialised stdlib source |
| `Schedule.kt` | a pack dependency: navigation into kotlinx-datetime's own source |
| `Concurrent.kt` | suspend functions and coroutine builders resolving from a pack |
| `src/test/kotlin` | the test tree, `@Ignore`, and gutter icons |

To watch a comparison failure render as a diff, change an expected value in
`DoubledTest` and run the class from its gutter icon.
