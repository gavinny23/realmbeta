allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Force every subproject (including third-party plugins with stale
// Java 8/11 config) onto Java/Kotlin 17, matching the app module.
// This prevents "Inconsistent JVM Target Compatibility" errors from
// old plugins without needing to patch each one individually in CI.
subprojects {
    tasks.withType(JavaCompile::class.java).configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
    tasks.matching { it.name.contains("KotlinCompile") }.configureEach {
        withGroovyBuilder {
            "kotlinOptions" {
                setProperty("jvmTarget", "17")
            }
        }
    }
}

// Some third-party plugins (e.g. on_audio_query_android) hardcode an
// old compileSdkVersion in their own build.gradle instead of tracking
// the app's. Newer androidx transitive deps (fragment 1.7.1, activity
// 1.8.1, etc.) require compiling against API 34+, so an old plugin
// stuck on 33 fails CheckAarMetadataWorkAction even though the app
// itself is already on compileSdk 36. Force every Android library
// subproject to match the app's compileSdk so this can't happen.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val common = ext as com.android.build.gradle.BaseExtension
            common.compileSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
