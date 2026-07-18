#!/bin/bash

# ==============================================================================
# Script: vociferate-pdf.single-lang--page-by-page.sh
# Descripción: Procesa un PDF página por página, generando audios en un único
#              idioma (original o traducción seleccionada) secuencialmente.
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
    WORKDIR="$PROJECT_ROOT/personal/tmp_page_by_page"
else
    TRANS_DIR="$PORTABLE_ROOT/portable-bin-PATH/bin"
    MONOLITHS_DIR="$SCRIPT_DIR"
    OUT_DIR="$PORTABLE_ROOT/personal/htm-pags"
    WORKDIR="$PORTABLE_ROOT/personal/tmp_page_by_page"
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
TARGET_LANG_OPT="${2:-}"

if [ -z "$PDF_PATH" ] || [ ! -f "$PDF_PATH" ]; then
    echo "Uso: $0 <archivo.pdf> [target_lang_option (0=original, 1=es, 2=en, 3=de)]"
    exit 1
fi

BASE_NAME=$(basename "$PDF_PATH")
ORIGIN_LANG=$(echo "$BASE_NAME" | rev | cut -d. -f2 | rev)
BOOK_NAME=$(echo "$BASE_NAME" | sed "s/\.${ORIGIN_LANG}\.pdf$//")

if [[ ! "$ORIGIN_LANG" =~ ^(en|es|de)$ ]]; then
    # Default original language to English if not specified in filename
    ORIGIN_LANG="en"
    BOOK_NAME="${BASE_NAME%.pdf}"
fi

# Determine target language from option
if [ -z "$TARGET_LANG_OPT" ]; then
    if [ -n "${OVERRIDE_LANG_OPT:-}" ]; then
        TARGET_LANG_OPT="$OVERRIDE_LANG_OPT"
    else
        echo "Seleccione el idioma de destino para vociferar:"
        echo "[0] vociferar en el idioma original"
        echo "[1] vociferar hacia el español"
        echo "[2] vociferar hacia el ingles"
        echo "[3] vociferar hacia el alemán"
        read -r -p "Selección [Por defecto: 0]: " TARGET_LANG_OPT || true
    fi
fi

TARGET_LANG_OPT=$(echo "$TARGET_LANG_OPT" | tr -d '[:space:]')
if [ -z "$TARGET_LANG_OPT" ]; then
    TARGET_LANG_OPT="0"
fi

case "$TARGET_LANG_OPT" in
    0) TARGET_LANG="$ORIGIN_LANG" ;;
    1) TARGET_LANG="es" ;;
    2) TARGET_LANG="en" ;;
    3) TARGET_LANG="de" ;;
    *) TARGET_LANG="$ORIGIN_LANG" ;;
esac

# --- Obtener total de páginas ---
TOTAL_PAGES=$(pdfinfo "$PDF_PATH" | grep "Pages:" | awk '{print $2}')
# fallback count if pdfinfo returns empty
if [ -z "$TOTAL_PAGES" ]; then
    if command -v qpdf >/dev/null 2>&1; then
        TOTAL_PAGES=$(qpdf --show-npages "$PDF_PATH")
    else
        TOTAL_PAGES=1
    fi
fi

echo "===================================================="
echo "[*] Libro: $BOOK_NAME"
echo "[*] Total Páginas: $TOTAL_PAGES"
echo "[*] Idioma Origen: $ORIGIN_LANG"
echo "[*] Idioma Destino Seleccionado: $TARGET_LANG"
echo "[*] Salida: $OUT_DIR"
echo "===================================================="

# --- Rango de páginas interactivo ---
START_PAGE=1
# Usando la misma lógica de override que en el script principal
if [ -n "${OVERRIDE_RANGE:-}" ]; then
    range_input="$OVERRIDE_RANGE"
    echo "[+] Usando rango de páginas predefinido: $range_input"
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
    START_PAGE=1
    END_PAGE=$TOTAL_PAGES
fi

# Ajustar límites
if (( START_PAGE < 1 )); then START_PAGE=1; fi
if (( END_PAGE < 1 )); then END_PAGE=1; fi
if (( START_PAGE > TOTAL_PAGES )); then START_PAGE=$TOTAL_PAGES; fi
if (( END_PAGE > TOTAL_PAGES )); then END_PAGE=$TOTAL_PAGES; fi
if (( START_PAGE > END_PAGE )); then
    tmp=$START_PAGE
    START_PAGE=$END_PAGE
    END_PAGE=$tmp
fi

# --- Función de traducción (reutilizada) ---
translate_text() {
    local target_lang=$1
    local input_file=$2
    local output_file=$3

    cat <<EOF > "$WORKDIR/translator_${PADDED_PAGE}_${target_lang}.py"
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

def chunk_text(text, size=4000):
    return [text[i:i+size] for i in range(0, len(text), size)]

try:
    with open("$input_file", 'r', encoding='utf-8') as f:
        text = f.read()
    if not text.strip():
        with open("$output_file", 'w') as f: f.write("")
        sys.exit(0)
        
    translator = GoogleTranslator(source='auto', target="$target_lang")
    chunks = chunk_text(text)
    translated_chunks = []
    
    for chunk in chunks:
        if chunk.strip():
            translated_chunks.append(translator.translate(chunk))
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
MAX_JOBS=$((TOTAL_THREADS / 2))
if [ "$MAX_JOBS" -lt 1 ]; then
    MAX_JOBS=1
fi

for (( page=START_PAGE; page<=END_PAGE; page++ )); do
    (
    PADDED_PAGE=$(printf "%04d" $page)
    OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${TARGET_LANG}.wav"
    OUT_MP3="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${TARGET_LANG}.mp3"
    
    if [ -s "$OUT_WAV" ] || [ -s "$OUT_MP3" ]; then
        echo ">>> PAGINA [$PADDED_PAGE / $TOTAL_PAGES] - Ya existe audio para $TARGET_LANG. Saltando."
        exit 0
    fi
    
    echo "[+] Iniciando PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] (en segundo plano)..."
    pdftotext -f $page -l $page -layout "$PDF_PATH" "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
    
    NEEDS_OCR=false
    if [ ! -s "$WORKDIR/raw_page_${PADDED_PAGE}.txt" ] || [ -z "$(tr -d '[:space:]' < "$WORKDIR/raw_page_${PADDED_PAGE}.txt")" ]; then
        NEEDS_OCR=true
    elif ! "$PY_BIN" "$SCRIPT_DIR/check_garbled.py" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$ORIGIN_LANG"; then
        NEEDS_OCR=true
    fi
    
    if [ "$NEEDS_OCR" = true ]; then
        case "$ORIGIN_LANG" in
            en) TESS_LANG="eng" ;;
            es) TESS_LANG="spa" ;;
            de) TESS_LANG="deu" ;;
            *)  TESS_LANG="eng" ;;
        esac
        if ! tesseract --list-langs | grep -q "^${TESS_LANG}$"; then
            TESS_LANG="eng"
        fi
        if pdftoppm -png -f $page -l $page -r 150 -singlefile "$PDF_PATH" "$WORKDIR/page_img_${PADDED_PAGE}" > /dev/null 2>&1; then
            if tesseract "$WORKDIR/page_img_${PADDED_PAGE}.png" "$WORKDIR/page_text_${PADDED_PAGE}" -l "$TESS_LANG" --oem 1 --psm 6 2>/dev/null; then
                cp "$WORKDIR/page_text_${PADDED_PAGE}.txt" "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
                rm -f "$WORKDIR/page_img_${PADDED_PAGE}.png" "$WORKDIR/page_text_${PADDED_PAGE}.txt"
            fi
        fi
    fi
    
    sed -i ':a;N;$!ba;s/-\n//g;s/\n\([^\n]\)/ \1/g' "$WORKDIR/raw_page_${PADDED_PAGE}.txt"
    if [ -f "$MONOLITHS_DIR/limpiador.py" ]; then "$PY_BIN" "$MONOLITHS_DIR/limpiador.py" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" > /dev/null 2>&1 || true; fi
    
    if [ ! -s "$WORKDIR/raw_page_${PADDED_PAGE}.txt" ]; then
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] vacía (saltada)."
        exit 0
    fi
    
    FINAL_TXT="$WORKDIR/text_${TARGET_LANG}_${PADDED_PAGE}.txt"
    if [ "$TARGET_LANG" == "$ORIGIN_LANG" ]; then
        cp "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$FINAL_TXT"
    else
        translate_text "$TARGET_LANG" "$WORKDIR/raw_page_${PADDED_PAGE}.txt" "$FINAL_TXT" || true
    fi
    
    MODEL="${MODELS[$TARGET_LANG]}"
    if cat "$FINAL_TXT" | "$PIPER_EXE" --model "$MODEL" --output_file "$OUT_WAV" > /dev/null 2>&1; then
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada correctamente."
    else
        echo "❌ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] error al generar audio."
    fi
    ) &
    
    while [ $(jobs -rp | wc -l) -ge $MAX_JOBS ]; do
        sleep 0.5
    done
done

wait

# Unir todos los WAVs de las páginas en un único WAV completo para el libro
FINAL_MERGED_WAV="$OUT_DIR/${BOOK_NAME}.${TARGET_LANG}.wav"
echo ""
echo "[+] Uniendo todas las páginas WAV en un solo archivo: $(basename "$FINAL_MERGED_WAV")..."
mapfile -t wav_files < <(ls -1 "$OUT_DIR"/"${BOOK_NAME}".page-[0-9][0-9][0-9][0-9]."${TARGET_LANG}".wav 2>/dev/null | sort)
if [ ${#wav_files[@]} -gt 0 ]; then
    if command -v sox >/dev/null 2>&1; then
        sox "${wav_files[@]}" "$FINAL_MERGED_WAV"
        echo "[!] Archivo único creado exitosamente en: $FINAL_MERGED_WAV"
    else
        echo "⚠️ Advertencia: 'sox' no está instalado. No se pudo unir en un único WAV."
    fi
else
    echo "⚠️ Advertencia: No se encontraron páginas WAV para unir."
fi

# Compile viewer
echo ""
echo "[+] Compilando visor monolítico para ${BOOK_NAME}..."
mkdir -p "$PORTABLE_ROOT/htm+audio"
"$PY_BIN" "$MONOLITHS_DIR/generar_htm_con_audios.py" "$PDF_PATH" "$PORTABLE_ROOT/htm+audio/${BOOK_NAME}.htm" || true

rm -rf "$WORKDIR"
echo "===================================================="
echo "[!] PROCESO COMPLETADO"
echo "===================================================="

