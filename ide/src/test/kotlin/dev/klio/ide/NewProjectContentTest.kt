package dev.klio.ide

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * What New Project writes. The manifest is the part a user cannot fix by
 * retyping, so its shape is pinned: the concise `[deps]` table, an
 * `[application]` entry only for a program, and a `[[test]]` set only when
 * there is a test to run.
 */
class NewProjectContentTest {

    @Test
    fun anApplicationDeclaresItsEntryPoint() {
        val manifest = klioManifest("com.example.app", application = true, sampleCode = true, dependencies = listOf(KlioDependencyChoice("kotlin.test")))
        assertTrue("[application]" in manifest)
        assertTrue("main = \"src/main/kotlin/Main.kt\"" in manifest)
    }

    @Test
    fun aLibraryDeclaresNoEntryPoint() {
        val manifest = klioManifest("com.example.lib", application = false, sampleCode = true, dependencies = emptyList())
        assertFalse("[application]" in manifest)
    }

    @Test
    fun dependenciesUseTheOneLineForm() {
        val manifest = klioManifest("a.b", application = true, sampleCode = false, dependencies = listOf(KlioDependencyChoice("kotlinx.io")))
        assertTrue("[deps]" in manifest)
        assertTrue("stdlib = \"*\"" in manifest)
        assertTrue("\"kotlinx.io\" = \"*\"" in manifest)
        assertFalse("[[deps]]" in manifest)
    }

    @Test
    fun aTestSourceSetNeedsSomethingToTestWith() {
        val withTest = klioManifest("a.b", application = true, sampleCode = true, dependencies = listOf(KlioDependencyChoice("kotlin.test")))
        assertTrue("[[test]]" in withTest)

        // No kotlin.test means the sample has no test, so the set would be empty.
        val withoutTest = klioManifest("a.b", application = true, sampleCode = true, dependencies = emptyList())
        assertFalse("[[test]]" in withoutTest)
    }

    @Test
    fun aDependencyTakenByFeatureSpellsThemOut() {
        val manifest = klioManifest(
            "a.b",
            application = true,
            sampleCode = false,
            dependencies = listOf(KlioDependencyChoice("io.ktor", listOf("client", "server"))),
        )
        assertTrue("\"io.ktor\" = { version = \"*\", features = [\"client\", \"server\"] }" in manifest)
    }

    @Test
    fun aDependencyWithNoFeaturesChosenTakesTheDefaults() {
        val manifest = klioManifest(
            "a.b",
            application = true,
            sampleCode = false,
            dependencies = listOf(KlioDependencyChoice("io.ktor")),
        )
        assertTrue("\"io.ktor\" = \"*\"" in manifest)
        assertFalse("features" in manifest)
    }

    @Test
    fun aPackageNameSurvivesADashedId() {
        assertEquals("my_app.core", klioSamplePackage("my-app.core"))
        assertEquals("com.example.app", klioSamplePackage("com.example.app"))
    }

    @Test
    fun theSampleAndItsTestAgree() {
        val main = klioSampleMain("a.b")
        val test = klioSampleTest("a.b")
        assertTrue("fun greeting(" in main)
        assertTrue("greeting(\"klio\")" in test)
        assertTrue(main.startsWith("package a.b"))
        assertTrue(test.startsWith("package a.b"))
    }
}
