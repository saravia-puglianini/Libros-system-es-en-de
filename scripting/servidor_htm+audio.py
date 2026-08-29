import os
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get('PORTABLE_ROOT', os.path.dirname(SCRIPT_DIR) if os.path.basename(SCRIPT_DIR) == 'scripting' else SCRIPT_DIR)
import os
import sys
import urllib.parse
import html
import io
import http.server
import functools
import re
import hashlib
import subprocess
import json

def get_available_langs(filepath):
    langs = []
    if not filepath.lower().endswith('.htm'):
        return langs
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            chunk = f.read(65536)
            if 'id="play-es"' in chunk: langs.append('es')
            if 'id="play-en"' in chunk: langs.append('en')
            if 'id="play-de"' in chunk: langs.append('de')
    except Exception:
        pass
    return langs

TITLE_CACHE = {}
def get_translated_titles(title):
    if title in TITLE_CACHE:
        return TITLE_CACHE[title]
    script = f"""
import os
import sys

# Dynamically add portable python site-packages to sys.path
project_root = "{PROJECT_ROOT}"
for folder in os.listdir(project_root):
    if folder.startswith('portable-bin-'):
        site_pkg = os.path.join(project_root, folder, 'python', 'site-packages')
        if os.path.exists(site_pkg) and site_pkg not in sys.path:
            sys.path.insert(0, site_pkg)

try:
    from deep_translator import GoogleTranslator
    import time
    
    def translate_with_retry(text, target):
        translator = GoogleTranslator(source='auto', target=target)
        while True:
            try:
                res = translator.translate(text)
                if res and "server error" not in res.lower():
                    return res
            except Exception:
                pass
            time.sleep(1)

    es = translate_with_retry(sys.argv[1], 'es')
    en = translate_with_retry(sys.argv[1], 'en')
    de = translate_with_retry(sys.argv[1], 'de')
    import json
    print(json.dumps({{'es': es, 'en': en, 'de': de}}))
except Exception as e:
    import json
    print(json.dumps({{'es': sys.argv[1], 'en': sys.argv[1], 'de': sys.argv[1]}}))
"""
    try:
        res = subprocess.run(['python3.11', '-c', script, title], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out = res.stdout.decode('utf-8').strip()
        if out:
            data = json.loads(out)
            TITLE_CACHE[title] = data
            return data
    except Exception:
        pass
    fallback = {'es': title, 'en': title, 'de': title}
    TITLE_CACHE[title] = fallback
    return fallback

class CustomHandler(http.server.SimpleHTTPRequestHandler):
    # Límite de velocidad en Megabytes por segundo (MB/s) por descarga.
    # Por ejemplo, 2.5 MB/s equivale a unos 20 Mbps, ideal para que varios usuarios
    # descarguen simultáneamente sin saturar la red local. Configurar a 0 para desactivar.
    bandwidth_limit_mb = 2.5

    def do_GET(self):
        if self.path.startswith('/thumbnails/'):
            thumb_name = self.path[len('/thumbnails/'):].split('?')[0]
            thumb_name = urllib.parse.unquote(thumb_name)
            thumb_path = os.path.join(PROJECT_ROOT, 'thumbnails', thumb_name)
            if os.path.isfile(thumb_path):
                self.send_response(200)
                if thumb_path.lower().endswith('.png'):
                    self.send_header("Content-type", "image/png")
                else:
                    self.send_header("Content-type", "image/jpeg")
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                with open(thumb_path, 'rb') as f:
                    self.wfile.write(f.read())
                return
            else:
                self.send_error(404, "Thumbnail not found")
                return
        super().do_GET()

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
            
        force_download = 'download=1' in self.path
        range_header = self.headers.get('Range')
        
        if not range_header and not force_download:
            f = super().send_head()
            if f:
                self.send_header('Accept-Ranges', 'bytes')
            return f
            
        try:
            file_size = os.path.getsize(path)
        except OSError:
            self.send_error(404, "File not found")
            return None
            
        ctype = self.guess_type(path)
        
        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(404, "File not found")
            return None
            
        if range_header:
            match = re.match(r'bytes=(\d+)-(\d*)', range_header)
            if not match:
                f.close()
                self.send_error(400, "Bad Range request")
                return None
                
            start = int(match.group(1))
            end_str = match.group(2)
            end = int(end_str) if end_str else file_size - 1
            
            if start >= file_size or end >= file_size or start > end:
                f.close()
                self.send_error(416, "Requested Range Not Satisfiable")
                self.send_header('Content-Range', f'bytes */{file_size}')
                self.end_headers()
                return None
                
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
            content_length = end - start + 1
            f.seek(start)
            self.range_to_copy = (start, end)
        else:
            self.send_response(200)
            content_length = file_size
            
        self.send_header('Content-type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(content_length))
        
        if force_download:
            filename = os.path.basename(path)
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.send_header('Connection', 'close')
            self.close_connection = True
            
        fs = os.fstat(f.fileno())
        self.send_header("Last-Modified", self.date_time_string(fs.st_mtime))
        self.end_headers()
        
        return f

    def copyfile(self, source, outputfile):
        import time
        limit_mb = getattr(self, 'bandwidth_limit_mb', 2.5)
        
        if hasattr(self, 'range_to_copy'):
            start, end = self.range_to_copy
            delattr(self, 'range_to_copy')
            bytes_to_copy = end - start + 1
        else:
            bytes_to_copy = None
            
        buffer_size = 64 * 1024 # 64 KB
        total_written = 0
        start_time = time.time()
        
        # 1 MB = 1024 * 1024 bytes
        rate_limit = limit_mb * 1024 * 1024 if limit_mb > 0 else None
        
        while True:
            if bytes_to_copy is not None:
                if total_written >= bytes_to_copy:
                    break
                chunk_size = min(buffer_size, bytes_to_copy - total_written)
            else:
                chunk_size = buffer_size
                
            data = source.read(chunk_size)
            if not data:
                break
                
            try:
                outputfile.write(data)
            except ConnectionError:
                # El cliente canceló la descarga o cerró la conexión
                break
                
            total_written += len(data)
            
            if rate_limit:
                expected_time = total_written / rate_limit
                elapsed_time = time.time() - start_time
                if elapsed_time < expected_time:
                    time.sleep(expected_time - elapsed_time)

    def list_directory(self, path):
        try:
            items = os.listdir(path)
        except OSError:
            self.send_error(404, "No permission to list directory")
            return None
            
        items.sort(key=lambda a: a.lower())
        r = []
        enc = sys.getfilesystemencoding()
        title = 'htm+audio'
        
        r.append('<!DOCTYPE HTML>')
        r.append('<html lang="es">')
        r.append('<head>')
        r.append(f'<meta charset="{enc}">')
        r.append(f'<title>{title}</title>')
        r.append('<meta name="viewport" content="width=device-width, initial-scale=1.0">')
        r.append('<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📖</text></svg>">')
        r.append('<script>')
        r.append('let currentLang = "es";')
        r.append('let langs = ["es", "en", "de"];')
        r.append('function translateTitle(titleElement, lang) {')
        r.append('    let attr = titleElement.getAttribute("data-title-" + lang);')
        r.append('    if (attr) return attr;')
        r.append('    return titleElement.getAttribute("data-orig-title");')
        r.append('}')
        r.append('function updateLanguage(newLang) {')
        r.append('    currentLang = newLang;')
        r.append('    document.getElementById("langBtn").innerText = "Lang " + currentLang;')
        r.append('    document.querySelectorAll(".lang-text").forEach(el => {')
        r.append('        let attr = el.getAttribute("data-lang-" + currentLang);')
        r.append('        if (attr) el.innerText = attr;')
        r.append('    });')
        r.append('    document.querySelectorAll("a.book-link").forEach(el => {')
        r.append('        let href = el.getAttribute("data-base-href");')
        r.append('        if (!href) {')
        r.append('            href = el.getAttribute("href").split("?")[0];')
        r.append('            el.setAttribute("data-base-href", href);')
        r.append('        }')
        r.append('        el.setAttribute("href", href + "?lang=" + currentLang);')
        r.append('    });')
        r.append('    document.querySelectorAll(".book-title").forEach(el => {')
        r.append('        el.innerText = translateTitle(el, currentLang);')
        r.append('    });')
        r.append('    document.querySelectorAll("li.book-item").forEach(li => {')
        r.append('        let langsStr = li.getAttribute("data-langs");')
        r.append('        if (!langsStr) return;')
        r.append('        let bookLangs = langsStr.split(",");')
        r.append('        if (bookLangs.length === 0 || bookLangs[0] === "") {')
        r.append('            li.style.display = "flex";')
        r.append('        } else if (bookLangs.includes(currentLang)) {')
        r.append('            li.style.display = "flex";')
        r.append('        } else {')
        r.append('            li.style.display = "none";')
        r.append('        }')
        r.append('    });')
        r.append('}')
        r.append('function toggleLang() {')
        r.append('    let idx = langs.indexOf(currentLang);')
        r.append('    idx = (idx + 1) % langs.length;')
        r.append('    updateLanguage(langs[idx]);')
        r.append('}')
        r.append('window.onload = function() { updateLanguage("es"); };')
        r.append('</script>')
        r.append('</head>')
        r.append('<body>')
        
        r.append(f'<h1>{title} <button id="langBtn" onclick="toggleLang()">Lang es</button></h1>')
        
        # Collect images for fast lookup (lowercase name -> actual name)
        images = {f.lower(): f for f in items if f.lower().endswith(('.jpg', '.jpeg', '.png', '.webp', '.gif'))}
        
        # Grouping regex to parse base title and part number
        pattern = re.compile(r'^(.*?)-part_(\d+)(.*)$', re.IGNORECASE)
        
        grouped = {}
        for name in items:
            fullname = os.path.join(path, name)
            displayname = name
            linkname = name
            if os.path.isdir(fullname):
                displayname = name + "/"
                linkname = name + "/"
                
            # Skip images so they don't appear as standalone items
            if name.lower().endswith(('.jpg', '.jpeg', '.png', '.webp', '.gif')):
                continue
                
            match = pattern.match(name)
            if match and not os.path.isdir(fullname):
                base_name = match.group(1)
                part_num = int(match.group(2))
                
                # Make a pretty title for the group
                group_title = base_name.replace('_', ' ').replace('-', ' ').strip()
                group_title = ' '.join(w.capitalize() for w in group_title.split())
                
                if group_title not in grouped:
                    cover_url = None
                    for ext in ['.jpg', '.jpeg', '.png', '.webp', '.gif']:
                        if (base_name.lower() + ext) in images:
                            cover_url = images[base_name.lower() + ext]
                            break
                    if not cover_url:
                        for ext in ['.en.pdf', '.es.pdf', '.de.pdf', '.pdf']:
                            test_name = base_name + ext
                            h = hashlib.sha256(test_name.encode('utf-8')).hexdigest()
                            thumb_path = os.path.join(PROJECT_ROOT, 'thumbnails', f"{h}.jpg")
                            if os.path.exists(thumb_path):
                                cover_url = f"/thumbnails/{h}.jpg"
                                break
                            
                    grouped[group_title] = {
                        'is_grouped': True,
                        'base_name': base_name,
                        'parts': [],
                        'cover_url': cover_url
                    }
                grouped[group_title]['parts'].append({
                    'name': name,
                    'part_num': part_num,
                    'linkname': linkname,
                    'displayname': displayname,
                    'langs': get_available_langs(fullname)
                })
            else:
                # Standalone file or directory
                clean_name = displayname.replace('.htm', '').replace('_', ' ').replace('-', ' ').replace('/', '')
                clean_name = ' '.join(w.capitalize() for w in clean_name.split())
                
                base_name_sa = name if os.path.isdir(fullname) else os.path.splitext(name)[0]
                if not os.path.isdir(fullname):
                    base_name_sa = re.sub(r'\.\d+$', '', base_name_sa)
                cover_url = None
                for ext in ['.jpg', '.jpeg', '.png', '.webp', '.gif']:
                    if (base_name_sa.lower() + ext) in images:
                        cover_url = images[base_name_sa.lower() + ext]
                        break
                if not cover_url:
                    for ext in ['.en.pdf', '.es.pdf', '.de.pdf', '.pdf']:
                        test_name = base_name_sa + ext
                        h = hashlib.sha256(test_name.encode('utf-8')).hexdigest()
                        thumb_path = os.path.join(PROJECT_ROOT, 'thumbnails', f"{h}.jpg")
                        if os.path.exists(thumb_path):
                            cover_url = f"/thumbnails/{h}.jpg"
                            break
                        
                grouped[clean_name] = {
                    'is_grouped': False,
                    'name': name,
                    'linkname': linkname,
                    'displayname': displayname,
                    'is_dir': os.path.isdir(fullname),
                    'cover_url': cover_url,
                    'langs': get_available_langs(fullname)
                }

        # Convert groups with only 1 part to standalone to avoid unnecessary toggling
        for group_title in list(grouped.keys()):
            data = grouped[group_title]
            if data['is_grouped'] and len(data['parts']) == 1:
                part = data['parts'][0]
                grouped[group_title] = {
                    'is_grouped': False,
                    'name': part['name'],
                    'linkname': part['linkname'],
                    'displayname': part['displayname'],
                    'is_dir': False,
                    'cover_url': data['cover_url'],
                    'langs': part.get('langs', [])
                }

        # Calculate global languages
        all_present_langs = set()
        for g_title, data in grouped.items():
            if data['is_grouped']:
                g_langs = set()
                for p in data['parts']:
                    g_langs.update(p.get('langs', []))
                data['langs'] = list(g_langs)
            else:
                data['langs'] = data.get('langs', [])
            all_present_langs.update(data['langs'])
        
        if not all_present_langs:
            all_present_langs = {'es', 'en', 'de'} # Fallback
            
        langs_js_array = json.dumps(list(all_present_langs))
        
        # Inject dynamic languages into the JS script block using a trick since we already appended it
        for i, line in enumerate(r):
            if 'let langs = ["es", "en", "de"];' in line:
                r[i] = f'let langs = {langs_js_array};'
                break

        # Sort books alphabetically by pretty title
        sorted_titles = sorted(grouped.keys(), key=lambda x: x.lower())
        r.append('<ul>')
        for g_title in sorted_titles:
            data = grouped[g_title]
            r.append('<hr>')
            if data.get('cover_url'):
                r.append(f'    <img src="{urllib.parse.quote(data["cover_url"])}" alt="Portada de {html.escape(g_title)}" height="200" style="margin-right: 20px; object-fit: cover; width: 140px;">')
            else:
                generic_cover = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='200'><rect width='140' height='200' fill='%23f0f0f0' stroke='%23ccc' stroke-width='2'/><text x='50%25' y='50%25' font-size='60' text-anchor='middle' dominant-baseline='middle'>📘</text></svg>"
                r.append(f'    <img src="{generic_cover}" alt="Portada genérica" height="200" width="140" style="margin-right: 20px; object-fit: cover;">')
            
            langs_attr = ",".join(data.get('langs', []))
            r.append(f'  <li class="book-item" data-langs="{langs_attr}" style="display: flex; align-items: flex-start; margin-bottom: 20px;">')
            r.append('    <div>')
            tr = get_translated_titles(g_title)
            tr_attr = f'data-orig-title="{html.escape(g_title)}" data-title-es="{html.escape(tr["es"])}" data-title-en="{html.escape(tr["en"])}" data-title-de="{html.escape(tr["de"])}"'
            
            if data['is_grouped']:
                parts = sorted(data['parts'], key=lambda x: x['part_num'])
                r.append(f'    <strong class="book-title" {tr_attr}>{html.escape(g_title)}</strong>')
                r.append('    <ol>')
                for p in parts:
                    r.append(f'      <li><a class="book-link lang-text" href="{urllib.parse.quote(p["linkname"])}" data-lang-es="Ver Parte {p["part_num"]}" data-lang-en="Open Part {p["part_num"]}" data-lang-de="Teil {p["part_num"]} öffnen">Ver Parte {p["part_num"]}</a> | <a href="{urllib.parse.quote(p["linkname"])}?download=1" download="{html.escape(p["displayname"])}" class="lang-text" data-lang-es="Descargar" data-lang-en="Download" data-lang-de="Herunterladen">Descargar</a></li>')
                r.append('    </ol>')
            else:
                if data['is_dir']:
                    r.append(f'    <strong class="book-title" {tr_attr}>{html.escape(g_title)}</strong>: <a class="book-link lang-text" href="{urllib.parse.quote(data["linkname"])}" data-lang-es="Abrir Carpeta" data-lang-en="Open Folder" data-lang-de="Ordner öffnen">Abrir Carpeta</a>')
                else:
                    r.append(f'    <strong class="book-title" {tr_attr}>{html.escape(g_title)}</strong>: <a class="book-link lang-text" href="{urllib.parse.quote(data["linkname"])}" data-lang-es="Ver / Escuchar" data-lang-en="View / Listen" data-lang-de="Ansehen / Anhören">Ver / Escuchar</a> | <a href="{urllib.parse.quote(data["linkname"])}?download=1" download="{html.escape(data["displayname"])}" class="lang-text" data-lang-es="Descargar" data-lang-en="Download" data-lang-de="Herunterladen">Descargar</a>')
            r.append('    </div>')
            r.append('  </li>')
                
        r.append('</ul>')
        r.append('</body></html>')
        
        encoded = '\n'.join(r).encode(enc, 'surrogateescape')
        f = io.BytesIO()
        f.write(encoded)
        f.seek(0)
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=%s" % enc)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        return f

if __name__ == '__main__':
    port = int(os.environ.get('SERVER_PORT', 9090))
    directory = f"{PROJECT_ROOT}/htm+audio"
    
    # Soporte retro-compatible para el manejo del directorio
    if sys.version_info >= (3, 7):
        handler = functools.partial(CustomHandler, directory=directory)
    else:
        os.chdir(directory)
        handler = CustomHandler
    
    # Soporte compatible para versiones de Python antiguas (menores a 3.7)
    if hasattr(http.server, 'ThreadingHTTPServer'):
        server_class = http.server.ThreadingHTTPServer
    else:
        import socketserver
        class ThreadingHTTPServerFallback(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
        server_class = ThreadingHTTPServerFallback
        
    with server_class(("", port), handler) as httpd:
        print(f"Serving at port {port}")
        httpd.serve_forever()
