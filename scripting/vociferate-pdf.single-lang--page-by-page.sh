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
# --- Selección de motor de traducción ---
if [ "$TARGET_LANG" != "$ORIGIN_LANG" ]; then
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
    if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
        OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.optime.${TARGET_LANG}.wav"
        UNOPT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${TARGET_LANG}.wav"
    else
        OUT_WAV="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${TARGET_LANG}.wav"
        UNOPT_WAV=""
    fi
    OUT_MP3="$OUT_DIR/${BOOK_NAME}.page-${PADDED_PAGE}.${TARGET_LANG}.mp3"
    
    if ([ -s "$OUT_WAV" ] || [ -s "$OUT_MP3" ]) && [ "${FORCE_RENEW_CACHE:-0}" != "1" ]; then
        echo ">>> PAGINA [$PADDED_PAGE / $TOTAL_PAGES] - Ya existe audio para $TARGET_LANG. Saltando."
        exit 0
    fi
    
    # Reutilización inteligente: Si ya existe el audio original sin comprimir y ahora se solicita optimizar
    if [ "${AUDIO_OPTIMIZE:-0}" == "1" ] && [ -n "$UNOPT_WAV" ] && [ -s "$UNOPT_WAV" ] && [ "${FORCE_RENEW_CACHE:-0}" != "1" ]; then
        echo "⚡ PAGINA [$PADDED_PAGE / $TOTAL_PAGES] - Reutilizando audio existente para comprimir..."
        if command -v sox >/dev/null 2>&1; then
            sox "$UNOPT_WAV" -r 16000 -c 1 -b 8 "$OUT_WAV" 2>/dev/null || cp "$UNOPT_WAV" "$OUT_WAV"
        else
            cp "$UNOPT_WAV" "$OUT_WAV"
        fi
        echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] comprimida y optimizada a partir del audio existente."
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
    RAW_PAGE_WAV="$WORKDIR/raw_audio_${PADDED_PAGE}_${TARGET_LANG}.wav"
    if cat "$FINAL_TXT" | "$PIPER_EXE" --model "$MODEL" --output_file "$RAW_PAGE_WAV" > /dev/null 2>&1; then
        if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
            if command -v sox >/dev/null 2>&1; then
                sox "$RAW_PAGE_WAV" -r 16000 -c 1 -b 8 "$OUT_WAV" 2>/dev/null || cp "$RAW_PAGE_WAV" "$OUT_WAV"
                rm -f "$RAW_PAGE_WAV"
            else
                mv "$RAW_PAGE_WAV" "$OUT_WAV"
            fi
            echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada, comprimida y optimizada correctamente."
        else
            mv "$RAW_PAGE_WAV" "$OUT_WAV"
            echo "✔ PÁGINA [$PADDED_PAGE / $TOTAL_PAGES] procesada correctamente."
        fi
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
wav_files=()
if [ "${AUDIO_OPTIMIZE:-0}" == "1" ]; then
    FINAL_MERGED_WAV="$OUT_DIR/${BOOK_NAME}.optime.${TARGET_LANG}.wav"
    for f in "$OUT_DIR"/"${BOOK_NAME}".page-[0-9][0-9][0-9][0-9].optime."${TARGET_LANG}".wav; do
        [ -f "$f" ] && wav_files+=("$f")
    done
else
    FINAL_MERGED_WAV="$OUT_DIR/${BOOK_NAME}.${TARGET_LANG}.wav"
    for f in "$OUT_DIR"/"${BOOK_NAME}".page-[0-9][0-9][0-9][0-9]."${TARGET_LANG}".wav; do
        [ -f "$f" ] && wav_files+=("$f")
    done
fi

echo ""
echo "[+] Uniendo todas las páginas WAV en un solo archivo: $(basename "$FINAL_MERGED_WAV")..."
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

# Partir para WhatsApp si fue solicitado agrupando páginas directamente en MP3 ligero (< 60 MB)
if [ "${WHATSAPP_SPLIT:-0}" == "1" ] && [ ${#wav_files[@]} -gt 0 ]; then
    echo ""
    echo "📱 Agrupando páginas en partes MP3 para WhatsApp (límite: < 60 MB por parte)..."
    WA_TARGET_DIR="$PORTABLE_ROOT/compartir-whatsapp/${BOOK_NAME}"
    mkdir -p "$WA_TARGET_DIR"
    
    # 110 MB de WAV equivalen a ~50-55 MB de MP3 a 64 kbps (~2 horas continuas de lectura)
    max_wav_bytes=$(( 110 * 1024 * 1024 ))
    current_batch=()
    current_size=0
    part_idx=1
    
    for wfile in "${wav_files[@]}"; do
        [ -f "$wfile" ] || continue
        fsize=$(stat -c%s "$wfile" 2>/dev/null || wc -c < "$wfile")
        
        if [ ${#current_batch[@]} -gt 0 ] && [ $(( current_size + fsize )) -gt $max_wav_bytes ]; then
            out_part=$(printf "%s/%s-WhatsApp-Parte_%03d.%s.mp3" "$WA_TARGET_DIR" "$BOOK_NAME" "$part_idx" "$TARGET_LANG")
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
        out_part=$(printf "%s/%s-WhatsApp-Parte_%03d.%s.mp3" "$WA_TARGET_DIR" "$BOOK_NAME" "$part_idx" "$TARGET_LANG")
        echo "   📲 Creando Parte $part_idx (${#current_batch[@]} páginas, convirtiendo a MP3 liviano)..."
        if command -v ffmpeg >/dev/null 2>&1 && command -v sox >/dev/null 2>&1; then
            sox "${current_batch[@]}" -t wav - 2>/dev/null | ffmpeg -y -i - -c:a libmp3lame -b:a 64k -ar 22050 -ac 1 "$out_part" >/dev/null 2>&1 || true
        elif command -v sox >/dev/null 2>&1; then
            sox "${current_batch[@]}" -C 64 "$out_part" 2>/dev/null || true
        fi
        part_size=$(du -h "$out_part" 2>/dev/null | awk '{print $1}' || echo "OK")
        echo "      ✅ Parte $part_idx lista ($part_size)"
    fi
    echo "[!] ✅ Partes MP3 para WhatsApp creadas exitosamente en: $WA_TARGET_DIR"
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

