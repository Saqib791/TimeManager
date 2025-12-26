plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.saqib.timemanager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 👇👇👇 Desugaring Fix (Kotlin Style)
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    defaultConfig {
        applicationId = "com.saqib.timemanager"
        minSdk = flutter.minSdkVersion // Notification ke liye 21
        targetSdk = flutter.targetSdkVersion
        versionCode = 1
        versionName = "1.0"
        multiDexEnabled = true
    }

    buildTypes {
        release {
            // Signing with debug key taaki bina key-store ke install ho jaye
            signingConfig = signingConfigs.getByName("debug")

            // 👇👇👇 YAHAN HAI MAIN FIX (Notification ke liye)
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // 👇👇👇 Dependency Fix (Kotlin Style)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}