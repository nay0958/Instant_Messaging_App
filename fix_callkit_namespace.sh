#!/bin/bash
# Fix namespace and JVM target issues for flutter_callkit_incoming package
# Run this script after 'flutter pub get' if you encounter build errors

PACKAGE_PATH="$HOME/.pub-cache/hosted/pub.dev/flutter_callkit_incoming-1.0.3+3/android/build.gradle"

if [ -f "$PACKAGE_PATH" ]; then
    # Check if namespace already exists
    if ! grep -q "namespace 'com.hiennv.flutter_callkit_incoming'" "$PACKAGE_PATH"; then
        echo "Adding namespace to flutter_callkit_incoming build.gradle..."
        # Use sed to add namespace after android {
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            sed -i '' '/^android {/a\
    namespace '\''com.hiennv.flutter_callkit_incoming'\''
' "$PACKAGE_PATH"
        else
            # Linux
            sed -i '/^android {/a\    namespace '\''com.hiennv.flutter_callkit_incoming'\''' "$PACKAGE_PATH"
        fi
        echo "✓ Namespace added successfully!"
    else
        echo "✓ Namespace already exists in build.gradle"
    fi
    
    # Check if JVM target configuration exists
    if ! grep -q "kotlinOptions" "$PACKAGE_PATH"; then
        echo "Adding JVM target configuration to flutter_callkit_incoming build.gradle..."
        # Use sed to add compileOptions and kotlinOptions after android {
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            sed -i '' '/^android {/a\
    compileOptions {\
        sourceCompatibility JavaVersion.VERSION_1_8\
        targetCompatibility JavaVersion.VERSION_1_8\
    }\
    kotlinOptions {\
        jvmTarget = "1.8"\
    }
' "$PACKAGE_PATH"
        else
            # Linux
            sed -i '/^android {/a\    compileOptions {\n        sourceCompatibility JavaVersion.VERSION_1_8\n        targetCompatibility JavaVersion.VERSION_1_8\n    }\n    kotlinOptions {\n        jvmTarget = "1.8"\n    }' "$PACKAGE_PATH"
        fi
        echo "✓ JVM target configuration added successfully!"
    else
        echo "✓ JVM target configuration already exists in build.gradle"
    fi
else
    echo "✗ Package not found at: $PACKAGE_PATH"
    echo "  Make sure you've run 'flutter pub get' first"
fi
