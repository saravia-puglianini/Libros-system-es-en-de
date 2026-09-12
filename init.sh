#!/usr/bin/env bash

set -Eeuo pipefail

DEBUG=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python3.12 >/dev/null 2>&1; then export PY_BIN=python3.12
elif command -v python3.11 >/dev/null 2>&1; then export PY_BIN=python3.11
elif command -v python3.10 >/dev/null 2>&1; then export PY_BIN=python3.10
elif command -v python3.9 >/dev/null 2>&1; then export PY_BIN=python3.9
elif command -v python3.8 >/dev/null 2>&1; then export PY_BIN=python3.8
else export PY_BIN=python3; fi

# =========================================================
# AUTO-REPARAR RUTAS ABSOLUTAS EN EL ESPACIO DE TRABAJO
# =========================================================
echo "⚙️  Auto-reparando rutas absolutas para esta copia del proyecto..."
"$PY_BIN" "$SCRIPT_DIR/scripting/patch_workspace_paths.py" "$SCRIPT_DIR"

# =========================================================
# MENÚ DE DISTRO
# =========================================================
echo "Que distro corre?"
echo ""
echo "[0] No lo se (Auto-detectar)"
echo "[1] portable-bin-rocky-linux-8-PATH"
echo "[2] portable-bin-gentoo-2026-PATH"
echo ""

distro_selection="0"
read -r -p "tipee [0/1/2] y enter: " input_distro || true
if [[ "$input_distro" == "1" ]]; then
    distro_selection="1"
elif [[ "$input_distro" == "2" ]]; then
    distro_selection="2"
fi

if [[ "$distro_selection" == "1" ]]; then
    SELECTED_PORTABLE_DIR="portable-bin-for-rocky-linux-8-PATH"
elif [[ "$distro_selection" == "2" ]]; then
    SELECTED_PORTABLE_DIR="portable-bin-for-gentoo-2026-PATH"
else
    echo "🔎 Auto-detectando entorno compatible..."
    if bash "$SCRIPT_DIR/init-validate-all-portable-binaries.sh" "portable-bin-for-gentoo-2026-PATH" > /dev/null 2>&1; then
        echo "✅ Gentoo-2026-PATH parece funcionar bien. Seleccionado."
        SELECTED_PORTABLE_DIR="portable-bin-for-gentoo-2026-PATH"
    elif rocky_output=$(bash "$SCRIPT_DIR/init-validate-all-portable-binaries.sh" "portable-bin-for-rocky-linux-8-PATH" 2>&1); then
        echo "✅ Rocky-Linux-8-PATH parece funcionar bien. Seleccionado."
        SELECTED_PORTABLE_DIR="portable-bin-for-rocky-linux-8-PATH"
    else
        echo "❌ Ningún entorno portable funciona perfectamente en su totalidad. Usaremos Rocky por defecto, revisa los fallos con ./init-validate-all-portable-binaries.sh"
        echo "$rocky_output" | grep "❌ \[ERROR\]" | while read -r _ _ path _; do
            bin_name=$(basename "$path")
            echo "falta $bin_name"
        done
        SELECTED_PORTABLE_DIR="portable-bin-for-rocky-linux-8-PATH"
    fi
fi

# =========================================================
# RECREAR ENLACES SIMBÓLICOS DINÁMICOS
# =========================================================
FOLDER_NAME=$(basename "$SCRIPT_DIR")
SUFFIX="${FOLDER_NAME#Libros-}"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Determinar el directorio de PDFs (ej: pdfs-aurelia o L-aurelia)
if [ -d "$PARENT_DIR/pdfs-$SUFFIX" ]; then
    PDFS_TARGET="$PARENT_DIR/pdfs-$SUFFIX"
elif [ -d "$PARENT_DIR/L-$SUFFIX" ]; then
    PDFS_TARGET="$PARENT_DIR/L-$SUFFIX"
elif [ -d "$PARENT_DIR/$SUFFIX" ]; then
    PDFS_TARGET="$PARENT_DIR/$SUFFIX"
else
    PDFS_TARGET="$PARENT_DIR/pdfs-$SUFFIX"
fi

# 2. Determinar directorios de salida procesados (ej: Processed_htms-superacion-en-el-trabajo o Processed_htms-L-belen)
if [ -d "$PARENT_DIR/Processed_htms-$SUFFIX" ]; then
    HTM_TARGET="$PARENT_DIR/Processed_htms-$SUFFIX"
    HTM_AUDIO_TARGET="$PARENT_DIR/Processed_htm_audios-$SUFFIX"
    PERSONAL_TARGET="$PARENT_DIR/Processed_WAV_files-$SUFFIX"
elif [ -d "$PARENT_DIR/Processed_htms-L-$SUFFIX" ]; then
    HTM_TARGET="$PARENT_DIR/Processed_htms-L-$SUFFIX"
    HTM_AUDIO_TARGET="$PARENT_DIR/Processed_htm_audios-L-$SUFFIX"
    PERSONAL_TARGET="$PARENT_DIR/Processed_WAV_files-L-$SUFFIX"
else
    # Por defecto usamos el nombre limpio
    HTM_TARGET="$PARENT_DIR/Processed_htms-$SUFFIX"
    HTM_AUDIO_TARGET="$PARENT_DIR/Processed_htm_audios-$SUFFIX"
    PERSONAL_TARGET="$PARENT_DIR/Processed_WAV_files-$SUFFIX"
fi

# Asegurar que existan todos los directorios destino
mkdir -p "$PDFS_TARGET" "$HTM_TARGET" "$HTM_AUDIO_TARGET" "$PERSONAL_TARGET"

# Eliminar enlaces antiguos si existen
rm -f "$SCRIPT_DIR/htm" "$SCRIPT_DIR/htm+audio" "$SCRIPT_DIR/personal" "$SCRIPT_DIR/pdfs"

# Crear enlaces simbólicos
ln -sf "$HTM_TARGET" "$SCRIPT_DIR/htm"
ln -sf "$HTM_AUDIO_TARGET" "$SCRIPT_DIR/htm+audio"
ln -sf "$PERSONAL_TARGET" "$SCRIPT_DIR/personal"
ln -sf "$PDFS_TARGET" "$SCRIPT_DIR/pdfs"

# Activar modo portable
if [ -d "$SCRIPT_DIR/$SELECTED_PORTABLE_DIR" ]; then
    export PORTABLE_MODE=1
    export PORTABLE_ROOT="$SCRIPT_DIR"
    export SELECTED_PORTABLE_DIR="$SELECTED_PORTABLE_DIR"
    
    # Crear un directorio temporal en /tmp para evadir bloqueos de ejecución (noexec) en el USB
    TEMP_BIN_DIR=$(mktemp -d -t pdf-portable-bin.XXXXXX)
    
    # Registrar trampa de limpieza para borrar el directorio temporal al salir
    trap 'rm -rf "$TEMP_BIN_DIR"' EXIT INT TERM HUP
    
    # Copiar los binarios que NO estén instalados en el sistema anfitrión
    for binary_path in "$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/bin/"*; do
        [ -e "$binary_path" ] || continue
        name=$(basename "$binary_path")
        if [[ "$name" != "python3" ]] && command -v "$name" >/dev/null 2>&1; then
            echo "    [+] Usando versión nativa del sistema: $name"
        else
            echo "    [+] Copiando versión portable al espejo: $name"
            cp -rf "$binary_path" "$TEMP_BIN_DIR/"
        fi
    done
    chmod +x "$TEMP_BIN_DIR"/* 2>/dev/null || true
    
    # Configurar el PATH apuntando al directorio temporal con permisos de ejecución
    export PATH="$TEMP_BIN_DIR:$PATH"
    export LD_LIBRARY_PATH="/usr/lib64:$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/lib64:$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/lib:${LD_LIBRARY_PATH:-}"
    export PYTHONPATH="$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/python/site-packages:${PYTHONPATH:-}"
    export PERL5LIB="$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/perl:${PERL5LIB:-}"
    
    if [ -d "$PORTABLE_ROOT/portable-bin-for-gentoo-2026-PATH/share/tessdata" ]; then
        export TESSDATA_PREFIX="$PORTABLE_ROOT/portable-bin-for-gentoo-2026-PATH/share/tessdata"
    else
        export TESSDATA_PREFIX="$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/share/tessdata"
    fi

    export APERTIUM_PATH="$TEMP_BIN_DIR"
    export APERTIUM_DATADIR="$PORTABLE_ROOT/$SELECTED_PORTABLE_DIR/share/apertium"
fi

# =========================================================
# CONFIG
# =========================================================

DIR="${1:-pdfs}"
# Resolve to real absolute path to handle symlinks
ABS_DIR=$(readlink -f "$DIR")

OUT_HTML="pdfs.htm"
THUMBS_DIR="thumbnails"
HTM_DIR="htm"
HTM_AUDIO_DIR="htm+audio"

echo
echo "========================================"
echo "📚 Biblioteca PDF"
echo "========================================"
echo "[+] Directorio objetivo:"
echo "    $DIR"

# =========================================================
# DEPENDENCIAS
# =========================================================

deps=(
    exiftool
    qpdf
    sha256sum
    pdftoppm
    pdfinfo
    file
)

echo
echo "🔎 Verificando dependencias..."

for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Falta dependencia: $cmd"
        exit 1
    fi
done

echo "✅ Dependencias OK"

# =========================================================
# FUNCTIONS
# =========================================================
# Retrieve page count for a PDF using available tools.
# Tries pdfinfo first; if it fails (e.g., GLIBC mismatch), falls back to qpdf.
get_page_count() {
    local pdf_path="$1"
    # Prefer native system pdfinfo if available to avoid GLIBC mismatch
    if command -v /usr/bin/pdfinfo >/dev/null 2>&1; then
        pdfinfo_cmd="/usr/bin/pdfinfo"
    else
        pdfinfo_cmd="pdfinfo"
    fi
    set +e
    set +o pipefail
    local pages=$($pdfinfo_cmd "$pdf_path" 2>/dev/null | awk '/Pages:/ {print $2}' || true)
    set -o pipefail
    set -eo pipefail
    set -e
    if [[ -n "$pages" && "$pages" =~ ^[0-9]+$ ]]; then
        echo "$pages"
        return
    fi
    # Fallback to qpdf if available.
    if command -v qpdf >/dev/null 2>&1; then
        set +e
        set +o pipefail
        pages=$(qpdf --show-npages "$pdf_path" 2>/dev/null || true)
        set -o pipefail
        set -e
        if [[ -n "$pages" && "$pages" =~ ^[0-9]+$ ]]; then
            echo "$pages"
            return
        fi
    fi
    # As last resort, return 0.
    echo "0"
}


# =========================================================
# OPTIMIZAR PDFs PESADOS
# =========================================================
optimize_heavy_pdfs() {
    if ! command -v gs >/dev/null 2>&1; then
        echo "⚠️  Ghostscript (gs) no está instalado. Se omitirá la optimización de tamaño."
        return
    fi

    # Buscar PDFs de más de 5MB
    local found_heavy=false
    while IFS= read -r -d '' pdf; do
        # Evitar archivos temporales o directorios .git
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        local size_mb=$(du -m "$pdf" | awk '{print $1}')
        if [ "$size_mb" -ge 5 ]; then
            found_heavy=true
            break
        fi
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)

    if [ "$found_heavy" = false ]; then
        return
    fi

    echo ""
    echo "⚖️  Se detectaron PDFs de más de 5MB en su biblioteca."
    echo "¿Desea optimizar el tamaño de sus PDFs antes de continuar? (Recomendado para PDFs editados con GIMP)"
    echo "[0] No optimizar (continuar normal)"
    echo "[1] Calidad Ebook (150 DPI - Recomendado, mantiene buena calidad para OCR)"
    echo "[2] Calidad Pantalla (72 DPI - Tamaño mínimo, compresión máxima)"
    echo ""
    
    local opt_choice="0"
    local input_opt=""
    read -r -p "Seleccione opción [0/1/2] (Por defecto: 0): " input_opt || true
    if [[ "$input_opt" == "1" ]]; then
        opt_choice="ebook"
    elif [[ "$input_opt" == "2" ]]; then
        opt_choice="screen"
    fi

    if [ "$opt_choice" = "0" ]; then
        echo "⏭️  Omitiendo optimización."
        return
    fi

    echo "⚙️  Optimizando PDFs con calidad: $opt_choice..."
    while IFS= read -r -d '' pdf; do
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        local size_mb=$(du -m "$pdf" | awk '{print $1}')
        if [ "$size_mb" -lt 5 ]; then
            continue
        fi
        
        local filename=$(basename "$pdf")
        echo "   📉 Optimizando $filename ($size_mb MB)..."
        
        local tmp_opt=$(mktemp --suffix=.pdf)
        if gs -sDEVICE=pdfwrite \
              -dCompatibilityLevel=1.4 \
              -dPDFSETTINGS="/$opt_choice" \
              -dNOPAUSE -dQUIET -dBATCH \
              -sOutputFile="$tmp_opt" \
              "$pdf"; then
              
            local new_size_mb=$(du -m "$tmp_opt" | awk '{print $1}')
            if [ "$new_size_mb" -lt "$size_mb" ]; then
                mv -f "$tmp_opt" "$pdf"
                echo "   ✅ Reducido a $new_size_mb MB"
            else
                rm -f "$tmp_opt"
                echo "   ℹ️  No se pudo reducir más el tamaño."
            fi
        else
            rm -f "$tmp_opt"
            echo "   ❌ Falló la optimización para $filename"
        fi
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)
}

optimize_heavy_pdfs

# =========================================================
# MENÚ DE CACHÉ DE PROCESAMIENTO
# =========================================================

echo ""
echo "Elija una opción de procesamiento:"
echo "[0] reutilizar cache"
echo "[1] renovar cache"
echo ""

cache_selection="0"
read -r -p "Seleccione opción [0/1] (Por defecto: 0): " input_cache || true
if [[ "$input_cache" == "1" ]]; then
    cache_selection="1"
fi

if [[ "$cache_selection" == "1" ]]; then
    echo "🔄 Renovando caché: se re-procesarán y regenerarán archivos."
    export FORCE_RENEW_CACHE="1"
else
    echo "⚡ Reutilizando caché: se conservarán archivos previamente generados."
    export FORCE_RENEW_CACHE="0"
fi

# =========================================================
# MENÚ INTERACTIVO COMPATIBLE CON EMACS *SHELL*
# =========================================================

echo ""
echo "📚 Seleccione el modo de generación:"
echo "[0] Generar .htm normales (rápido, sin audio)"
echo "[1] Generar ARDUAMENTE con audios paginados multilingües (Piper + Traducción)"
echo "[2] Generar ARDUAMENTE con audios para TODOS los libros (Batch automático)"
echo "[3] Generar ARDUAMENTE un audio a partir de un pdf en un idioma hacia el mismo u otro"
echo "[4] Generar ARDUAMENTE un audio a partir de TODOS los pdfs en un idioma hacia el mismo u otro (Batch automático)"
echo ""

mode_selection="0"
read -r -p "Seleccione opción [0/1/2/3/4] (Por defecto: 0): " input_selection || true
if [[ "$input_selection" == "1" ]]; then
    mode_selection="1"
elif [[ "$input_selection" == "2" ]]; then
    mode_selection="2"
elif [[ "$input_selection" == "3" ]]; then
    mode_selection="3"
elif [[ "$input_selection" == "4" ]]; then
    mode_selection="4"
fi

if [[ "$mode_selection" == "1" ]]; then
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[DEBUG] mode_selection = $mode_selection"
        set -x
    fi
    trap 'echo "[ERROR] Falló en la línea $LINENO con código de salida $?"' ERR
    echo ""
    echo "🔎 Escaneando libros pendientes de conversión..."
    
    declare -a unconverted_pdfs=()
    declare -a unconverted_names=()
    declare -a unconverted_pages=()
    
    temp_unconverted=$(mktemp)
    [ "${DEBUG:-0}" = "1" ] && echo "[DEBUG] temp_unconverted = $temp_unconverted"
    
    # Encontrar todos los PDFs en el directorio objetivo
    while IFS= read -r -d '' pdf; do
        filename=$(basename "$pdf")
        # Ignorar archivos temporales o de git si los hubiera
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        
        # Extraer el idioma y nombre limpio del libro
        orig_lang=$(echo "$filename" | rev | cut -d. -f2 | rev)
        if [[ "$orig_lang" =~ ^(en|es|de)$ ]]; then
            clean_book_name=$(echo "$filename" | sed "s/\.${orig_lang}\.pdf$//")
        else
            clean_book_name="${filename%.pdf}"
        fi
        
        htm_audio_file="$HTM_AUDIO_DIR/${clean_book_name}.htm"
        if [[ "${FORCE_RENEW_CACHE:-0}" == "1" || ! -f "$htm_audio_file" ]]; then
            # Obtener número de páginas
            pages=$(get_page_count "$pdf")
            pages=${pages:-0}
            
            # Guardar en archivo temporal para ordenar
            printf '%d|%s|%s\n' "$pages" "$pdf" "$filename" >> "$temp_unconverted"
        fi
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)
    
    # Leer ordenando ascendentemente por número de páginas (menor tiempo a más)
    if [[ -f "$temp_unconverted" ]]; then
        while IFS='|' read -r pages pdf filename; do
            if [[ -n "$pdf" ]]; then
                unconverted_pages+=("$pages")
                unconverted_pdfs+=("$pdf")
                unconverted_names+=("$filename")
            fi
        done < <(sort -t'|' -k1,1n "$temp_unconverted")
        rm -f "$temp_unconverted"
    fi
    
    total_unconverted=${#unconverted_pdfs[@]}
    
    if [[ "$total_unconverted" -eq 0 ]]; then
        echo "🎉 ¡Todos los libros ya tienen su versión HTML con audio! No hay pendientes."
        exit 0
    fi
    
    echo "📚 Libros que aún no han sido convertidos:"
    for (( i=0; i<total_unconverted; i++ )); do
        pages="${unconverted_pages[$i]}"
        
        # Calcular tiempo estimado (50 segundos por página)
        total_seconds=$(( pages * 50 ))
        total_minutes=$(( total_seconds / 60 ))
        
        if [[ "$total_minutes" -ge 60 ]]; then
            hours=$(( total_minutes / 60 ))
            mins=$(( total_minutes % 60 ))
            if [[ "$mins" -gt 0 ]]; then
                time_est="${hours}h y ${mins}min"
            else
                time_est="${hours}h"
            fi
        else
            # Si da 0 minutos, poner al menos 1min
            if [[ "$total_minutes" -eq 0 && "$pages" -gt 0 ]]; then
                time_est="1min"
            else
                time_est="${total_minutes}min"
            fi
        fi
        
        echo "[$i] ${unconverted_names[$i]} - $pages páginas (Tiempo estimado $time_est)"
    done
    echo ""
    
    selected_index=""
    # If stdin is not a terminal (e.g., input piped), auto-select first book
    if [ -t 0 ]; then
        while true; do
            read -r -p "Seleccione el número del libro a procesar [0-$((total_unconverted - 1))]: " selection_val || true
            if [[ -n "$selection_val" && "$selection_val" =~ ^[0-9]+$ && "$selection_val" -ge 0 && "$selection_val" -lt "$total_unconverted" ]]; then
                selected_index="$selection_val"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        # Default to first unconverted book when input is piped
        selected_index=0
        echo "[Auto] Seleccionado libro 0 (primer libro) debido a entrada no interactiva"
    fi
    
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
    
    selected_pdf="${unconverted_pdfs[$selected_index]}"
    selected_filename="${unconverted_names[$selected_index]}"
    
    # Determinar idioma de origen y nombre limpio
    selected_lang=$(echo "$selected_filename" | rev | cut -d. -f2 | rev)
    if [[ "$selected_lang" =~ ^(en|es|de)$ ]]; then
        clean_book_name=$(echo "$selected_filename" | sed "s/\.${selected_lang}\.pdf$//")
    else
        clean_book_name="${selected_filename%.pdf}"
        selected_lang="en"
    fi
    
    echo ""
    echo "===================================================="
    echo "🎙️ PASO A: Generando audios multilingües página por página..."
    echo "Libro seleccionado: $clean_book_name"
    echo "Idioma origen detectado: $selected_lang"
    echo "===================================================="
    
    case "$selected_lang" in
        en)
            bash ./scripting/vociferate-pdf.from.en.to.es.and.de--page-by-page.sh "$selected_pdf"
            ;;
        es)
            bash ./scripting/vociferate-pdf.from.es.to.en.and.de--page-by-page.sh "$selected_pdf"
            ;;
        de)
            bash ./scripting/vociferate-pdf.from.de.to.en.and.es--page-by-page.sh "$selected_pdf"
            ;;
        *)
            echo "⚠️ Idioma no soportado para generación de audios ($selected_lang). Usando script en inglés por defecto."
            bash ./scripting/vociferate-pdf.from.en.to.es.and.de--page-by-page.sh "$selected_pdf"
            ;;
    esac
    
    echo ""
    echo "===================================================="
    echo "📱 PASO B: Compilando visor monolítico con audios inyectados (Base64)..."
    echo "===================================================="
    mkdir -p "$HTM_AUDIO_DIR"
    "$PY_BIN" "$SCRIPT_DIR/scripting/generar_htm_con_audios.py" "$selected_pdf" "$HTM_AUDIO_DIR/${clean_book_name}.htm"
    
    echo ""
    echo "🎉 ¡Conversión ardua completada con éxito!"
    unset TRANSLATOR_SERVICE
    unset AUDIO_OPTIMIZE
    echo "Continuando con el procesamiento general de la biblioteca..."
    echo ""
fi

if [[ "$mode_selection" == "2" ]]; then
    echo ""
    read -r -p "Desea iterar todos los pdfs? (si/no) [Por defecto: no]: " iterar_confirm || true
    iterar_confirm=$(echo "$iterar_confirm" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    
    if [[ "$iterar_confirm" != "si" && "$iterar_confirm" != "s" ]]; then
        echo "❌ Operación cancelada por el usuario."
        exit 0
    fi
    
    echo ""
    echo "cuantas paginas por pdf?"
    echo "[0] Todas"
    echo "[5-15] del 5 al 15"
    echo "[10] del 1 hasta el 10"
    echo ""
    read -r -p "Seleccione opción [Por defecto: 0]: " pages_input || true
    pages_input=$(echo "$pages_input" | tr -d '[:space:]')
    if [[ -z "$pages_input" ]]; then
        pages_input="0"
    fi
    
    echo ""
    echo "qué idiomas desea iterar en todos los pdfs para vociferar:"
    echo "[0] Spanish"
    echo "[1] English"
    echo "[2] German"
    echo "[3] Spanish and English"
    echo "[4] Spanish and German"
    echo "[5] English and German"
    echo "[6] Spanish, English and German"
    echo ""
    read -r -p "Seleccione opción [0-6] (Por defecto: 0): " langs_input || true
    langs_input=$(echo "$langs_input" | tr -d '[:space:]')
    if [[ -z "$langs_input" ]]; then
        langs_input="0"
    fi
    
    echo ""
    echo "🔎 Escaneando y organizando todos los PDFs en la biblioteca..."
    
    # Encontrar todos los PDFs (using ABS_DIR)
    declare -a all_pdfs=()
    declare -a all_filenames=()
    declare -a all_pages=()
    
    temp_all=$(mktemp)
    
    # Encontrar todos los PDFs en el directorio objetivo
    while IFS= read -r -d '' pdf; do
        filename=$(basename "$pdf")
        # Ignorar archivos temporales
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        
        pages=$(get_page_count "$pdf")
        pages=${pages:-0}
        
        printf '%d|%s|%s\n' "$pages" "$pdf" "$filename" >> "$temp_all"
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)
    
    # Leer ordenando ascendentemente por número de páginas
    if [[ -f "$temp_all" ]]; then
        while IFS='|' read -r pages pdf filename; do
            if [[ -n "$pdf" ]]; then
                all_pages+=("$pages")
                all_pdfs+=("$pdf")
                all_filenames+=("$filename")
            fi
        done < <(sort -t'|' -k1,1n "$temp_all")
        rm -f "$temp_all"
    fi
    
    total_pdfs=${#all_pdfs[@]}
    
    if [[ "$total_pdfs" -eq 0 ]]; then
        echo "❌ No se encontraron archivos PDF en el directorio especificado."
        exit 1
    fi
    
    echo "📚 Se encontraron $total_pdfs PDFs. Iniciando procesamiento en lote..."
    echo "===================================================="
    
    # Exportar variables de entorno para que los scripts hijos las lean y bypassen prompts
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
    
    export OVERRIDE_RANGE="$pages_input"
    export OVERRIDE_LANG="$langs_input"
    
    for (( i=0; i<total_pdfs; i++ )); do
        pdf_path="${all_pdfs[$i]}"
        pdf_name="${all_filenames[$i]}"
        pdf_page_count="${all_pages[$i]}"
        
        echo ""
        echo "----------------------------------------------------"
        echo "[Batch $((i+1)) / $total_pdfs] Procesando: $pdf_name ($pdf_page_count páginas)"
        echo "----------------------------------------------------"
        
        # Determinar idioma de origen
        pdf_lang=$(echo "$pdf_name" | rev | cut -d. -f2 | rev)
        if [[ ! "$pdf_lang" =~ ^(en|es|de)$ ]]; then
            pdf_lang="en" # default
        fi
        
        case "$pdf_lang" in
            en)
                bash ./scripting/vociferate-pdf.from.en.to.es.and.de--page-by-page.sh "$pdf_path"
                ;;
            es)
                bash ./scripting/vociferate-pdf.from.es.to.en.and.de--page-by-page.sh "$pdf_path"
                ;;
            de)
                bash ./scripting/vociferate-pdf.from.de.to.en.and.es--page-by-page.sh "$pdf_path"
                ;;
            *)
                bash ./scripting/vociferate-pdf.from.en.to.es.and.de--page-by-page.sh "$pdf_path"
                ;;
        esac
        
    done
    
    # Limpiar variables de entorno
    unset OVERRIDE_RANGE
    unset OVERRIDE_LANG
    unset TRANSLATOR_SERVICE
    
    echo ""
    echo "===================================================="
    echo "🎉 ¡Conversión en lote automatizada completada con éxito!"
    echo "===================================================="
    echo ""
fi

if [[ "$mode_selection" == "3" ]]; then
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[DEBUG] mode_selection = $mode_selection"
        set -x
    fi
    trap 'echo "[ERROR] Falló en la línea $LINENO con código de salida $?"' ERR
    echo ""
    echo "🔎 Escaneando libros disponibles..."
    
    declare -a all_pdfs=()
    declare -a all_names=()
    declare -a all_pages=()
    
    temp_pdfs=$(mktemp)
    while IFS= read -r -d '' pdf; do
        filename=$(basename "$pdf")
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        pages=$(get_page_count "$pdf")
        pages=${pages:-0}
        printf '%d|%s|%s\n' "$pages" "$pdf" "$filename" >> "$temp_pdfs"
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)
    
    if [[ -f "$temp_pdfs" ]]; then
        while IFS='|' read -r pages pdf filename; do
            if [[ -n "$pdf" ]]; then
                all_pages+=("$pages")
                all_pdfs+=("$pdf")
                all_names+=("$filename")
            fi
        done < <(sort -t'|' -k1,1n "$temp_pdfs")
        rm -f "$temp_pdfs"
    fi
    
    total_pdfs=${#all_pdfs[@]}
    if [[ "$total_pdfs" -eq 0 ]]; then
        echo "❌ No hay libros PDF en el directorio pdfs."
        exit 1
    fi
    
    echo "📚 Libros disponibles:"
    for (( i=0; i<total_pdfs; i++ )); do
        echo "[$i] ${all_names[$i]} - ${all_pages[$i]} páginas"
    done
    echo ""
    
    selected_index=""
    if [ -t 0 ]; then
        while true; do
            read -r -p "Seleccione el número del libro a procesar [0-$((total_pdfs - 1))]: " selection_val || true
            if [[ -n "$selection_val" && "$selection_val" =~ ^[0-9]+$ && "$selection_val" -ge 0 && "$selection_val" -lt "$total_pdfs" ]]; then
                selected_index="$selection_val"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        selected_index=0
        echo "[Auto] Seleccionado libro 0 debido a entrada no interactiva"
    fi
    
    selected_pdf="${all_pdfs[$selected_index]}"
    selected_filename="${all_names[$selected_index]}"
    
    # Determinar idioma de origen
    orig_lang="en"
    if [[ "$selected_filename" =~ \.es\.pdf$ ]]; then
        orig_lang="es"
    elif [[ "$selected_filename" =~ \.en\.pdf$ ]]; then
        orig_lang="en"
    elif [[ "$selected_filename" =~ \.de\.pdf$ ]]; then
        orig_lang="de"
    fi
    
    echo ""
    echo "Seleccione el idioma de destino para vociferar:"
    echo "[0] vociferar en el idioma original"
    echo "[1] vociferar hacia el español"
    echo "[2] vociferar hacia el ingles"
    echo "[3] vociferar hacia el alemán"
    echo ""
    
    lang_choice="0"
    if [ -t 0 ]; then
        while true; do
            read -r -p "Tipee [0/1/2/3] y enter: " input_lang || true
            if [[ "$input_lang" =~ ^[0-3]$ ]]; then
                lang_choice="$input_lang"
                break
            elif [[ -z "$input_lang" ]]; then
                lang_choice="0"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        lang_choice="0"
        echo "[Auto] Seleccionado idioma original (0) debido a entrada no interactiva"
    fi
    
    target_lang="$orig_lang"
    case "$lang_choice" in
        0) target_lang="$orig_lang" ;;
        1) target_lang="es" ;;
        2) target_lang="en" ;;
        3) target_lang="de" ;;
        *) target_lang="$orig_lang" ;;
    esac
    
    if [ "$target_lang" != "$orig_lang" ]; then
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
    
    bash ./scripting/vociferate-pdf.single-lang--page-by-page.sh "$selected_pdf" "$lang_choice"
    unset TRANSLATOR_SERVICE
    unset AUDIO_OPTIMIZE
    
    echo ""
    echo "🎉 ¡Conversión ardua completada con éxito!"
    echo ""
fi

if [[ "$mode_selection" == "4" ]]; then
    echo ""
    read -r -p "Desea iterar todos los pdfs? (si/no) [Por defecto: no]: " iterar_confirm || true
    iterar_confirm=$(echo "$iterar_confirm" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    
    if [[ "$iterar_confirm" != "si" && "$iterar_confirm" != "s" ]]; then
        echo "❌ Operación cancelada por el usuario."
        exit 0
    fi
    
    echo ""
    echo "cuantas paginas por pdf?"
    echo "[0] Todas"
    echo "[5-15] del 5 al 15"
    echo "[10] del 1 hasta el 10"
    echo ""
    read -r -p "Seleccione opción [Por defecto: 0]: " pages_input || true
    pages_input=$(echo "$pages_input" | tr -d '[:space:]')
    if [[ -z "$pages_input" ]]; then
        pages_input="0"
    fi
    
    echo ""
    echo "Seleccione el idioma de destino para vociferar:"
    echo "[0] vociferar en el idioma original"
    echo "[1] vociferar hacia el español"
    echo "[2] vociferar hacia el ingles"
    echo "[3] vociferar hacia el alemán"
    echo ""
    
    lang_choice="0"
    if [ -t 0 ]; then
        while true; do
            read -r -p "Tipee [0/1/2/3] y enter: " input_lang || true
            if [[ "$input_lang" =~ ^[0-3]$ ]]; then
                lang_choice="$input_lang"
                break
            elif [[ -z "$input_lang" ]]; then
                lang_choice="0"
                break
            else
                echo "❌ Opción inválida. Intente de nuevo."
            fi
        done
    else
        lang_choice="0"
        echo "[Auto] Seleccionado idioma original (0) debido a entrada no interactiva"
    fi
    
    # Encontrar todos los PDFs
    declare -a all_pdfs=()
    declare -a all_filenames=()
    declare -a all_pages=()
    temp_all=$(mktemp)
    while IFS= read -r -d '' pdf; do
        filename=$(basename "$pdf")
        if [[ "$pdf" =~ /\.git/ || "$pdf" =~ /personal/tmp_ ]]; then
            continue
        fi
        pages=$(get_page_count "$pdf")
        pages=${pages:-0}
        printf '%d|%s|%s\n' "$pages" "$pdf" "$filename" >> "$temp_all"
    done < <(find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0)
    
    if [[ -f "$temp_all" ]]; then
        while IFS='|' read -r pages pdf filename; do
            if [[ -n "$pdf" ]]; then
                all_pages+=("$pages")
                all_pdfs+=("$pdf")
                all_filenames+=("$filename")
            fi
        done < <(sort -t'|' -k1,1n "$temp_all")
        rm -f "$temp_all"
    fi
    
    total_pdfs=${#all_pdfs[@]}
    if [[ "$total_pdfs" -eq 0 ]]; then
        echo "❌ No se encontraron archivos PDF."
        exit 1
    fi
    
    if [[ "$lang_choice" != "0" ]]; then
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
    
    export OVERRIDE_RANGE="$pages_input"
    export OVERRIDE_LANG_OPT="$lang_choice"
    
    for (( i=0; i<total_pdfs; i++ )); do
        pdf_path="${all_pdfs[$i]}"
        pdf_name="${all_filenames[$i]}"
        pdf_page_count="${all_pages[$i]}"
        echo ""
        echo "----------------------------------------------------"
        echo "[Batch $((i+1)) / $total_pdfs] Procesando: $pdf_name ($pdf_page_count páginas)"
        echo "----------------------------------------------------"
        bash ./scripting/vociferate-pdf.single-lang--page-by-page.sh "$pdf_path" "$lang_choice"
    done
    
    unset OVERRIDE_RANGE
    unset OVERRIDE_LANG_OPT
    unset TRANSLATOR_SERVICE
    unset AUDIO_OPTIMIZE
    
    echo ""
    echo "===================================================="
    echo "🎉 ¡Conversión en lote completada con éxito!"
    echo "===================================================="
    echo ""
fi

# =========================================================
# ELIMINAR DUPLICADOS
# =========================================================

echo
echo "🧹 Eliminando PDFs duplicados..."

# Conserva SOLO un ejemplar
# NO crea .1
# NO crea copias
# NO crea hardlinks

declare -A seen_hashes
while IFS= read -r -d '' file; do
    hash=$(sha256sum "$file" | awk '{print $1}')
    if [ -n "${seen_hashes[$hash]:-}" ]; then
        echo "   🗑️  Eliminando duplicado: '$file' (Idéntico a '${seen_hashes[$hash]}')"
        rm -f "$file"
    else
        seen_hashes[$hash]="$file"
    fi
done < <(find "$ABS_DIR" -type f ! -path '*/.git/*' -print0)

echo "✅ Duplicados eliminados"

# =========================================================
# PROCESAR PDFs
# =========================================================

if [[ "${FORCE_RENEW_CACHE:-0}" == "1" ]]; then
    echo
    echo "📚 Procesando PDFs (Sanitizando y renovando metadata)..."

    find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0 |
    while IFS= read -r -d '' file; do

        echo
        echo "========================================"
        echo "[+] Archivo:"
        echo "    $file"

        base=$(basename "$file")

        # =====================================================
        # VALIDAR MIME REAL
        # =====================================================

        mime=$(file --mime-type -b "$file")

        if [[ "$mime" != "application/pdf" ]]; then
            echo "[!] No es un PDF válido"
            continue
        fi

        # =====================================================
        # SANITIZAR SIEMPRE (Ignorar si ya está linearizado)
        # =====================================================

        echo "[*] Forzando sanitización para eliminar posibles scripts/metadata..."

        # =====================================================
        # LIMPIAR METADATA
        # =====================================================

        if exiftool \
            -overwrite_original \
            -all= \
            "$file" >/dev/null 2>&1; then

            echo "[+] Metadata eliminada"

        else
            echo "[!] Error eliminando metadata"
            continue
        fi

        # =====================================================
        # SANITIZAR PDF
        # =====================================================

        # QPDF < 10.0.0 no soporta --replace-input, usamos un archivo temporal
        tmp_qpdf=$(mktemp)
        if qpdf \
            --linearize \
            --object-streams=generate \
            "$file" \
            "$tmp_qpdf" >/dev/null 2>&1; then

            mv -f "$tmp_qpdf" "$file"
            echo "[+] PDF sanitizado"

        else
            rm -f "$tmp_qpdf"
            echo "[!] QPDF falló"
            continue
        fi

        # =====================================================
        # CONSERVAR NOMBRE ORIGINAL
        # =====================================================

        echo "[+] Nombre preservado:"
        echo "    $base"

    done

    echo
    echo "========================================"
    echo "✅ PDFs procesados"
    echo "========================================"
else
    echo
    echo "⚡ Reutilizando caché: Omitiendo sanitización pesada de PDFs existentes."
fi

# =========================================================
# GENERAR MINIATURAS
# =========================================================

mkdir -p "$THUMBS_DIR"

echo
echo "📸 Analizando PDFs..."

temp_list=$(mktemp)

find -L "$ABS_DIR" -maxdepth 1 -type f \( -iname "*.pdf" -o -iname "*.PDF" \) -print0 |
while IFS= read -r -d '' pdf; do

    pages=$(get_page_count "$pdf")
    pages=${pages:-0}

    printf '%s|%s\n' "$pages" "$pdf" >> "$temp_list"

done

mapfile -t PDF_DATA < <(sort -t'|' -k1,1rn "$temp_list")

rm -f "$temp_list"

TOTAL=${#PDF_DATA[@]}

if [[ "$TOTAL" -eq 0 ]]; then
    echo
    echo "⚠️ No se encontraron PDFs"
    exit 0
fi

echo
echo "🖼️ Generando miniaturas..."

COUNT=0

for entry in "${PDF_DATA[@]}"; do

    COUNT=$((COUNT + 1))

    pdf="${entry#*|}"

    filename=$(basename "$pdf")

    # Hash SOLO para miniaturas
    thumb_id=$(printf '%s' "$filename" | sha256sum | awk '{print $1}')

    thumb_base="$THUMBS_DIR/$thumb_id"
    thumb_path="${thumb_base}.jpg"

    printf "\r[%d/%d] 🔄 %-50.50s" \
        "$COUNT" \
        "$TOTAL" \
        "$filename"

    if [[ "${FORCE_RENEW_CACHE:-0}" == "1" || ! -f "$thumb_path" ]]; then

        if ! pdftoppm \
            -jpeg \
            -f 1 \
            -singlefile \
            "$pdf" \
            "$thumb_base" >/dev/null 2>&1; then

            echo
            echo "⚠️ Error miniatura:"
            echo "    $filename"
        fi
    fi

done

echo
echo "✅ Miniaturas listas"

mkdir -p "$HTM_DIR"
echo
echo "🛠️ Generando visores htm monolíticos (Chrome compatible)..."

# =========================================================
# GENERAR HTML
# =========================================================

echo
echo "🌐 Generando HTML..."

cat > "$OUT_HTML" <<'EOF'
<!DOCTYPE html>
<html lang="es" data-theme="light">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>📚 Biblioteca Premium</title>
    <style>
        :root {
            --bg-color: #f8fafc;
            --card-bg: #ffffff;
            --text-main: #1e293b;
            --text-muted: #64748b;
            --accent: #3b82f6;
            --accent-hover: #2563eb;
            --border-color: #e2e8f0;
            --shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            --transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        }

        [data-theme="dark"] {
            --bg-color: #0f172a;
            --card-bg: #1e293b;
            --text-main: #f1f5f9;
            --text-muted: #94a3b8;
            --accent: #60a5fa;
            --accent-hover: #93c5fd;
            --border-color: #334155;
            --shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.3), 0 10px 10px -5px rgba(0, 0, 0, 0.2);
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            transition: var(--transition);
            line-height: 1.5;
            padding-bottom: 50px;
        }

        header {
            position: sticky;
            top: 0;
            z-index: 100;
            background: var(--card-bg);
            backdrop-filter: blur(10px);
            border-bottom: 1px solid var(--border-color);
            padding: 1.5rem 2rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        h1 {
            font-family: inherit;
            font-size: 1.75rem;
            font-weight: 700;
            background: linear-gradient(135deg, var(--accent), #8b5cf6);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .controls {
            display: flex;
            gap: 1rem;
            align-items: center;
        }

        button, .btn {
            padding: 0.6rem 1.2rem;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background: var(--card-bg);
            color: var(--text-main);
            font-weight: 500;
            cursor: pointer;
            transition: var(--transition);
            display: flex;
            align-items: center;
            gap: 0.5rem;
            font-size: 0.9rem;
        }

        button:hover {
            border-color: var(--accent);
            color: var(--accent);
            transform: translateY(-2px);
        }

        .btn-primary {
            background: var(--accent);
            color: white !important;
            border: none;
        }

        .btn-primary:hover {
            background: var(--accent-hover);
            color: white !important;
        }

        .btn-audio {
            background: linear-gradient(135deg, #a855f7, #6366f1) !important;
            color: white !important;
            border: none !important;
        }

        .btn-audio:hover {
            background: linear-gradient(135deg, #be185d, #a855f7) !important;
            color: white !important;
            transform: translateY(-2px);
        }

        .is-visited {
            background: #000 !important;
            color: #fff !important;
            border-color: #000 !important;
        }

        .container {
            max-width: 1400px;
            margin: 2rem auto;
            padding: 0 2rem;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 2rem;
        }

        .card {
            background: var(--card-bg);
            border-radius: 16px;
            border: 1px solid var(--border-color);
            overflow: hidden;
            display: flex;
            flex-direction: column;
            transition: var(--transition);
            box-shadow: var(--shadow);
            position: relative;
        }

        .card:hover {
            transform: translateY(-8px) scale(1.02);
            border-color: var(--accent);
        }

        .thumb-container {
            position: relative;
            height: 380px;
            overflow: hidden;
            background: #eee;
        }

        .card img {
            width: 100%;
            height: 100%;
            object-fit: cover;
            transition: var(--transition);
        }

        .card:hover img {
            transform: scale(1.05);
        }

        .card-content {
            padding: 1.5rem;
            flex-grow: 1;
            display: flex;
            flex-direction: column;
            gap: 1rem;
        }

        .title {
            font-size: 1rem;
            font-weight: 600;
            color: var(--text-main);
            display: -webkit-box;
            -webkit-line-clamp: 2;
            -webkit-box-orient: vertical;
            overflow: hidden;
            height: 3rem;
        }

        .meta {
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 0.85rem;
            color: var(--text-muted);
        }

        .actions {
            margin-top: auto;
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
        }

        .copy-btn {
            width: 100%;
            justify-content: center;
            font-size: 0.8rem;
            background: rgba(59, 130, 246, 0.1);
            border-color: transparent;
            color: var(--accent);
        }

        .copy-btn:hover {
            background: var(--accent);
            color: white;
        }

        .view-btn {
            width: 100%;
            justify-content: center;
            text-decoration: none;
        }

        .toast {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: #10b981;
            color: white;
            padding: 12px 24px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
            transform: translateY(100px);
            transition: var(--transition);
            z-index: 1000;
        }

        .toast.show {
            transform: translateY(0);
        }

        @media (max-width: 640px) {
            header {
                flex-direction: column;
                gap: 1rem;
                text-align: center;
            }
            .grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>

<header>
    <h1>📚 Biblioteca PDF</h1>
    <div class="controls">
        <button id="langToggle" style="background: linear-gradient(135deg, #f59e0b, #d97706); color: white; font-weight: bold; border: none; min-width: 90px; justify-content: center;">Lang DE</button>
        <button id="sortPages">📊 Ordenar por Páginas</button>
        <button id="sortTitle">🔤 Ordenar por Título</button>
        <button id="toggleTheme">🌓 Cambiar Tema</button>
    </div>
</header>

<div class="container">
    <div class="grid" id="bookGrid">
EOF

for entry in "${PDF_DATA[@]}"; do

    pages="${entry%%|*}"
    pdf="${entry#*|}"

    filename=$(basename "$pdf")
    # Clean filename for query
    clean_name=$(printf '%s' "$filename")

    thumb_id=$(printf '%s' "$filename" | sha256sum | awk '{print $1}')
    thumb="$THUMBS_DIR/$thumb_id.jpg"
    
    # Clean language suffix to find clean htm name
    orig_lang=$(echo "$filename" | rev | cut -d. -f2 | rev)
    if [[ "$orig_lang" =~ ^(en|es|de)$ ]]; then
        clean_book_name=$(echo "$filename" | sed "s/\.${orig_lang}\.pdf$//")
    else
        clean_book_name="${filename%.pdf}"
    fi
    
    # Determinar qué visor htm enlazar (prioriza audio)
    htm_audio="$HTM_AUDIO_DIR/${clean_book_name}.htm"
    htm_normal="$HTM_DIR/${filename%.pdf}.htm"
    
    # Buscar si existen partes recortadas de PDF para este libro
    trimmed_pdfs=()
    if [[ -d "personal/pdfs_recortados" ]]; then
        while IFS= read -r -d '' part; do
            trimmed_pdfs+=("$part")
        done < <(find "personal/pdfs_recortados" -maxdepth 1 -name "${filename%.pdf}-part_*.pdf" -print0 2>/dev/null | sort -z)
    fi

    if [[ ${#trimmed_pdfs[@]} -gt 0 ]]; then
        # Existen partes divididas, generar el visor htm normal para cada una
        for part_pdf in "${trimmed_pdfs[@]}"; do
            part_filename=$(basename "$part_pdf")
            part_htm_normal="$HTM_DIR/${part_filename%.pdf}.htm"
            if [[ "${FORCE_RENEW_CACHE:-0}" == "1" || ! -f "$part_htm_normal" ]]; then
                "$PY_BIN" scripting/generar_htm.py "$part_pdf" "$part_htm_normal" "lib/pdf.js" "lib/pdf.worker.js"
            fi
        done
    else
        # Generar visor htm normal si no existe o si se renueva caché
        if [[ "${FORCE_RENEW_CACHE:-0}" == "1" || ! -f "$htm_normal" ]]; then
            "$PY_BIN" scripting/generar_htm.py "$pdf" "$htm_normal" "lib/pdf.js" "lib/pdf.worker.js"
        fi
    fi

    # Construir HTML de botones (prioriza y separa audio y normal si existen ambos)
    if [[ ${#trimmed_pdfs[@]} -gt 0 ]]; then
        actions_html="<div class=\"parts-container\" style=\"display: flex; flex-direction: column; gap: 0.5rem; width: 100%; border-top: 1px dashed var(--border-color); padding-top: 0.75rem;\">"
        actions_html+="<div style=\"font-size: 0.85rem; font-weight: bold; color: var(--text-muted); margin-bottom: 0.25rem;\">📚 Partes del Libro:</div>"
        
        part_idx=1
        for part_pdf in "${trimmed_pdfs[@]}"; do
            part_filename=$(basename "$part_pdf")
            part_base="${part_filename%.pdf}"
            
            part_htm_normal="$HTM_DIR/${part_base}.htm"
            part_suffix=$(echo "$part_base" | grep -o -E "\-part_[0-9]+$")
            part_htm_audio="$HTM_AUDIO_DIR/${clean_book_name}${part_suffix}.htm"
            
            actions_html+="<div style=\"display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; background: rgba(0,0,0,0.02); padding: 0.35rem 0.5rem; border-radius: 6px; border: 1px solid var(--border-color);\">"
            actions_html+="<span style=\"font-size: 0.85rem; font-weight: 600;\">Parte $part_idx</span>"
            actions_html+="<div style=\"display: flex; gap: 0.35rem; flex-wrap: wrap; justify-content: flex-end;\">"
            
            actions_html+="<a href=\"$part_htm_normal\" target=\"_blank\" class=\"btn btn-primary view-btn\" style=\"padding: 0.3rem 0.6rem; font-size: 0.8rem; border-radius: 4px;\">📖 Leer</a>"
            actions_html+="<a href=\"$part_htm_normal\" class=\"btn btn-primary view-btn\" onclick=\"window.open(this.href, '_blank', 'width=1024,height=768,resizable=yes,scrollbars=yes'); return false;\" style=\"padding: 0.3rem 0.6rem; font-size: 0.8rem; border-radius: 4px; background: #6b21a8;\">📖 L Popup</a>"
            
            if [[ -f "$part_htm_audio" ]]; then
                actions_html+="<a href=\"$part_htm_audio\" target=\"_blank\" class=\"btn btn-audio audio-btn\" style=\"padding: 0.3rem 0.6rem; font-size: 0.8rem; border-radius: 4px;\">🎧 Audio</a>"
                actions_html+="<a href=\"$part_htm_audio\" class=\"btn btn-audio audio-btn\" onclick=\"window.open(this.href, '_blank', 'width=1024,height=768,resizable=yes,scrollbars=yes'); return false;\" style=\"padding: 0.3rem 0.6rem; font-size: 0.8rem; border-radius: 4px; background: #be185d;\">🎧 A Popup</a>"
            fi
            
            actions_html+="</div>"
            actions_html+="</div>"
            
            part_idx=$((part_idx + 1))
        done
        actions_html+="</div>"
    else
        if [[ -f "$htm_audio" ]]; then
            actions_html="<div style=\"display: flex; gap: 0.5rem; width: 100%; flex-wrap: wrap;\">
                            <a href=\"$htm_normal\" target=\"_blank\" class=\"btn btn-primary view-btn\" style=\"flex: 1; justify-content: center;\">📖 Leer PDF</a>
                            <a href=\"$htm_normal\" class=\"btn btn-primary view-btn\" onclick=\"window.open(this.href, '_blank', 'width=1024,height=768,resizable=yes,scrollbars=yes'); return false;\" style=\"flex: 1; justify-content: center; background: #6b21a8;\">📖 L Popup</a>
                            <a href=\"$htm_audio\" target=\"_blank\" class=\"btn btn-audio audio-btn\" style=\"flex: 1; justify-content: center;\">🎧 Audio</a>
                            <a href=\"$htm_audio\" class=\"btn btn-audio audio-btn\" onclick=\"window.open(this.href, '_blank', 'width=1024,height=768,resizable=yes,scrollbars=yes'); return false;\" style=\"flex: 1; justify-content: center; background: #be185d;\">🎧 A Popup</a>
                          </div>"
        else
            actions_html="<div style=\"display: flex; gap: 0.5rem; width: 100%; flex-wrap: wrap;\">
                            <a href=\"$htm_normal\" target=\"_blank\" class=\"btn btn-primary view-btn\" style=\"flex: 1; justify-content: center;\">📖 Leer PDF</a>
                            <a href=\"$htm_normal\" class=\"btn btn-primary view-btn\" onclick=\"window.open(this.href, '_blank', 'width=1024,height=768,resizable=yes,scrollbars=yes'); return false;\" style=\"flex: 1; justify-content: center; background: #6b21a8;\">📖 L Popup</a>
                          </div>"
        fi
    fi

    if [[ ! -f "$thumb" ]]; then
        thumb="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIzMDAiIGhlaWdodD0iNDAwIiB2aWV3Qm94PSIwIDAgMzAwIDQwMCI+PHJlY3Qgd2lkdGg9IjEwMCUiIGhlaWdodD0iMTAwJSIgZmlsbD0iI2VlZSIvPjx0ZXh0IHg9IjUwJSIgeT0iNTAlIiBmb250LXNpemU9IjI0IiBmaWxsPSIjYmJiIiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBkeT0iLjc1ZW0iIGZvbnQtZmFtaWx5PSJzYW5zLXNlcmlmIj5QREY8L3RleHQ+PC9zdmc+"
    fi

    cat >> "$OUT_HTML" <<EOF
        <div class="card" data-pages="$pages" data-title="$filename">
            <div class="thumb-container">
                <img src="$thumb" alt="$filename" loading="lazy">
            </div>
            <div class="card-content">
                <div class="title" title="$filename">$filename</div>
                <div class="meta">
                    <span>📄 $pages páginas</span>
                </div>
                <div class="actions">
                    $actions_html
                    <button class="copy-btn" onclick="copyQuery('$clean_name')">
                        ⚡ Ejecutar Query
                    </button>
                </div>
            </div>
        </div>
EOF

done

cat >> "$OUT_HTML" <<'EOF'
    </div>
</div>

<div id="toast" class="toast">¡Copiado al portapapeles!</div>

<script>
    const grid = document.getElementById('bookGrid');
    const cards = Array.from(grid.getElementsByClassName('card'));
    const toast = document.getElementById('toast');

    // Theme Toggle
    const toggleTheme = document.getElementById('toggleTheme');
    toggleTheme.addEventListener('click', () => {
        const currentTheme = document.documentElement.getAttribute('data-theme');
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';
        document.documentElement.setAttribute('data-theme', newTheme);
        localStorage.setItem('theme', newTheme);
    });

    // Restore Theme
    const savedTheme = localStorage.getItem('theme');
    if (savedTheme) {
        document.documentElement.setAttribute('data-theme', savedTheme);
    }

    // Lang Toggle
    const langToggle = document.getElementById('langToggle');
    const langs = ['DE', 'ES', 'EN'];
    let currentLangIdx = 0;
    
    // Attempt to restore language selection
    const savedLang = localStorage.getItem('globalAudioLang');
    if (savedLang) {
        currentLangIdx = langs.indexOf(savedLang);
        if (currentLangIdx === -1) currentLangIdx = 0;
    }
    
    function updateLangLinks() {
        if (!langToggle) return;
        langToggle.textContent = 'Lang ' + langs[currentLangIdx];
        localStorage.setItem('globalAudioLang', langs[currentLangIdx]);
        
        // Update all audio-btn links
        document.querySelectorAll('a.audio-btn').forEach(link => {
            try {
                let url = new URL(link.href, window.location.href);
                url.searchParams.set('lang', langs[currentLangIdx].toLowerCase());
                link.href = url.href;
            } catch(e) { console.error(e); }
        });
    }
    
    if (langToggle) {
        langToggle.addEventListener('click', () => {
            currentLangIdx = (currentLangIdx + 1) % langs.length;
            updateLangLinks();
        });
        // Initial setup
        updateLangLinks();
    }

    // Sorting
    let pageSortDesc = true;
    document.getElementById('sortPages').addEventListener('click', () => {
        const sorted = cards.sort((a, b) => {
            const pA = parseInt(a.dataset.pages);
            const pB = parseInt(b.dataset.pages);
            return pageSortDesc ? pB - pA : pA - pB;
        });
        pageSortDesc = !pageSortDesc;
        renderSorted(sorted);
    });

    let titleSortAsc = true;
    document.getElementById('sortTitle').addEventListener('click', () => {
        const sorted = cards.sort((a, b) => {
            return titleSortAsc 
                ? a.dataset.title.localeCompare(b.dataset.title)
                : b.dataset.title.localeCompare(a.dataset.title);
        });
        titleSortAsc = !titleSortAsc;
        renderSorted(sorted);
    });

    function renderSorted(sortedArray) {
        grid.innerHTML = '';
        sortedArray.forEach(card => grid.appendChild(card));
    }

    // Clipboard Functionality
    function copyQuery(bookName) {
        const basePath = window.location.pathname.substring(0, window.location.pathname.lastIndexOf('/'));
        const query = `bash ~/monoliths-llm/vociferate-pdf.sh ${basePath}/pdfs/${bookName}`;
        navigator.clipboard.writeText(query).then(() => {
            showToast();
        });
    }

    function showToast() {
        toast.classList.add('show');
        setTimeout(() => {
            toast.classList.remove('show');
        }, 2000);
    }

    // Mark links as visited using localStorage
    document.querySelectorAll('a.btn').forEach(link => {
        if (localStorage.getItem('visited_' + link.href)) {
            link.classList.add('is-visited');
        }
        link.addEventListener('click', () => {
            localStorage.setItem('visited_' + link.href, 'true');
            link.classList.add('is-visited');
        });
    });
</script>

</body>
</html>
EOF

echo
echo "========================================"
echo "✅ TODO COMPLETADO"
echo "📄 HTML generado:"
echo "    $OUT_HTML"
echo "========================================"