rootProject.name = "limn-lunasvg-natives"

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

// One project, one artifact, seven jars: the licences in the main jar and liblimnsvg, lunasvg and
// plutovg compiled into Limn's JNI shim, in one natives-<os>-<arch> classifier each. It is the SVG
// renderer of limn-toolkit's ADR 066, here so that it versions with LUNASVG, as limn-ffmpeg-natives
// versions with FFmpeg: a toolkit release re-uploads no native byte.
