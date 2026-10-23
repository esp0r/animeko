/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

plugins {
    id("ani.kmp-library")
    alias(libs.plugins.kotlin.plugin.serialization)

    // alias(libs.plugins.kotlinx.atomicfu)
}

kotlin {
    targets.withType<KotlinNativeTarget>().configureEach {
        val sdk = if (name == "iosArm64") "iphoneos" else "iphonesimulator"
        val output = layout.buildDirectory.dir("native/$sdk")
        val usePrebuilt = providers.gradleProperty("ani.anitorrent.prebuilt").map(String::toBoolean).orElse(false)
        val nativeBuild = tasks.register<Exec>("buildAnitorrent${name.replaceFirstChar { it.uppercase() }}") {
            inputs.dir("native")
            outputs.file(output.map { it.file("lib/libanitorrent_c.a") })
            commandLine("bash", file("native/build-apple.sh"), sdk, output.get().asFile)
            onlyIf { !usePrebuilt.get() }
        }
        compilations.getByName("main").cinterops.create("anitorrent") {
            definitionFile.set(file("src/nativeInterop/cinterop/anitorrent.def"))
            includeDirs(file("native/include"))
            extraOpts("-libraryPath", output.get().dir("lib").asFile.absolutePath)
            tasks.named(interopProcessingTaskName).configure {
                dependsOn(nativeBuild)
                inputs.file(output.map { it.file("lib/libanitorrent_c.a") })
                    .withPropertyName("anitorrentNativeArchive")
                    .withPathSensitivity(PathSensitivity.NONE)
            }
        }
    }
    android {
        namespace = "me.him188.ani.torrent.anitorrent"
    }
    sourceSets.commonMain.dependencies {
        api(libs.kotlinx.coroutines.core)
        implementation(libs.kotlinx.collections.immutable)
        api(projects.utils.io)
        api(projects.utils.platform)
        api(projects.torrent.torrentApi)
        api(projects.utils.coroutines)
        implementation(libs.atomicfu)
    }
    sourceSets.getByName("jvmMain").dependencies {
        api(anitorrentLibs.anitorrent.native)
    }
    sourceSets.getByName("desktopMain").dependencies {
        val triple = getAnitorrentTriple()
        if (triple != null) {
            api(
                anitorrentLibs.anitorrent.native.desktop.asProvider().map { notation ->
                    "$notation:${triple}"
                },
            )
        }
    }
}

fun getAnitorrentTriple(): String? {
    return when (getOs()) {
        Os.MacOS -> {
            when (getArch()) {
                Arch.X86_64 -> "macos-x64"
                Arch.AARCH64 -> "macos-aarch64"
            }
        }

        Os.Windows -> {
            when (getArch()) {
                Arch.X86_64 -> "windows-x64"
                // Windows ARM64 builds intentionally ship without the local BT engine.
                Arch.AARCH64 -> null
            }
        }

        Os.Linux -> {
            when (getArch()) {
                Arch.X86_64 -> "linux-x64"
                else -> error("Unsupported architecture: ${getArch()}")
            }
        }

        Os.Unknown -> error("Unsupported OS: ${getOs()}")
    }
}
