#!/bin/bash

# ==============================================================================
# Script: vociferate-pdf.from.de.to.en.and.es--page-by-page.sh
# Descripción: Procesa un PDF en Alemán página por página, generando audios 
#              en 3 idiomas (Original en alemán + traducción a inglés y español)
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
    OUT_DIR="$PROJECT_ROOT/personal/htm-pags"
    WORKDIR="$PROJECT_ROOT/personal/tmp_page_by_page_de"
else
    TRANS_DIR="$PORTABLE_ROOT/portable-bin-PATH/bin"
    MONOLITHS_DIR="$SCRIPT_DIR"
    OUT_DIR="$PORTABLE_ROOT/personal/htm-pags"
    WORKDIR="$PORTABLE_ROOT/personal/tmp_page_by_page_de"
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
    echo "Uso: $0 <archivo.de.pdf>"
    exit 1
fi

BASE_NAME=$(basename "$PDF_PATH")
ORIGIN_LANG=$(echo "$BASE_NAME" | rev | cut -d. -f2 | rev)
BOOK_NAME=$(echo "$BASE_NAME" | sed "s/\.${ORIGIN_LANG}\.pdf$//")

if [ "$ORIGIN_LANG" != "de" ]; then
    echo "Error: El archivo debe terminar en .de.pdf para ser procesado por este script."
    exit 1
fi

# --- Obtener total de páginas ---
TOTAL_PAGES=$(pdfinfo "$PDF_PATH" | grep "Pages:" | awk '{print $2}')

echo "===================================================="
echo "[*] Libro: $BOOK_NAME"
echo "[*] Total Páginas: $TOTAL_PAGES"
echo "[*] Idioma Origen: $ORIGIN_LANG"
echo "[*] Salida: $OUT_DIR"
echo "===================================================="

# --- Rango de páginas interactivo ---
START_PAGE=1
END_PAGE=$TOTAL_PAGES

if [ -n "${OVERRIDE_RANGE:-}" ]; then
    range_input="$OVERRIDE_RANGE"
    echo "[+] Usando rango de páginas predefinido (OVERRIDE_RANGE): $range_input"
else
    echo ""
    echo "Desde qué página a qué página desea convertir:"
    echo "  [0] todas (1 a $TOTAL_PAGES)"
    echo "  ejemplo [5-15] para del 5 al 15"
    echo "  [10] desde la 1 hasta la 10"
    echo ""
    read -r -p "Selección [Por defecto: 0]: " range_input || true
fi
range_input=$(echo "$range_input" | tr -d '[:space:]')

if [[ -z "$range_input" || "$range_input" == "0" ]]; then
    START_PAGE=1
    END_PAGE=$TOTAL_PAGES
elif [[ "$range_input" =~ ^[0-9]+-[0-9]+$ ]]; then
    START_PAGE=$(echo "$range_input" | cut -d'-' -f1)
    END_PAGE=$(echo "$range_input" | cut -d'-' -f2)
elif [[ "$range_input" =~ ^[0-9]+$ ]]; then
    START_PAGE=1
    END_PAGE="$range_input"
else
    echo "⚠️ Selección no reconocida. Usando rango por defecto: todas (1 a $TOTAL_PAGES)."
    START_PAGE=1
    END_PAGE=$TOTAL_PAGES
fi

# Ajustar límites de página por seguridad
if (( START_PAGE < 1 )); then START_PAGE=1; fi
if (( END_PAGE < 1 )); then END_PAGE=1; fi
if (( START_PAGE > TOTAL_PAGES )); then START_PAGE=$TOTAL_PAGES; fi
if (( END_PAGE > TOTAL_PAGES )); then END_PAGE=$TOTAL_PAGES; fi

if (( START_PAGE > END_PAGE )); then
    # Intercambiar si están invertidos
    tmp=$START_PAGE
    START_PAGE=$END_PAGE
    END_PAGE=$tmp
fi

echo "[+] Rango seleccionado: Páginas $START_PAGE a $END_PAGE"

# --- Selección de idiomas a vociferar ---
if [ -n "${OVERRIDE_LANG:-}" ]; then
    lang_selection="$OVERRIDE_LANG"
    echo "[+] Usando idioma de vociferación predefinido (OVERRIDE_LANG): $lang_selection"
else
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
fi
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


# --- Función de traducción ---
# --- Selección de motor de traducción ---
if [ -z "${TRANSLATOR_SERVICE:-}" ]; then
    echo ""
    echo "Seleccione si desea usar un servicio de google ...o un comando sin salir a internet para traducir:"
    echo "[0] google-translate (Internet required)"
    echo "[1] apertium (No DRM... No internet? no problem, internet is optional)"
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

# --- Selección de optimización de audio ---
if [ -z "${AUDIO_OPTIMIZE:-}" ]; then
    echo ""
    echo "Elija una optimización:"
    echo ""
    echo "[0] Comprimir brutalmente, pero compresiblemente audible"
    echo "[1] No comprimir, tengo oido de músico, tengo discos grandes"
    echo ""
    opt_choice="0"
    if [ -t 0 ]; then
        while true; do
            read -r -p "Seleccione opción [0/1] (Por defecto: 0): " input_opt || true
            if [[ "$input_opt" == "1" ]]; then
                opt_choice="1"
                break
            elif [[ "$input_opt" == "0" || -z "$input_opt" ]]; then
                opt_choice="0"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        opt_choice="0"
        echo "[Auto] Seleccionado Comprimir brutalmente (0) debido a entrada no interactiva"
    fi

    if [[ "$opt_choice" == "0" ]]; then
        echo ""
        echo "De acuerdo se comprimirá brutalmente entonces ahorrará 75% de MB"
        export AUDIO_OPTIMIZE="1"
    else
        export AUDIO_OPTIMIZE="0"
    fi
fi

# --- Selección de formato del resultado / WhatsApp ---
if [ -z "${WHATSAPP_SPLIT:-}" ]; then
    echo ""
    echo "Elija una opción para el resultado:"
    echo ""
    echo "[0] Compartible por whatsapp"
    echo "[1] Para mi mismo en un solo archivo es suficiente"
    echo ""
    wa_choice="1"
    if [ -t 0 ]; then
        while true; do
            read -r -p "Seleccione opción [0/1] (Por defecto: 0): " input_wa || true
            if [[ "$input_wa" == "0" || -z "$input_wa" ]]; then
                wa_choice="0"
                break
            elif [[ "$input_wa" == "1" ]]; then
                wa_choice="1"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        wa_choice="0"
    fi

    if [[ "$wa_choice" == "0" ]]; then
        export WHATSAPP_SPLIT="1"
    else
        export WHATSAPP_SPLIT="0"
    fi
fi

translate_text() {
    local target_lang=$1
    local input_file=$2
    local output_file=$3

    cat <<EOF > "$WORKDIR/translator_${PADDED_PAGE}_${target_lang}.py"
import os
import sys
import re

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
            # Eliminar marcadores sintácticos de Apertium (*, @, #, ~) para que el lector TTS no los pronuncie
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
    with open("$input_file", 'r', encoding='utf-8') as f:
        text = f.read()
    if not text.strip():
        with open("$output_file", 'w') as f: f.write("")
        sys.exit(0)
        
    service = os.environ.get('TRANSLATOR_SERVICE', 'google').lower()
    chunks = chunk_text(text)
    translated_chunks = []
    
    if service == 'apertium':
        source_lang = "$ORIGIN_LANG"
        for chunk in chunks:
            if chunk.strip():
                translated_chunks.append(translate_apertium(chunk, source_lang, "$target_lang"))
            else:
                translated_chunks.append(chunk)
    else:
        translator = GoogleTranslator(source='auto', target="$target_lang")
        for chunk in chunks:
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
            
    with open("$output_file", 'w', encoding='utf-8') as f:
        f.write(" ".join(translated_chunks))
except Exception as e:
    print(f"⚠️ Error en traducción a $target_lang ({e}). Usando original.", file=sys.stderr)
    try:
        if 'text' not in locals():
            with open("$input_file", 'r', encoding='utf-8') as f_in:
                text = f_in.read()
        with open("$output_file", 'w', encoding='utf-8') as f_out:
            f_out.write(text)
        sys.exit(0)
    except Exception as fallback_err:
        sys.exit(1)
EOF

    "$PY_BIN" "$WORKDIR/translator_${PADDED_PAGE}_${target_lang}.py" 
}

TOTAL_THREADS=$(nproc)
if [ -n "${PARALLEL_JOBS:-}" ]; then
    MAX_JOBS="$PARALLEL_JOBS"
elif [ "$TOTAL_THREADS" -gt 4 ]; then
    MAX_JOBS=$(( TOTAL_THREADS - 2 ))
elif [ "$TOTAL_THREADS" -gt 1 ]; then
    MAX_JOBS=$(( TOTAL_THREADS - 1 ))
else
    MAX_JOBS=1
fi

echo "🚀 CPU detectada: $TOTAL_THREADS hilos. Ejecutando $MAX_JOBS procesos en paralelo simultáneamente..."

for (( page=START_PAGE; page<=END_PAGE; page++ )); do
    (

    PADDED_PAGE=$(printf "%04d" $page)
    
    # 1. Comprobar si ya existen todos los audios de los idiomas solicitados para esta página
    ALL_EXIST=true
    for L in "${LANGS[@]}"; do
        if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
            W="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.optime.${L}.wav"
        else
            W="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${L}.wav"
        fi
        M="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${L}.mp3"
        # Si NO existe un archivo WAV no vacío Y tampoco existe un archivo MP3 no vacío, entonces falta el audio para este idioma.
        if [ ! -s "$W" ] && [ ! -s "$M" ]; then
            ALL_EXIST=false
            break
        fi
    done
    
    if [ "$ALL_EXIST" = true ] && [ "${FORCE_RENEW_CACHE:-0}" != "1" ]; then
        echo ">>> PAGINA [$PADDED_PAGE / $TOTAL_PAGES] - Ya existen todos los audios (${LANGS[*]}). Saltando extracción."
        exit 0
    fi
    
    echo "[+] Iniciando PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] (en segundo plano)..."
    
    # 1. Extraer solo esta página
    pdftotext -f $page -l $page -layout "$PDF_PATH" "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
    
    # Fallback OCR si pdftotext no extrae nada de texto real o si el texto extraído es ilegible/garboso
    NEEDS_OCR=false
    if [ ! -s "$WORKDIR/raw_page_${PADDED_PAGE}.txt" ] || [ -z "$(tr -d '[:space:]' < "$WORKDIR/raw_page_${PADDED_PAGE}.txt")" ]; then
        NEEDS_OCR=true
        echo "    [*] Página vacía digitalmente. Ejecutando OCR (Tesseract)..."
    elif ! "$PY_BIN" "$SCRIPT_DIR/check_garbled.py" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$ORIGIN_LANG"; then
        NEEDS_OCR=true
        echo "    [!] Texto digital detectado como ilegible/corrupto. Forzando OCR (Tesseract)..."
    fi
    
    if [ "$NEEDS_OCR" = true ]; then
        echo "    [*] OCR activado para página $PADDED_PAGE (texto vacío o corrupto detectado)..."
        # Determinar idioma para Tesseract y comprobar disponibilidad
        case "$ORIGIN_LANG" in
            en) TESS_LANG="eng" ;;
            es) TESS_LANG="spa" ;;
            de) TESS_LANG="deu" ;;
            *)  TESS_LANG="deu" ;;
        esac
        
        # Verificar si Tesseract tiene el idioma instalado, si no, fallback a deu
        if ! tesseract --list-langs | grep -q "^${TESS_LANG}$"; then
            TESS_LANG="deu"
        fi
        
        # Convertir página a imagen PNG temporal a 150 DPI
        if pdftoppm -png -f $page -l $page -r 150 -singlefile "$PDF_PATH" "$WORKDIR/page_img_${PADDED_PAGE}" > /dev/null 2>&1; then
            # Correr OCR Tesseract con configuraciones de segmentación recomendadas
            if tesseract "$WORKDIR/page_img_${PADDED_PAGE}.png" "$WORKDIR/page_text_${PADDED_PAGE}" -l "$TESS_LANG" --oem 1 --psm 6 2>/dev/null; then
                cp "$WORKDIR/page_text_${PADDED_PAGE}.txt" "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
                rm -f "$WORKDIR/page_img_${PADDED_PAGE}.png" "$WORKDIR/page_text_${PADDED_PAGE}.txt"
            fi
        fi
    fi
    
    # 2. Limpieza básica y formal
    sed -i ':a;N;$!ba;s/-\n//g;s/\n\([^\n]\)/ \1/g' "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
    if [ -f "$MONOLITHS_DIR/limpiador.py" ]; then "$PY_BIN" "$MONOLITHS_DIR/limpiador.py" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" > /dev/null 2>&1 || true; else echo "    [WARNING] limpiador.py no encontrado. Omitiendo limpieza."; fi
    
    # Si la página está vacía, saltar
    if [ ! -s "$WORKDIR/raw_page_${PADDED_PAGE}.txt" ]; then
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] vacía (saltada)."
        exit 0
    fi
 
    # 3. Generar los idiomas seleccionados para esta página
    for LANG in "${LANGS[@]}"; do
        FINAL_TXT="$WORKDIR/text_${LANG}_${PADDED_PAGE}.txt"
        if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
            OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.optime.${LANG}.wav"
            UNOPT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${LANG}.wav"
        else
            OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${LANG}.wav"
            UNOPT_WAV=""
        fi
        OUT_MP3="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${LANG}.mp3"
        
        # Saltarse si ya existe en WAV o MP3 para evitar regeneración redundante
        if ([ -s "$OUT_WAV" ] || [ -s "$OUT_MP3" ]) && [ "${FORCE_RENEW_CACHE:-0}" != "1" ]; then
            echo "    [+] $LANG: Ya existe, saltando."
            continue
        fi

        # Reutilización inteligente: Si ya existe el audio original sin comprimir y ahora se solicita optimizar
        if [ "${AUDIO_OPTIMIZE:-0}" == "1" ] && [ -n "$UNOPT_WAV" ] && [ -s "$UNOPT_WAV" ] && [ "${FORCE_RENEW_CACHE:-0}" != "1" ]; then
            echo "    ⚡ $LANG: Reutilizando audio existente para comprimir..."
            if command -v sox >/dev/null 2>&1; then
                sox "$UNOPT_WAV" -r 16000 -c 1 -b 8 "$OUT_WAV" 2>/dev/null || cp "$UNOPT_WAV" "$OUT_WAV"
            else
                cp "$UNOPT_WAV" "$OUT_WAV"
            fi
            echo "    [✔] $LANG: Comprimido y optimizado a partir del audio existente."
            continue
        fi
 
        # Traducción si aplica
        if [ "$LANG" == "$ORIGIN_LANG" ]; then
            cp "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$FINAL_TXT"
        else
            echo "    [*] $LANG: Traduciendo..."
            translate_text "$LANG" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$FINAL_TXT" || true
        fi
        
        # Piper (genera .wav directo a destino, rápido y liviano)
        echo "    [*] $LANG: Generando audio..."
        MODEL="${MODELS[$LANG]}"
        RAW_PAGE_WAV="$WORKDIR/raw_audio_${PADDED_PAGE}_${LANG}.wav"
        if cat "$FINAL_TXT" | "$PIPER_EXE" --model "$MODEL" --output_file "$RAW_PAGE_WAV" > /dev/null 2>&1; then
            if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
                if command -v sox >/dev/null 2>&1; then
                    sox "$RAW_PAGE_WAV" -r 16000 -c 1 -b 8 "$OUT_WAV" 2>/dev/null || cp "$RAW_PAGE_WAV" "$OUT_WAV"
                    rm -f "$RAW_PAGE_WAV"
                else
                    mv "$RAW_PAGE_WAV" "$OUT_WAV"
                fi
                echo "    [✔] $LANG: Audio generado, comprimido y optimizado."
            else
                mv "$RAW_PAGE_WAV" "$OUT_WAV"
                echo "    [✔] $LANG: Audio generado."
            fi
        fi
    done
    if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada, comprimida y optimizada correctamente."
    else
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada correctamente."
    fi
    ) &

    # Limit concurrent jobs
    while [ $(jobs -rp | wc -l) -ge $MAX_JOBS ]; do
        sleep 0.5
    done
done

# Wait for all background jobs to finish
wait

# Unir todos los WAVs de las páginas en archivos completos para cada idioma
if command -v sox >/dev/null 2>&1; then
    for L in "${LANGS[@]}"; do
        wav_files=()
        if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
            FINAL_MERGED_WAV="$OUT_DIR/${BOOK_NAME}.optime.${L}.wav"
            for f in "$OUT_DIR"/"${BOOK_NAME}".page-[0-9][0-9][0-9][0-9].optime."${L}".wav; do
                [ -f "$f" ] && wav_files+=("$f")
            done
        else
            FINAL_MERGED_WAV="$OUT_DIR/${BOOK_NAME}.${L}.wav"
            for f in "$OUT_DIR"/"${BOOK_NAME}".page-[0-9][0-9][0-9][0-9]."${L}".wav; do
                [ -f "$f" ] && wav_files+=("$f")
            done
        fi
        if [ ${#wav_files[@]} -gt 0 ]; then
            echo ""
            echo "[+] Uniendo todas las páginas WAV para $L en un solo archivo: $(basename "$FINAL_MERGED_WAV")..."
            sox "${wav_files[@]}" "$FINAL_MERGED_WAV" 2>/dev/null || true
            echo "[!] Archivo único creado exitosamente en: $FINAL_MERGED_WAV"

            # Partir para WhatsApp si fue solicitado agrupando páginas directamente en MP3 ligero (< 60 MB)
            if [ "${WHATSAPP_SPLIT:-0}" == "1" ]; then
                echo "📱 Agrupando páginas en partes MP3 para WhatsApp ($L) (límite: < 60 MB por parte)..."
                WA_TARGET_DIR="$PORTABLE_ROOT/compartir-whatsapp/${BOOK_NAME}_${L}"
                mkdir -p "$WA_TARGET_DIR"
                max_wav_bytes=$(( 110 * 1024 * 1024 ))
                current_batch=()
                current_size=0
                part_idx=1
                
                for wfile in "${wav_files[@]}"; do
                    [ -f "$wfile" ] || continue
                    fsize=$(stat -c%s "$wfile" 2>/dev/null || wc -c < "$wfile")
                    
                    if [ ${#current_batch[@]} -gt 0 ] && [ $(( current_size + fsize )) -gt $max_wav_bytes ]; then
                        out_part=$(printf "%s/%s-%s-WhatsApp-Parte_%03d.mp3" "$WA_TARGET_DIR" "$BOOK_NAME" "$L" "$part_idx")
                        echo "   📲 Creando Parte $part_idx (${#current_batch[@]} páginas, convirtiendo a MP3 liviano)..."
                        if command -v ffmpeg >/dev/null 2>&1 && command -v sox >/dev/null 2>&1; then
                            sox "${current_batch[@]}" -t wav - 2>/dev/null | ffmpeg -y -i - -c:a libmp3lame -b:a 64k -ar 22050 -ac 1 "$out_part" >/dev/null 2>&1 || true
                        elif command -v sox >/dev/null 2>&1; then
                            sox "${current_batch[@]}" -C 64 "$out_part" 2>/dev/null || true
                        fi
                        part_size=$(du -h "$out_part" 2>/dev/null | awk '{print $1}' || echo "OK")
                        echo "      ✅ Parte $part_idx lista ($part_size)"
                        part_idx=$(( part_idx + 1 ))
                        current_batch=()
                        current_size=0
                    fi
                    current_batch+=("$wfile")
                    current_size=$(( current_size + fsize ))
                done
                
                if [ ${#current_batch[@]} -gt 0 ]; then
                    out_part=$(printf "%s/%s-%s-WhatsApp-Parte_%03d.mp3" "$WA_TARGET_DIR" "$BOOK_NAME" "$L" "$part_idx")
                    echo "   📲 Creando Parte $part_idx (${#current_batch[@]} páginas, convirtiendo a MP3 liviano)..."
                    if command -v ffmpeg >/dev/null 2>&1 && command -v sox >/dev/null 2>&1; then
                        sox "${current_batch[@]}" -t wav - 2>/dev/null | ffmpeg -y -i - -c:a libmp3lame -b:a 64k -ar 22050 -ac 1 "$out_part" >/dev/null 2>&1 || true
                    elif command -v sox >/dev/null 2>&1; then
                        sox "${current_batch[@]}" -C 64 "$out_part" 2>/dev/null || true
                    fi
                    part_size=$(du -h "$out_part" 2>/dev/null | awk '{print $1}' || echo "OK")
                    echo "      ✅ Parte $part_idx lista ($part_size)"
                fi
                echo "[!] ✅ Partes MP3 para WhatsApp para $L creadas exitosamente en: $WA_TARGET_DIR"
            fi
        fi
    done
fi

# Compilar visor monolítico htm+audio una única vez al finalizar todas las páginas
echo ""
echo "[+] Compilando visor monolítico para ${BOOK_NAME}..."
mkdir -p "$PORTABLE_ROOT/htm+audio"
"$PY_BIN" "$MONOLITHS_DIR/generar_htm_con_audios.py" "$PDF_PATH" "$PORTABLE_ROOT/htm+audio/${BOOK_NAME}.htm" || true

# Limpieza final
rm -rf "$WORKDIR"
echo ""
echo "===================================================="
echo "[!] PROCESO DE PÁGINAS COMPLETADO (ALEMÁN)"
echo "===================================================="
