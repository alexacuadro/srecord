#!/bin/bash

# --- CONFIGURACIÓN ---
SUPABASE_URL="https://vonuhrbjchufqzqygqgt.supabase.co"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvbnVocmJqY2h1ZnF6cXlncWd0Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4NDE0NDI5OCwiZXhwIjoyMDk5NzIwMjk4fQ.siz8OYqzfMuOI0dxUuwpQdrk1ywdwSqyKih3wOU4w_Q"
BUCKET_NAME="app-updates"
PROXY="http://127.0.0.1:10809"

# 1. Obtener versión del pubspec.yaml
VERSION=$(grep 'version: ' pubspec.yaml | sed 's/version: //')
CLEAN_VERSION=$(echo $VERSION | cut -d'+' -f1)
BUILD_NUMBER=$(echo $VERSION | cut -d'+' -f2)
PACKAGE_NAME="com.fusionpro.srecord.local"
echo "🚀 Iniciando publicación automática de S-RECORD v$VERSION (Build $BUILD_NUMBER)..."

# 2. Configurar Entorno Limpio para Android
export http_proxy=$PROXY
export https_proxy=$PROXY

# Limpiar variables que causan conflicto en Gradle/Android
unset ANDROID_PREFS_ROOT
unset ANDROID_SDK_HOME
# Usaremos ANDROID_USER_HOME que es la recomendada actualmente
export ANDROID_USER_HOME="/home/alejandro/.android"
export ANDROID_HOME="/home/alejandro/Android/Sdk"
export ANDROID_SDK_ROOT="/home/alejandro/Android/Sdk"

# 3. Construir APK de Flutter (Estándar)
echo "📦 Construyendo Release con Flutter..."
/home/alejandro/fvm/versions/stable/bin/flutter build apk --release --no-tree-shake-icons

if [ $? -ne 0 ]; then
    echo "❌ Error: Falló la construcción del APK."
    exit 1
fi

# El comando anterior genera el APK en esta ruta por defecto
APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
FILE_NAME="srecord_$VERSION.apk"

# 4. Subir APK a Supabase Storage
echo "☁️ Subiendo APK a Supabase Storage ($FILE_NAME)..."
curl -X POST "$SUPABASE_URL/storage/v1/object/$BUCKET_NAME/$FILE_NAME" \
     -H "Authorization: Bearer $SUPABASE_KEY" \
     -H "apikey: $SUPABASE_KEY" \
     -H "Content-Type: application/vnd.android.package-archive" \
     -H "x-upsert: true" \
     --progress-bar \
     --data-binary "@$APK_PATH"

if [ $? -ne 0 ]; then
    echo "❌ Error al subir el archivo a Supabase."
    exit 1
fi

PUBLIC_URL="$SUPABASE_URL/storage/v1/object/public/$BUCKET_NAME/$FILE_NAME"
echo "✅ APK subida con éxito: $PUBLIC_URL"

# 4.1 Calcular Hash para Integridad
echo "🔐 Calculando firma SHA-256..."
APK_HASH=$(sha256sum "$APK_PATH" | cut -d' ' -f1)

# 5. Actualizar tablas en Supabase
echo "📝 Registrando nueva versión en app_updates..."
curl -X POST "$SUPABASE_URL/rest/v1/app_updates" \
     -H "Authorization: Bearer $SUPABASE_KEY" \
     -H "apikey: $SUPABASE_KEY" \
     -H "Content-Type: application/json" \
     -H "Prefer: resolution=merge-duplicates" \
     -d "{\"package_name\": \"$PACKAGE_NAME\", \"version_code\": $BUILD_NUMBER, \"version_name\": \"$CLEAN_VERSION\", \"apk_url\": \"$PUBLIC_URL\", \"apk_hash\": \"$APK_HASH\", \"release_notes\": \"Actualización crítica v$VERSION disponible.\"}"

echo "📝 Actualizando configuración global (app_config)..."
curl -X PATCH "$SUPABASE_URL/rest/v1/app_config?platform=eq.android" \
     -H "Authorization: Bearer $SUPABASE_KEY" \
     -H "apikey: $SUPABASE_KEY" \
     -H "Content-Type: application/json" \
     -d "{\"min_version\": \"$CLEAN_VERSION\", \"update_url\": \"$PUBLIC_URL\", \"message\": \"Actualización crítica v$VERSION disponible.\"}"

echo "✨ PROCESO FINALIZADO CON ÉXITO ✨"
echo "La versión $VERSION ya es obligatoria para todos los usuarios."
