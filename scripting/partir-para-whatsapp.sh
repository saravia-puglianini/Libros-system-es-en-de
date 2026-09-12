#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PORTABLE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PERSONAL_DIR="$PROJECT_ROOT/personal/htm-pags"
HTM_AUDIO_DIR="$PROJECT_ROOT/htm+audio"
OUT_BASE_DIR="$PROJECT_ROOT/compartir-whatsapp"

echo "===================================================="
echo "📱 Partidor de Audiolibros y Documentos para WhatsApp"
echo "===================================================="
echo ""

# 1. Buscar archivos de audio completos en personal/htm-pags
declare -a available_audio_files=()
declare -a available_audio_labels=()

if [ -d "$PERSONAL_DIR" ]; then
    while IFS= read -r -d '' audio_file; do
        fname=$(basename "$audio_file")
        # Filtrar solo archivos completos (no por página)
        if [[ ! "$fname" =~ \.page-[0-9]{4}\. ]]; then
            size_mb=$(du -h "$audio_file" | awk '{print $1}')
            available_audio_files+=("$audio_file")
            available_audio_labels+=("$fname ($size_mb)")
        fi
    done < <(find "$PERSONAL_DIR" -maxdepth 1 -type f \( -iname "*.wav" -o -iname "*.mp3" -o -iname "*.ogg" -o -iname "*.m4a" \) -print0 | sort -z)
fi

# Si no hay audios completos fusionados, buscar libros que tengan páginas generadas
declare -a available_page_books=()
if [ -d "$PERSONAL_DIR" ]; then
    while IFS= read -r -d '' pfile; do
        pfname=$(basename "$pfile")
        # Extraer prefijo del libro
        book_prefix=$(echo "$pfname" | sed -E 's/\.page-[0-9]{4}.*$//')
        if [[ -n "$book_prefix" && ! " ${available_page_books[*]:-} " =~ " ${book_prefix} " ]]; then
            available_page_books+=("$book_prefix")
        fi
    done < <(find "$PERSONAL_DIR" -maxdepth 1 -type f -name "*.page-*.wav" -print0 | sort -z)
fi

total_audios=${#available_audio_files[@]}
total_page_books=${#available_page_books[@]}

if [ "$total_audios" -eq 0 ] && [ "$total_page_books" -eq 0 ]; then
    echo "⚠️ No se encontraron audios generados en: $PERSONAL_DIR"
    echo "Por favor genere primero el audio del libro antes de partirlo para WhatsApp."
    exit 1
fi

echo "🔎 Audios y libros disponibles para partir:"
idx=0
for (( i=0; i<total_audios; i++ )); do
    echo "  [$idx] Audio completo: ${available_audio_labels[$i]}"
    idx=$((idx + 1))
done

for (( i=0; i<total_page_books; i++ )); do
    # Contar cuántas páginas tiene
    p_count=$(find "$PERSONAL_DIR" -maxdepth 1 -name "${available_page_books[$i]}.page-*.wav" | wc -l)
    echo "  [$idx] Colección de páginas ($p_count págs): ${available_page_books[$i]}"
    idx=$((idx + 1))
done

echo ""
selected_idx=0
if [ -t 0 ]; then
    while true; do
        read -r -p "Seleccione el número a partir [0-$((idx - 1))] (Por defecto: 0): " input_sel || true
        if [ -z "$input_sel" ]; then
            selected_idx=0
            break
        elif [[ "$input_sel" =~ ^[0-9]+$ ]] && [ "$input_sel" -ge 0 ] && [ "$input_sel" -lt "$idx" ]; then
            selected_idx="$input_sel"
            break
        else
            echo "❌ Opción inválida. Intente de nuevo."
        fi
    done
fi

SELECTED_FILE=""
SELECTED_BOOK_NAME=""

if [ "$selected_idx" -lt "$total_audios" ]; then
    SELECTED_FILE="${available_audio_files[$selected_idx]}"
    base_file_name=$(basename "$SELECTED_FILE")
    SELECTED_BOOK_NAME="${base_file_name%.*}"
else
    page_book_idx=$((selected_idx - total_audios))
    SELECTED_BOOK_NAME="${available_page_books[$page_book_idx]}"
    # Si seleccionó una colección de páginas, las unimos primero temporalmente o directamente
    echo ""
    echo "[*] Generando unión temporal de páginas para '${SELECTED_BOOK_NAME}'..."
    TMP_MERGE="/tmp/${SELECTED_BOOK_NAME}.merged.wav"
    
    # Recolectar archivos de páginas en orden
    mapfile -t page_files < <(find "$PERSONAL_DIR" -maxdepth 1 -name "${SELECTED_BOOK_NAME}.page-*.wav" | sort -V)
    if [ ${#page_files[@]} -gt 0 ]; then
        if command -v sox >/dev/null 2>&1; then
            sox "${page_files[@]}" "$TMP_MERGE"
            SELECTED_FILE="$TMP_MERGE"
        elif command -v ffmpeg >/dev/null 2>&1; then
            concat_list=$(mktemp)
            for pf in "${page_files[@]}"; do
                echo "file '$pf'" >> "$concat_list"
            done
            ffmpeg -y -f concat -safe 0 -i "$concat_list" -c copy "$TMP_MERGE" >/dev/null 2>&1
            rm -f "$concat_list"
            SELECTED_FILE="$TMP_MERGE"
        fi
    fi
fi

if [ -z "$SELECTED_FILE" ] || [ ! -f "$SELECTED_FILE" ]; then
    echo "❌ Error al preparar el archivo de audio."
    exit 1
fi

echo ""
echo "📱 Elija el formato de salida para compartir por WhatsApp:"
echo "[0] MP3 Optimizado para WhatsApp (Recomendado: audio ultraligero y nítido, compatible 100% con móviles)"
echo "[1] WAV Partido (Sin pérdida de compresión de audio)"
echo "[2] M4A / AAC (Alta calidad moderna para WhatsApp)"
echo ""

format_choice="0"
if [ -t 0 ]; then
    while true; do
        read -r -p "Seleccione formato [0/1/2] (Por defecto: 0): " input_fmt || true
        if [[ "$input_fmt" =~ ^[0-2]$ ]]; then
            format_choice="$input_fmt"
            break
        elif [ -z "$input_fmt" ]; then
            format_choice="0"
            break
        else
            echo "❌ Opción inválida."
        fi
    done
fi

echo ""
echo "📏 Seleccione el tamaño máximo por parte (Límite WhatsApp):"
echo "[0] 60 MB (Recomendado: límite seguro para cualquier versión de WhatsApp móvil y web)"
echo "[1] 30 MB (Ideal para conexiones lentas o datos móviles limitados)"
echo "[2] 95 MB (Máximo permitido por WhatsApp para archivos como documento)"
echo ""

size_choice="0"
MAX_MB=60
if [ -t 0 ]; then
    while true; do
        read -r -p "Seleccione límite [0/1/2] (Por defecto: 0): " input_sz || true
        if [[ "$input_sz" == "1" ]]; then
            MAX_MB=30
            break
        elif [[ "$input_sz" == "2" ]]; then
            MAX_MB=95
            break
        elif [[ "$input_sz" == "0" || -z "$input_sz" ]]; then
            MAX_MB=60
            break
        else
            echo "❌ Opción inválida."
        fi
    done
fi

# Crear directorio de salida limpio
CLEAN_NAME=$(echo "$SELECTED_BOOK_NAME" | sed -E 's/\.(es|en|de)$//' | sed 's/\.optime//')
TARGET_OUTPUT_DIR="$OUT_BASE_DIR/$CLEAN_NAME"
mkdir -p "$TARGET_OUTPUT_DIR"

echo ""
echo "===================================================="
echo "[*] Procesando y dividiendo audio para WhatsApp..."
echo "[*] Libro: $CLEAN_NAME"
echo "[*] Tamaño máx por parte: ${MAX_MB} MB"
echo "[*] Carpeta de destino: $TARGET_OUTPUT_DIR"
echo "===================================================="

# Comprobar si tenemos las páginas individuales para hacer una agrupación directa y ligera
mapfile -t individual_pages < <(find "$PERSONAL_DIR" -maxdepth 1 -name "${SELECTED_BOOK_NAME}.page-*.wav" | sort -V)

if [ ${#individual_pages[@]} -gt 0 ]; then
    echo "[*] Agrupando ${#individual_pages[@]} páginas directamente en MP3 ligero para WhatsApp (máx ${MAX_MB} MB)..."
    max_wav_bytes=$(( MAX_MB * 2 * 1024 * 1024 ))
    current_batch=()
    current_size=0
    part_idx=1
    
    for wfile in "${individual_pages[@]}"; do
        [ -f "$wfile" ] || continue
        fsize=$(stat -c%s "$wfile" 2>/dev/null || wc -c < "$wfile")
        
        if [ ${#current_batch[@]} -gt 0 ] && [ $(( current_size + fsize )) -gt $max_wav_bytes ]; then
            out_part=$(printf "%s/%s-WhatsApp-Parte_%03d.mp3" "$TARGET_OUTPUT_DIR" "$CLEAN_NAME" "$part_idx")
            echo "   📲 Generando Parte $part_idx (${#current_batch[@]} páginas, convirtiendo a MP3 liviano)..."
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
        out_part=$(printf "%s/%s-WhatsApp-Parte_%03d.mp3" "$TARGET_OUTPUT_DIR" "$CLEAN_NAME" "$part_idx")
        echo "   📲 Generando Parte $part_idx (${#current_batch[@]} páginas, convirtiendo a MP3 liviano)..."
        if command -v ffmpeg >/dev/null 2>&1 && command -v sox >/dev/null 2>&1; then
            sox "${current_batch[@]}" -t wav - 2>/dev/null | ffmpeg -y -i - -c:a libmp3lame -b:a 64k -ar 22050 -ac 1 "$out_part" >/dev/null 2>&1 || true
        elif command -v sox >/dev/null 2>&1; then
            sox "${current_batch[@]}" -C 64 "$out_part" 2>/dev/null || true
        fi
        part_size=$(du -h "$out_part" 2>/dev/null | awk '{print $1}' || echo "OK")
        echo "      ✅ Parte $part_idx lista ($part_size)"
    fi
    EXT="mp3"
else
    # Si solo existe el archivo único consolidado
    TOTAL_DURATION=0
    if command -v ffprobe >/dev/null 2>&1; then
        TOTAL_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SELECTED_FILE" | awk '{print int($1)}')
    elif command -v soxi >/dev/null 2>&1; then
        TOTAL_DURATION=$(soxi -D "$SELECTED_FILE" | awk '{print int($1)}')
    fi

    if [ -z "$TOTAL_DURATION" ] || [ "$TOTAL_DURATION" -le 0 ]; then
        TOTAL_DURATION=3600
    fi

    EXT="wav"
    CODEC_ARGS=("-c:a" "pcm_s16le" "-ar" "16000" "-ac" "1")
    BITRATE_KBITS=256

    BYTES_PER_SEC=$(( (BITRATE_KBITS * 1000) / 8 ))
    TARGET_BYTES=$(( MAX_MB * 1024 * 1024 * 95 / 100 ))
    SEGMENT_SECONDS=$(( TARGET_BYTES / BYTES_PER_SEC ))

    if [ "$SEGMENT_SECONDS" -lt 60 ]; then
        SEGMENT_SECONDS=60
    fi

    echo "[*] Dividiendo archivo consolidado en segmentos de aprox. $((SEGMENT_SECONDS / 60)) minutos..."
    ffmpeg -y -i "$SELECTED_FILE" \
        "${CODEC_ARGS[@]}" \
        -f segment \
        -segment_time "$SEGMENT_SECONDS" \
        -reset_timestamps 1 \
        "$TARGET_OUTPUT_DIR/${CLEAN_NAME}-WhatsApp-Parte_%03d.${EXT}"
fi

echo ""
echo "===================================================="
echo "✅ ¡PARTES PARA WHATSAPP CREADAS CON ÉXITO!"
echo "===================================================="
echo "📁 Archivos listos en: $TARGET_OUTPUT_DIR"
echo ""

part_num=1
for part in "$TARGET_OUTPUT_DIR"/*."$EXT"; do
    if [ -f "$part" ]; then
        psize=$(du -h "$part" | awk '{print $1}')
        pname=$(basename "$part")
        echo "   📲 [Parte $part_num] $pname  ($psize) -> Compatible WhatsApp"
        part_num=$((part_num + 1))
    fi
done

echo ""
echo "💡 Instrucciones para compartir:"
echo "   1. Abre WhatsApp Web o la app de WhatsApp en tu teléfono/PC."
echo "   2. Arrastra o adjunta los archivos de la carpeta '$TARGET_OUTPUT_DIR'."
echo "   3. ¡Se reproducirán al instante en el chat de WhatsApp!"
echo "===================================================="
