#!/bin/bash

# ==============================================================================
# Script: vociferate-pdf.from.en.to.es.and.de.sh
# Descripción: Automatiza la extracción, traducción y generación de audio MP3
#              en tres idiomas (Inglés, Español, Alemán) a partir de un PDF.
# ==============================================================================

set -e

# --- Configuración de rutas ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3.12 >/dev/null 2>&1; then PY_BIN=python3.12
elif command -v python3.11 >/dev/null 2>&1; then PY_BIN=python3.11
elif command -v python3.10 >/dev/null 2>&1; then PY_BIN=python3.10
elif command -v python3.9 >/dev/null 2>&1; then PY_BIN=python3.9
elif command -v python3.8 >/dev/null 2>&1; then PY_BIN=python3.8
else PY_BIN=python3; fi

PORTABLE_ROOT="${PORTABLE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -z "$PORTABLE_MODE" ]; then
    TRANS_DIR="$HOME/googletrans/dist"
    MONOLITHS_DIR="$HOME/monoliths-llm"
    OUT_DIR="$PROJECT_ROOT/htm+audio"
    WORKDIR="$PROJECT_ROOT/personal/tmp_vociferate"
else
    TRANS_DIR="$PORTABLE_ROOT/portable-bin-PATH/bin"
    MONOLITHS_DIR="$SCRIPT_DIR"
    OUT_DIR="$PORTABLE_ROOT/htm+audio"
    WORKDIR="$PORTABLE_ROOT/personal/tmp_vociferate"
fi

mkdir -p "$OUT_DIR"
mkdir -p "$WORKDIR"

# --- Modelos de Piper ---

source "$SCRIPT_DIR/find-piper.sh"
declare -A MODELS
MODELS[en]="$PIPER_MODEL_DIR/en_US-ryan-high.onnx"
MODELS[es]="$PIPER_MODEL_DIR/es_MX-claude-high.onnx"
MODELS[de]="$PIPER_MODEL_DIR/de_DE-thorsten-high.onnx"

# --- Argumentos ---
PDF_PATH="$1"

if [ -z "$PDF_PATH" ] || [ ! -f "$PDF_PATH" ]; then
    echo "Uso: $0 <archivo.en.pdf | archivo.es.pdf | archivo.de.pdf>"
    exit 1
fi

BASE_NAME=$(basename "$PDF_PATH")
# Extraer el idioma original de la extensión (ej: libro.en.pdf -> en)
ORIGIN_LANG=$(echo "$BASE_NAME" | rev | cut -d. -f2 | rev)
# Nombre del libro sin la extensión de idioma
BOOK_NAME=$(echo "$BASE_NAME" | sed "s/\.${ORIGIN_LANG}\.pdf$//")

if [[ ! "$ORIGIN_LANG" =~ ^[a-zA-Z]{2}$ ]]; then
    echo "Error: El archivo debe terminar en .XX.pdf donde XX es el código de idioma de dos letras"
    exit 1
fi

echo "[*] Libro detectado: $BOOK_NAME"
echo "[*] Idioma origen: $ORIGIN_LANG"

# --- Selección de idiomas a vociferar ---
echo ""
echo "Que idioma desea vociferar?"
echo "[0] Spanish"
echo "[1] English"
echo "[2] German"
echo "[3] Spanish and English"
echo "[4] Spanish and German"
echo "[5] English and German"
echo "[6] Spanish, English and German"
echo ""
read -r -p "type enter for [0] by default: " lang_selection || true
lang_selection=$(echo "$lang_selection" | tr -d '[:space:]')

# Por defecto es [0] Spanish
if [[ -z "$lang_selection" ]]; then
    lang_selection="0"
fi

case "$lang_selection" in
    0)
        LANGS=("es")
        ;;
    1)
        LANGS=("en")
        ;;
    2)
        LANGS=("de")
        ;;
    3)
        LANGS=("es" "en")
        ;;
    4)
        LANGS=("es" "de")
        ;;
    5)
        LANGS=("en" "de")
        ;;
    6)
        LANGS=("es" "en" "de")
        ;;
    *)
        echo "⚠️ Selección no reconocida. Usando por defecto: Spanish."
        LANGS=("es")
        ;;
esac

echo "[+] Idiomas seleccionados para vociferar: ${LANGS[*]}"


# --- Función de traducción robusta ---
# Divide el texto en fragmentos para evitar límites de la API de Google
# --- Selección de motor de traducción ---
if [ -z "${TRANSLATOR_SERVICE:-}" ]; then
    echo ""
    echo "Seleccione el motor de traducción:"
    echo "[0] google-translate (Internet required)"
    echo "[1] apertium (No DRM, No internet optional)"
    echo ""
    trans_service_choice="0"
    if [ -t 0 ]; then
        while true; do
            read -r -p "Seleccione opción [0/1] (Por defecto: 0): " input_trans_service || true
            if [[ "$input_trans_service" == "1" ]]; then
                trans_service_choice="1"
                break
            elif [[ "$input_trans_service" == "0" || -z "$input_trans_service" ]]; then
                trans_service_choice="0"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        trans_service_choice="0"
        echo "[Auto] Seleccionado google-translate (0) debido a entrada no interactiva"
    fi

    if [[ "$trans_service_choice" == "1" ]]; then
        export TRANSLATOR_SERVICE="apertium"
    else
        export TRANSLATOR_SERVICE="google"
    fi
fi

translate_text() {
    local target_lang=$1
    local input_file=$2
    local output_file=$3

    echo "[*] Traduciendo a $target_lang..."
    
    # Creamos un script de python temporal para manejar la traducción de forma robusta
    # ya que no todos los idiomas tienen un binario en dist/
    cat <<EOF > "$WORKDIR/translator.py"
import os
import sys

# Dynamically add portable python site-packages to sys.path
project_root = "$PORTABLE_ROOT"
for folder in os.listdir(project_root):
    if folder.startswith('portable-bin-'):
        site_pkg = os.path.join(project_root, folder, 'python', 'site-packages')
        if os.path.exists(site_pkg) and site_pkg not in sys.path:
            sys.path.insert(0, site_pkg)

from deep_translator import GoogleTranslator
import time
import subprocess
import shutil

target = "$target_lang"
input_path = "$input_file"
output_path = "$output_file"

def call_apertium(text, mode):
    selected_portable = os.environ.get('SELECTED_PORTABLE_DIR')
    portable_dir = None
    if selected_portable and os.path.exists(os.path.join(project_root, selected_portable)):
        portable_dir = os.path.join(project_root, selected_portable)
    else:
        for folder in os.listdir(project_root):
            if folder.startswith('portable-bin-'):
                portable_dir = os.path.join(project_root, folder)
                break
            
    env = os.environ.copy()
    if portable_dir:
        apertium_bin = os.path.join(portable_dir, "bin", "apertium")
        lib_path = os.path.join(portable_dir, "lib")
        lib64_path = os.path.join(portable_dir, "lib64")
        datadir = os.path.join(portable_dir, "share", "apertium")
        env["LD_LIBRARY_PATH"] = f"/usr/lib64:{lib64_path}:{lib_path}:{env.get('LD_LIBRARY_PATH', '')}"
        env["APERTIUM_DATADIR"] = datadir
        # Si apertium está instalado en el sistema anfitrión se usa el binario nativo con los diccionarios portables
        if shutil.which("apertium"):
            cmd = "apertium"
        elif os.path.exists(apertium_bin):
            cmd = apertium_bin
        else:
            cmd = "apertium"
    else:
        cmd = "apertium"
        
    try:
        res = subprocess.run(
            [cmd, mode],
            input=text.encode('utf-8'),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env
        )
        if res.returncode == 0:
            raw_out = res.stdout.decode('utf-8').strip()
            return re.sub(r'[*@#~]', '', raw_out)
        else:
            print(f"⚠️ Apertium error: {res.stderr.decode('utf-8')}", file=sys.stderr)
    except Exception as e:
        print(f"⚠️ Error running apertium: {e}", file=sys.stderr)
    return text

def translate_apertium(text, source_lang, target_lang):
    lang_map = {'es': 'spa', 'en': 'eng', 'de': 'deu'}
    src = lang_map.get(source_lang, source_lang)
    tgt = lang_map.get(target_lang, target_lang)
    
    if src == tgt:
        return text
        
    direct_modes = ['eng-spa', 'spa-eng', 'eng-deu', 'deu-eng']
    mode = f"{src}-{tgt}"
    if mode in direct_modes:
        return call_apertium(text, mode)
    else:
        if src != 'eng' and tgt != 'eng':
            intermediate = call_apertium(text, f"{src}-eng")
            return call_apertium(intermediate, f"eng-{tgt}")
    return text

def chunk_text(text, size=4000):
    return [text[i:i+size] for i in range(0, len(text), size)]

try:
    with open(input_path, 'r', encoding='utf-8') as f:
        text = f.read()
    
    service = os.environ.get('TRANSLATOR_SERVICE', 'google').lower()
    chunks = chunk_text(text)
    translated_chunks = []
    
    if service == 'apertium':
        source_lang = "en"
        for i, chunk in enumerate(chunks):
            print(f"    Progreso: {i+1}/{len(chunks)} fragmentos (Apertium)", file=sys.stderr)
            if chunk.strip():
                translated_chunks.append(translate_apertium(chunk, source_lang, target))
            else:
                translated_chunks.append(chunk)
    else:
        translator = GoogleTranslator(source='auto', target=target)
        for i, chunk in enumerate(chunks):
            print(f"    Progreso: {i+1}/{len(chunks)} fragmentos", file=sys.stderr)
            if chunk.strip():
                translated_chunk = None
                attempt = 1
                while True:
                    try:
                        translated_chunk = translator.translate(chunk)
                        if translated_chunk and "server error" not in translated_chunk.lower():
                            break
                        else:
                            print(f"⚠️ Translation returned empty or 'server error' (attempt {attempt})", file=sys.stderr)
                    except Exception as e:
                        print(f"⚠️ Error translating chunk (attempt {attempt}): {e}", file=sys.stderr)
                    print("⏳ Esperando 1 segundo para reintentar traducción...", file=sys.stderr)
                    time.sleep(1)
                    attempt += 1
                
                translated_chunks.append(translated_chunk)
            else:
                translated_chunks.append(chunk)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(" ".join(translated_chunks))
except Exception as e:
    print(f"⚠️ Alerta: Error en traducción a {target} ({e}). Usando texto original como fallback.", file=sys.stderr)
    try:
        if 'text' not in locals():
            with open(input_path, 'r', encoding='utf-8') as f_in:
                text = f_in.read()
        with open(output_path, 'w', encoding='utf-8') as f_out:
            f_out.write(text)
        sys.exit(0)
    except Exception as fallback_err:
        print(f"Error crítico en fallback: {fallback_err}", file=sys.stderr)
        sys.exit(1)
EOF

    # Ejecutar usando el entorno virtual de googletrans si existe, sino python3
    "$PY_BIN" "$WORKDIR/translator.py" 
}

# --- Paso 1: Extracción y Limpieza de Texto ---
echo "[*] Extrayendo texto del PDF..."
pdftotext -layout "$PDF_PATH" "$WORKDIR/raw.txt"

echo "[*] Limpiando texto..."
# Quitar cortes de palabras y normalizar
sed -i ':a;N;$!ba;s/-\n//g;s/\n\([^\n]\)/ \1/g' "$WORKDIR/raw.txt"
# Usar el limpiador oficial del sistema
"$PY_BIN" "$MONOLITHS_DIR/limpiador.py" "$WORKDIR/raw.txt"
# El limpiador genera raw.txt (sobreescribe o crea con el mismo nombre base)
# Según limpiador.py: ruta_salida = f"{nombre_base}.txt" -> raw.txt

# --- Paso 2: Bucle de Generación ---


for LANG in "${LANGS[@]}"; do
    echo "----------------------------------------------------"
    echo "[>>>] PROCESANDO IDIOMA: $LANG"
    
    FINAL_TXT="$WORKDIR/text_$LANG.txt"
    FINAL_WAV="$WORKDIR/audio_$LANG.wav"
    
    # Determinar si requiere traducción
    if [ "$LANG" == "$ORIGIN_LANG" ]; then
        echo "[*] Idioma original detectado, saltando traducción."
        cp "$WORKDIR/raw.txt" "$FINAL_TXT"
    else
        translate_text "$LANG" "$WORKDIR/raw.txt" "$FINAL_TXT"
    fi
    
    # Generar Audio con Piper
    echo "[*] Generando audio con Piper (Voz: $LANG)..."
    MODEL="${MODELS[$LANG]}"
    cat "$FINAL_TXT" | "$PIPER_EXE" --model "$MODEL" --output_file "$FINAL_WAV" --progress
    
    # Convertir a MP3 y dividir en partes de 95MB
    # Usamos ffmpeg con el muxer 'segment' para dividir automáticamente
    echo "[*] Convirtiendo y dividiendo en MP3 (máx 95MB)..."
    
    # Primero convertimos a un MP3 maestro (temporal) para medir o procesar
    MASTER_MP3="$WORKDIR/master_$LANG.mp3"
    ffmpeg -i "$FINAL_WAV" -f wav - -hide_banner -loglevel error | lame -b 128 - "$MASTER_MP3" > /dev/null 2>&1
    
    # Dividir el MP3 en partes de 95MB
    # Usamos el comando segment de ffmpeg. 
    # Para asegurar el tamaño, calculamos el tiempo aproximado. 
    # 128kbps = 16KB/s. 95MB = 97280KB. 97280 / 16 = 6080 segundos (~101 min).
    SEGMENT_TIME=6000 
    
    OUTPUT_PATTERN="$OUT_DIR/${BOOK_NAME}.origen_${ORIGIN_LANG}.voz_${LANG}.parte%02d.mp3"
    
    ffmpeg -y -i "$MASTER_MP3" -f segment -segment_time "$SEGMENT_TIME" -c copy "$OUTPUT_PATTERN" -hide_banner -loglevel error

    echo "[+] Archivos generados para voz $LANG en $OUT_DIR"
done

# --- Limpieza Final ---
rm -rf "$WORKDIR"
echo "----------------------------------------------------"
echo "[!] PROCESO COMPLETADO EXITOSAMENTE"
echo "[!] Los archivos están en: $OUT_DIR"
