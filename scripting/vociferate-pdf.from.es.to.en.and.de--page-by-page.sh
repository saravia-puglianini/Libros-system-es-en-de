#!/bin/bash

# ==============================================================================
# Script: vociferate-pdf.from.es.to.en.and.de--page-by-page.sh
# Descripción: Procesa un PDF en Español página por página, generando audios 
#              en 3 idiomas (Original en español + traducción a inglés y alemán)
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
    WORKDIR="$PROJECT_ROOT/personal/tmp_page_by_page_es"
else
    TRANS_DIR="$PORTABLE_ROOT/portable-bin-PATH/bin"
    MONOLITHS_DIR="$SCRIPT_DIR"
    OUT_DIR="$PORTABLE_ROOT/personal/htm-pags"
    WORKDIR="$PORTABLE_ROOT/personal/tmp_page_by_page_es"
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
    echo "Uso: $0 <archivo.es.pdf>"
    exit 1
fi

BASE_NAME=$(basename "$PDF_PATH")
ORIGIN_LANG=$(echo "$BASE_NAME" | rev | cut -d. -f2 | rev)
BOOK_NAME=$(echo "$BASE_NAME" | sed "s/\.${ORIGIN_LANG}\.pdf$//")

if [ "$ORIGIN_LANG" != "es" ]; then
    echo "Error: El archivo debe terminar en .es.pdf para ser procesado por este script."
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
    print(f"⚠️ Alerta: Error en traducción a $target_lang ({e}). Usando texto original como fallback.", file=sys.stderr)
    try:
        if 'text' not in locals():
            with open("$input_file", 'r', encoding='utf-8') as f_in:
                text = f_in.read()
        with open("$output_file", 'w', encoding='utf-8') as f_out:
            f_out.write(text)
        sys.exit(0)
    except Exception as fallback_err:
        print(f"Error crítico en fallback: {fallback_err}", file=sys.stderr)
        sys.exit(1)
EOF

    "$PY_BIN" "$WORKDIR/translator_${PADDED_PAGE}_${target_lang}.py" 
}

# --- Bucle por Página ---
TOTAL_THREADS=$(nproc)
MAX_JOBS=$((TOTAL_THREADS / 2))
if [ "$MAX_JOBS" -lt 1 ]; then
    MAX_JOBS=1
fi
echo "[+] Detectados $TOTAL_THREADS hilos. Procesando con $MAX_JOBS procesos en paralelo (mitad lógica)."

for (( page=START_PAGE; page<=END_PAGE; page++ )); do
    (

    PADDED_PAGE=$(printf "%04d" $page)
    
    # 0. Comprobar si ya existen todos los audios para esta página
    ALL_EXIST=true
    for L in "${LANGS[@]}"; do
        W="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${L}.wav"
        M="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${L}.mp3"
        # Si NO existe un archivo WAV no vacío Y tampoco existe un archivo MP3 no vacío, entonces falta el audio para este idioma.
        if [ ! -s "$W" ] && [ ! -s "$M" ]; then
            ALL_EXIST=false
            break
        fi
    done
    
    if [ "$ALL_EXIST" = true ]; then
        echo ">>> PAGINA [$PADDED_PAGE / $TOTAL_PAGES] - Ya existen todos los audios. Saltando."
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
        # Determinar idioma para Tesseract y comprobar disponibilidad
        case "$ORIGIN_LANG" in
            en) TESS_LANG="eng" ;;
            es) TESS_LANG="spa" ;;
            de) TESS_LANG="deu" ;;
            *)  TESS_LANG="eng" ;;
        esac
        
        # Verificar si Tesseract tiene el idioma instalado, si no, fallback a eng
        if ! tesseract --list-langs | grep -q "^${TESS_LANG}$"; then
            echo "    [!] Idioma '${TESS_LANG}' de Tesseract no disponible. Usando 'eng' como fallback."
            TESS_LANG="eng"
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
        OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${LANG}.wav"
        OUT_MP3="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${LANG}.mp3"
        
        # Saltarse si ya existe en WAV o MP3 para evitar regeneración redundante
        if [ -s "$OUT_WAV" ] || [ -s "$OUT_MP3" ]; then
            echo "    [+] $LANG: Ya existe, saltando."
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
        cat "$FINAL_TXT" | "$PIPER_EXE" --model "$MODEL" --output_file "$OUT_WAV" > /dev/null 2>&1
    done
    echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada correctamente."
    ) &

    # Limit concurrent jobs
    while [ $(jobs -rp | wc -l) -ge $MAX_JOBS ]; do
        sleep 0.5
    done
done

# Wait for all background jobs to finish
wait

# Compilar visor monolítico htm+audio una única vez al finalizar todas las páginas
echo ""
echo "[+] Compilando visor monolítico para ${BOOK_NAME}..."
mkdir -p "$PORTABLE_ROOT/htm+audio"
"$PY_BIN" "$MONOLITHS_DIR/generar_htm_con_audios.py" "$PDF_PATH" "$PORTABLE_ROOT/htm+audio/${BOOK_NAME}.htm" || true

# Limpieza final
rm -rf "$WORKDIR"
echo ""
echo "===================================================="
echo "[!] PROCESO DE PÁGINAS COMPLETADO (ESPAÑOL)"
echo "===================================================="
