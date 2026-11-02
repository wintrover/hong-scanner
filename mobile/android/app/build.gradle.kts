import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is opt-in through a gitignored key.properties file in
// android/ that points at a keystore kept OUTSIDE the repository (repo
// rule: credentials never enter the tree). There is no quiet fallback to
// the debug key: without key.properties a release build fails with an
// instructive error instead of shipping debug-signed (fail-closed).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val releaseKeystoreConfigured = keystorePropertiesFile.exists()
if (releaseKeystoreConfigured) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { requiredKey ->
        require(keystoreProperties.getProperty(requiredKey) != null) {
            "key.properties is missing '$requiredKey' (see mobile/README.md, release signing)"
        }
    }
}

android {
    namespace = "com.hongscanner.hongscanner"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hongscanner.hongscanner"
        // firebase_messaging 17.x requires minSdk 24.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeystoreConfigured) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // No key.properties -> no signingConfig at all. The execution
            // guard below then refuses the build; it never quietly signs
            // release with debug keys.
            if (releaseKeystoreConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

if (!releaseKeystoreConfigured) {
    tasks.matching { task -> task.name.matches(Regex(".*[Rr]elease.*")) }.configureEach {
        doFirst {
            throw GradleException(
                "Release build refused: no signing config. Create a keystore OUTSIDE the repo " +
                    "(see mobile/README.md 'release signing') and android/key.properties pointing at it."
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
