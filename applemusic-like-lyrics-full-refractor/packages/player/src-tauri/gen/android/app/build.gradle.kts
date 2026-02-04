import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("rust")
}

val tauriProperties = Properties().apply {
    val propFile = file("tauri.properties")
    if (propFile.exists()) {
        propFile.inputStream().use { load(it) }
    }
}

android {
    compileSdk = 36
    namespace = "net.stevexmh.amllplayer"
    ndkVersion = "27.2.12479018" 
    defaultConfig {
        manifestPlaceholders["usesCleartextTraffic"] = "false"
        applicationId = "net.stevexmh.amllplayer"
        minSdk = 26
        targetSdk = 36
        versionCode = tauriProperties.getProperty("tauri.android.versionCode", "1").toInt()
        versionName = tauriProperties.getProperty("tauri.android.versionName", "1.0")
    }
    buildTypes {
        getByName("debug") {
            manifestPlaceholders["usesCleartextTraffic"] = "true"
            isDebuggable = true
            isJniDebuggable = true
            isMinifyEnabled = false
            packaging {                jniLibs.keepDebugSymbols.add("*/arm64-v8a/*.so")
                jniLibs.keepDebugSymbols.add("*/armeabi-v7a/*.so")
                jniLibs.keepDebugSymbols.add("*/x86/*.so")
                jniLibs.keepDebugSymbols.add("*/x86_64/*.so")
            }
        }
        getByName("release") {
            isMinifyEnabled = true
            proguardFiles(
                *fileTree(".") { include("**/*.pro") }
                    .plus(getDefaultProguardFile("proguard-android-optimize.txt"))
                    .toList().toTypedArray()
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        buildConfig = true
    }
}

rust {
    rootDirRel = "../../../"
}

dependencies {
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("com.google.android.material:material:1.8.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}

apply(from = "tauri.build.gradle.kts")

tasks.register<Copy>("copyCppSharedLib") {
    val ndkDir = project.android.ndkDirectory.absolutePath

    val abiMap = mapOf(
        "arm64-v8a" to "aarch64-linux-android",
        "armeabi-v7a" to "armv7a-linux-androideabi",
        "x86" to "i686-linux-android",
        "x86_64" to "x86_64-linux-android"
    )

    project.android.defaultConfig.ndk.abiFilters.forEach { abi ->
        val toolchainAbi = abiMap[abi]
        if (toolchainAbi != null) {
            val sourcePath = "$ndkDir/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/$toolchainAbi/libc++_shared.so"
            println("Copying $sourcePath for $abi")
            from(sourcePath)
            into("src/main/jniLibs/$abi")
        }
    }
}

tasks.whenTaskAdded {
    if (name.startsWith("package")) {
        dependsOn("copyCppSharedLib")
    }
}
