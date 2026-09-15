plugins {
    kotlin("jvm") version "2.4.20"
    id("org.jetbrains.intellij.platform") version "2.9.0"
}

group = "dev.klio"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform { defaultRepositories() }
}

dependencies {
    testImplementation(kotlin("test"))

    intellijPlatform {
        intellijIdeaCommunity("2026.1.2", useInstaller = false)
        bundledPlugin("org.jetbrains.kotlin")
        bundledPlugin("com.intellij.java")
    }
}

kotlin {
    jvmToolchain(21)
}

intellijPlatform {
    pluginConfiguration {
        id = "dev.klio.intellij"
        name = "KLIO"
        version = project.version.toString()
        ideaVersion {
            sinceBuild = "261"
            untilBuild = provider { null }
        }
    }
    pluginVerification {
        ides { recommended() }
    }
}

tasks {
    test {
        useJUnitPlatform()
    }

    runIde {
        // `KLIO_IDE_SELFCHECK=<project-dir>` turns the sandbox run into the
        // headless self-check instead of opening a window.
        System.getenv("KLIO_IDE_SELFCHECK")?.let { sample ->
            args = listOf("klio-selfcheck", sample)
            systemProperty("java.awt.headless", "true")
        }
        // `KLIO_IDE_PROJECT=<dir>` opens that project instead of the welcome screen.
        System.getenv("KLIO_IDE_PROJECT")?.let { project ->
            if (System.getenv("KLIO_IDE_SELFCHECK") == null) args = listOf(project)
        }
        environment("PATH", System.getenv("PATH") + ":" + rootDir.parentFile.resolve("zig-out/bin"))
        System.getenv("KLIO_HOME")?.let { environment("KLIO_HOME", it) }
    }
}

// A headless run of the integration against a real klio project.
tasks.register("selfCheck") {
    dependsOn("runIde")
}
