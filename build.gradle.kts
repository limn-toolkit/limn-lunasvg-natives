// limn-lunasvg-natives: the SVG renderer the Limn toolkit loads, and nothing else.
//
// NOTHING HERE IS BUILT BY GRADLE'S COMPILERS. The library comes from scripts/build-lunasvg.sh,
// which is how a release builds it on six machines (.github/workflows/natives.yml) and how a
// developer builds one locally. What this file does is PACKAGE, and test what was built:
//
//   the main jar          the licences and the notice of lunasvg and plutovg. The one jar the
//                         toolkit's backend names; it carries no code and no native.
//   natives-<os>-<arch>   one classifier jar per desktop target: that platform's liblimnsvg,
//                         lunasvg and plutovg linked into the JNI shim, a few hundred kilobytes.
//                         The toolkit's backend names all six, as it names LWJGL's.
//
// The loader in the toolkit resolves limn/svg/native/<os>-<arch>/liblimnsvg.<ext> as a CLASSPATH
// resource, and a classpath spans jars, so which jar holds which file is invisible to it.
//
// NO native is committed, and none ever will be. .gitignore excludes the whole native/ tree.

import java.util.Properties

plugins {
    `java-library`
    alias(libs.plugins.central.publish)
}

group = "io.github.limn-toolkit"

// The version, from -PlimnNativesVersion (the publish workflow passes it, taken from the tag) and
// otherwise the -SNAPSHOT of versions.properties. Its first three components must be the lunasvg
// version scripts/build-lunasvg.sh pins: a version that names one lunasvg over another's payload is
// a lie the build can catch, so it does.
val declaredVersion = Properties().apply {
    file("versions.properties").inputStream().use { load(it) }
}.getProperty("limn-lunasvg-natives") ?: throw GradleException("versions.properties names no version")
version = (findProperty("limnNativesVersion") as String?) ?: "$declaredVersion-SNAPSHOT"

val pinnedLunasvg = Regex("""^LUNASVG_VERSION="([^"]+)"""", RegexOption.MULTILINE)
    .find(file("scripts/build-lunasvg.sh").readText())?.groupValues?.get(1)
    ?: throw GradleException("scripts/build-lunasvg.sh no longer pins LUNASVG_VERSION where this build reads it")
if (!version.toString().startsWith("$pinnedLunasvg.")) {
    throw GradleException(
        "version $version does not name the lunasvg it carries: scripts/build-lunasvg.sh pins " +
                "$pinnedLunasvg, so the version must be $pinnedLunasvg.<n> (see versions.properties)"
    )
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
    withSourcesJar()
}

// A jar of native libraries runs on any Java the shim was written for, and this is what says so
// where consumers listen: without it the published module metadata takes its minimum JVM from the
// toolchain above and refuses every consumer building for an older Java.
tasks.named<JavaCompile>("compileJava") {
    options.release.set(8)
}
// The tests are this repository's own and run on the build's JDK; JUnit asks for 17.
tasks.named<JavaCompile>("compileTestJava") {
    options.release.set(17)
}

val svgNatives = file("native/dist")

sourceSets {
    named("main") {
        // Absent on a machine that never ran the build script, which Gradle accepts.
        resources.srcDir(svgNatives)
    }
}

/**
 * The desktop targets a published payload must cover, written out rather than discovered: a check
 * that trusts what it finds calls an empty directory complete.
 */
val requiredNativePlatforms = listOf(
    "linux-aarch64", "linux-x86_64",
    "macos-aarch64", "macos-x86_64",
    "windows-aarch64", "windows-x86_64",
)

val licences = listOf("LICENSE-lunasvg.txt", "LICENSE-plutovg.txt", "NOTICE-lunasvg.txt")

// The main jar: the licences and the notice, nothing else.
tasks.named<ProcessResources>("processResources") {
    exclude {
        it.path.startsWith("limn/svg/native/") && !it.isDirectory && it.name !in licences
    }
    doFirst {
        if (!svgNatives.isDirectory) {
            logger.lifecycle("limn-lunasvg-natives: no payload built (run scripts/build-lunasvg.sh); the jars will be empty")
        }
    }
}

/** One jar per platform: that platform's liblimnsvg and the licences. */
val nativeJars = requiredNativePlatforms.map { platform ->
    val suffix = platform.split("-").joinToString("") { part -> part.replaceFirstChar(Char::uppercase) }
    tasks.register<Jar>("nativesJar$suffix") {
        description = "liblimnsvg for $platform, published as natives-$platform."
        group = "build"
        archiveClassifier.set("natives-$platform")
        // A module name of its own: two jars deriving the same one from their file names stop the
        // JVM at startup on the module path ("Two versions of module"), which limn-ffmpeg-natives
        // learned before this repository existed.
        manifest { attributes("Automatic-Module-Name" to "limn.lunasvg.natives." + platform.replace('-', '.')) }
        from(svgNatives) {
            include("limn/svg/native/$platform/**")
        }
        from(svgNatives) {
            licences.forEach { include("limn/svg/native/$it") }
        }
    }
}

tasks.named("assemble") {
    dependsOn(nativeJars)
}

// The main jar's module name, which the toolkit's backend module requires. "native" is a keyword,
// so no jar here has a package and two of them never collide on one.
tasks.named<Jar>("jar") {
    manifest { attributes("Automatic-Module-Name" to "limn.lunasvg.natives") }
}

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// The tests load what the build script staged for THIS machine, by path, and skip with a sentence
// when it was not built here: a checkout that never ran the script still builds and packages.
tasks.named<Test>("test") {
    useJUnitPlatform()
    systemProperty("limn.svg.dist", svgNatives.resolve("limn/svg/native").absolutePath)
    testLogging { events("failed", "skipped"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

/** Which platforms the staged payload really carries: a directory with its library in it. */
fun carriedPlatforms(): Set<String> {
    val root = svgNatives.resolve("limn/svg/native")
    return (root.listFiles() ?: emptyArray())
        .filter { platform -> platform.isDirectory && (platform.listFiles() ?: emptyArray()).any { it.name.startsWith("liblimnsvg.") } }
        .map { it.name }
        .toSet()
}

// A release ships all six, and this turns the sentence into a rule.
tasks.withType<AbstractPublishToMaven>().configureEach {
    // The local file repository is where a partial payload is LOOKED AT; the guard is for anything
    // that leaves the machine.
    if (name.contains("BuildDir")) return@configureEach
    doFirst {
        val missing = requiredNativePlatforms.filterNot { carriedPlatforms().contains(it) }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "refusing to publish limn-lunasvg-natives without its whole payload: " +
                        "${missing.joinToString(", ")} " + (if (missing.size == 1) "is" else "are") +
                        " missing from ${svgNatives.relativeTo(rootDir)}. A release builds all six on its own " +
                        "runners (.github/workflows/natives.yml) and merges them in before this task runs."
            )
        }
    }
}

// The payload reaches the main source set through resources.srcDir above, which is what a sources
// jar copies as well: this jar answers "what was this compiled from", and the answer is the shim's
// C++ and the pinned lunasvg named in scripts/build-lunasvg.sh, so the binaries leave it.
tasks.named<Jar>("sourcesJar") {
    exclude("limn/svg/native/**")
    from("src/main/cpp")
}

mavenPublishing {
    // Uploads and stops: the deployment sits staged on the Central Portal until somebody presses
    // Publish, which is the last moment a release can still be dropped.
    publishToMavenCentral()

    if (providers.gradleProperty("signingInMemoryKey").isPresent ||
            providers.gradleProperty("signing.keyId").isPresent) {
        signAllPublications()
    }

    pom {
        name.set("limn-lunasvg-natives")
        description.set(
            "The SVG renderer behind the Limn toolkit: lunasvg $pinnedLunasvg and plutovg (MIT), " +
                    "compiled with Limn's JNI shim into one library per platform, for macOS, Linux " +
                    "and Windows on x86_64 and aarch64, one natives-<os>-<arch> classifier each. " +
                    "Versions with lunasvg, not with the toolkit."
        )
        url.set("https://github.com/limn-toolkit/limn-lunasvg-natives")
        scm {
            url.set("https://github.com/limn-toolkit/limn-lunasvg-natives")
            connection.set("scm:git:https://github.com/limn-toolkit/limn-lunasvg-natives.git")
            developerConnection.set("scm:git:ssh://git@github.com/limn-toolkit/limn-lunasvg-natives.git")
        }
        licenses {
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                comments.set("Limn's JNI shim, compiled into liblimnsvg")
            }
            license {
                name.set("MIT License")
                url.set("https://opensource.org/license/mit")
                comments.set("lunasvg and plutovg, compiled into liblimnsvg; see LICENSE-lunasvg.txt and LICENSE-plutovg.txt in each jar")
            }
        }
        developers {
            developer {
                id.set("limn-toolkit")
                name.set("Limn Toolkit")
                email.set("limntoolkit@gmail.com")
                url.set("https://github.com/limn-toolkit")
            }
        }
    }
}

// The classifier jars join the one publication the plugin configured.
publishing {
    publications.withType<MavenPublication>().configureEach {
        nativeJars.forEach { artifact(it) }
    }
    // A plain file repository under build/repo, for looking at what would ship without sending it
    // anywhere, and for scripts/rehearse-consumer.sh to resolve from.
    repositories {
        maven {
            name = "buildDir"
            url = uri(layout.buildDirectory.dir("repo"))
        }
    }
}

// A release that Central would reject on validation (unsigned), caught before anything leaves.
gradle.taskGraph.whenReady {
    val releasing = allTasks.any {
        it.name == "publishToMavenCentral" || it.name == "publishAndReleaseToMavenCentral" ||
                it.name.startsWith("publishAllPublicationsToMavenCentral")
    }
    if (!releasing) return@whenReady
    if (project.version.toString().endsWith("-SNAPSHOT")) {
        logger.lifecycle("publishing ${project.version} to Central's SNAPSHOT repository. This is " +
                "not a release: bump versions.properties and push for one (see RELEASING.md).")
        return@whenReady
    }
    if (!providers.gradleProperty("signingInMemoryKey").isPresent &&
            !providers.gradleProperty("signing.keyId").isPresent) {
        throw GradleException(
            "refusing to publish ${project.version} to Maven Central unsigned: no signing key is " +
                    "configured, and Central requires a signature on every artifact of a release."
        )
    }
}
