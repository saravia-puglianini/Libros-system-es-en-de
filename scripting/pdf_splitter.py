import os
import re
import subprocess
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get('PORTABLE_ROOT', os.path.dirname(SCRIPT_DIR) if os.path.basename(SCRIPT_DIR) == 'scripting' else SCRIPT_DIR)

MAX_HTML_SIZE = 75 * 1024 * 1024  # 75 MB limit
TEMPLATE_SIZE = 2.6 * 1024 * 1024   # Approx size of htm.htm template

def get_total_pages(pdf_path):
    try:
        out = subprocess.check_output(["pdfinfo", pdf_path]).decode('utf-8', errors='ignore')
        for line in out.split('\n'):
            if line.startswith("Pages:"):
                return int(line.split()[1])
    except Exception as e:
        print(f"Error getting total pages: {e}")
    return 1

def get_audio_sizes_for_book(book_name, total_pages):
    audio_dir = f"{PROJECT_ROOT}/personal/htm-pags"
    if not os.path.exists(audio_dir):
        return {}, {}

    audio_sizes = {}  # page_num -> sum of audio file sizes for this page
    audio_files = {}  # page_num -> list of (lang, file_path)
    
    # Audio pattern: <book_name>.page-<page_num>[.optime].<lang>.<ext>
    audio_pattern = re.compile(rf"^{re.escape(book_name)}\.page-(\d+)(?:\.optime)?\.(en|es|de)\.(mp3|wav)$", re.IGNORECASE)
    
    for fname in os.listdir(audio_dir):
        match = audio_pattern.match(fname)
        if match:
            page_num = int(match.group(1))
            if page_num > total_pages:
                continue
            lang = match.group(2).lower()
            file_path = os.path.join(audio_dir, fname)
            size = os.path.getsize(file_path)
            
            audio_sizes[page_num] = audio_sizes.get(page_num, 0) + size
            if page_num not in audio_files:
                audio_files[page_num] = []
            audio_files[page_num].append((lang, file_path))
            
    return audio_sizes, audio_files

def get_pdf_part_size(pdf_path, start, end):
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
        tmp_name = tmp.name
    try:
        subprocess.run([
            "qpdf", "--empty",
            "--pages", pdf_path, f"{start}-{end}",
            "--", tmp_name
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return os.path.getsize(tmp_name)
    except Exception as e:
        print(f"Error running qpdf to check size for {start}-{end}: {e}")
        # Fallback approximation
        return 0
    finally:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)

def cleanup_old_parts(pdf_path):
    out_dir = f"{PROJECT_ROOT}/personal/pdfs_recortados"
    if not os.path.exists(out_dir):
        return
    pdf_base = os.path.basename(pdf_path)
    base_name, _ = os.path.splitext(pdf_base)
    # Match base_name-part_XXXX.pdf
    pattern = re.compile(rf"^{re.escape(base_name)}-part_\d+\.pdf$", re.IGNORECASE)
    for fname in os.listdir(out_dir):
        if pattern.match(fname):
            try:
                os.remove(os.path.join(out_dir, fname))
                print(f"Removed old part PDF: {fname}")
            except Exception as e:
                print(f"Error removing old part PDF {fname}: {e}")

def cleanup_old_htm_parts(output_path):
    out_dir = os.path.dirname(output_path)
    if not os.path.exists(out_dir):
        return
    output_base, _ = os.path.splitext(os.path.basename(output_path))
    # Match output_base-part_XXXX.htm
    pattern = re.compile(rf"^{re.escape(output_base)}-part_\d+\.htm$", re.IGNORECASE)
    for fname in os.listdir(out_dir):
        if pattern.match(fname):
            try:
                os.remove(os.path.join(out_dir, fname))
                print(f"Removed old part HTM: {fname}")
            except Exception as e:
                print(f"Error removing old part HTM {fname}: {e}")

def get_dynamic_limit_for_book(book_name, total_pages):
    _, audio_files = get_audio_sizes_for_book(book_name, total_pages)
    unique_langs = set()
    for page_num in audio_files:
        for lang, _ in audio_files[page_num]:
            unique_langs.add(lang.lower())
    num_langs = len(unique_langs)
    if num_langs <= 1:
        # 1 solo idioma (o ninguno aún): 85 MB
        return 85 * 1024 * 1024, unique_langs
    elif num_langs == 2:
        # 2 idiomas: 250 MB
        return 250 * 1024 * 1024, unique_langs
    else:
        # 3 idiomas (en, es, de): 500 MB
        return 500 * 1024 * 1024, unique_langs

def will_require_partitioning(pdf_path, book_name, total_pages, max_html_size):
    audio_sizes, audio_files = get_audio_sizes_for_book(book_name, total_pages)
    unique_langs = set()
    audio_extensions = set()
    all_sizes = []
    
    for page_num in audio_files:
        for lang, file_path in audio_files[page_num]:
            unique_langs.add(lang.lower())
            audio_extensions.add(file_path.split('.')[-1].lower())
            all_sizes.append(os.path.getsize(file_path))
            
    num_langs = max(1, len(unique_langs))
    
    if all_sizes:
        avg_audio_size_per_page = sum(all_sizes) / len(audio_files)
    else:
        is_mp3 = "mp3" in audio_extensions
        per_lang_size = 1.0 * 1024 * 1024 if is_mp3 else 7.5 * 1024 * 1024
        avg_audio_size_per_page = per_lang_size * num_langs

    pdf_total_size = os.path.getsize(pdf_path)
    estimated_total_size = TEMPLATE_SIZE + (pdf_total_size + avg_audio_size_per_page * total_pages) * 1.34
    
    return estimated_total_size > max_html_size

def partition_pdf(pdf_path, book_name, total_pages, audio_sizes, max_html_size=None):
    if max_html_size is None:
        max_html_size, _ = get_dynamic_limit_for_book(book_name, total_pages)

    pdf_total_size = os.path.getsize(pdf_path)
    pdf_page_avg = pdf_total_size / total_pages
    
    def estimate_size(start_p, end_p):
        audio_sum = sum(audio_sizes.get(p, 0) for p in range(start_p, end_p + 1))
        pdf_sum = pdf_page_avg * (end_p - start_p + 1)
        return TEMPLATE_SIZE + (pdf_sum + audio_sum) * 1.34
        
    # Check if total size (with all audios) is already under max_html_size
    total_audio_sum = sum(audio_sizes.values())
    total_estimated = TEMPLATE_SIZE + (pdf_total_size + total_audio_sum) * 1.34
    if total_estimated <= max_html_size:
        # No need to partition at all!
        return [(1, total_pages)]
        
    parts = []
    start = 1
    
    while start <= total_pages:
        # Heuristic search: find candidate_end where estimated size <= max_html_size * 0.95
        candidate_end = start
        for p in range(start, total_pages + 1):
            if estimate_size(start, p) <= max_html_size * 0.95:
                candidate_end = p
            else:
                break
                
        # Now verify exact size using qpdf
        exact_pdf_size = get_pdf_part_size(pdf_path, start, candidate_end)
        audio_sum = sum(audio_sizes.get(p, 0) for p in range(start, candidate_end + 1))
        exact_html_size = TEMPLATE_SIZE + (exact_pdf_size + audio_sum) * 1.34
        
        if exact_html_size <= max_html_size:
            # We can try to grow candidate_end if it's not already total_pages
            while candidate_end < total_pages:
                next_end = candidate_end + 1
                next_exact_pdf_size = get_pdf_part_size(pdf_path, start, next_end)
                next_audio_sum = sum(audio_sizes.get(p, 0) for p in range(start, next_end + 1))
                next_exact_html_size = TEMPLATE_SIZE + (next_exact_pdf_size + next_audio_sum) * 1.34
                if next_exact_html_size <= max_html_size:
                    candidate_end = next_end
                    exact_pdf_size = next_exact_pdf_size
                else:
                    break
        else:
            # We must shrink candidate_end (but not below start)
            while candidate_end > start:
                candidate_end -= 1
                exact_pdf_size = get_pdf_part_size(pdf_path, start, candidate_end)
                audio_sum = sum(audio_sizes.get(p, 0) for p in range(start, candidate_end + 1))
                exact_html_size = TEMPLATE_SIZE + (exact_pdf_size + audio_sum) * 1.34
                if exact_html_size <= max_html_size:
                    break
                    
        parts.append((start, candidate_end))
        start = candidate_end + 1
        
    return parts

def split_pdf_file(pdf_path, start, end, part_num, total_parts):
    # Output path under `/home/user/Libros-system-es-en-de/personal/pdfs_recortados/`
    out_dir = f"{PROJECT_ROOT}/personal/pdfs_recortados"
    os.makedirs(out_dir, exist_ok=True)
    
    pdf_base = os.path.basename(pdf_path)
    base_name, ext = os.path.splitext(pdf_base)
    
    part_suffix = f"-part_{part_num:04d}"
    part_pdf_name = f"{base_name}{part_suffix}{ext}"
    part_pdf_path = os.path.join(out_dir, part_pdf_name)
    
    try:
        subprocess.run([
            "qpdf", "--empty",
            "--pages", pdf_path, f"{start}-{end}",
            "--", part_pdf_path
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"Part PDF created: {part_pdf_path} (pages {start}-{end})")
        return part_pdf_path, part_suffix
    except Exception as e:
        print(f"Error creating part PDF for {start}-{end}: {e}")
        return None, None
