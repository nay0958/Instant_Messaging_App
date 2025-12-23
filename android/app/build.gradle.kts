plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Conditionally apply Google Services plugin only if google-services.json exists
val googleServicesFile = file("google-services.json")
if (googleServicesFile.exists()) {
    apply(plugin = "com.google.gms.google-services")
    println("✅ Google Services plugin applied (google-services.json found)")
} else {
    println("⚠️ Google Services plugin skipped (google-services.json not found)")
    println("💡 To enable Firebase: Add google-services.json to android/app/")
}

android {
    namespace = "com.study.messaging"

    // Flutter template variables are fine; just ensure compile/target are recent.
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.study.messaging"

        // ⚠️ Make sure minSdk >= 21 for flutter_local_notifications
        // If flutter.minSdkVersion < 21, override it explicitly:
         minSdk = flutter.minSdkVersion
       // minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ✅ Enable Java desugaring
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true   // <-- IMPORTANT
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    buildTypes {
        release {
            // keep debug signing for now
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ✅ Add the desugaring library
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // (Other dependencies injected by Flutter stay as-is)
}
