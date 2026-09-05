#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
generar_htm_con_audios.py

Genera un visor htm offline interactivo HTML (con el PDF inyectado en Base64)
e inyecta soporte de audio sincronizado por página para inglés (en),
español (es) y alemán (de).
Soporta división automática de PDFs y audios si el tamaño excede los 450 MB.
"""

import sys
import os
import re
import json
import base64
import pdf_splitter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.environ.get('PORTABLE_ROOT', os.path.dirname(SCRIPT_DIR) if os.path.basename(SCRIPT_DIR) == 'scripting' else SCRIPT_DIR)

def get_book_name(pdf_path):
    base_name = os.path.basename(pdf_path)
    # Patrón: nombre_libro.<idioma>.pdf (ej: alices_abenteuer.en.pdf)
    match = re.search(r'\.([a-zA-Z]{2})\.pdf$', base_name, re.IGNORECASE)
    if match:
        return base_name[:match.start()]
    else:
        if base_name.lower().endswith('.pdf'):
            return base_name[:-4]
        return base_name

def generate_htm(template_content, pdf_base64, audio_map, filename, output_path):
    html = template_content
    
    # Leer el sonido de cambio de página y convertirlo a base64
    wav_path = f"{PROJECT_ROOT}/var/sonido-cambio-pagina.wav"
    if not os.path.exists(wav_path):
        wav_path = f"{PROJECT_ROOT}/sonido-cambio-pagina.wav"
    
    page_turn_sound_base64 = ""
    if os.path.exists(wav_path):
        import base64 as b64_module
        try:
            with open(wav_path, 'rb') as wf:
                wav_bytes = wf.read()
            page_turn_sound_base64 = f"data:audio/wav;base64,{b64_module.b64encode(wav_bytes).decode('utf-8')}"
        except Exception as e:
            print(f"Error cargando sonido-cambio-pagina.wav: {e}")

    # 1. Inyección de CSS para los botones de Audio
    css_to_inject = """
        /* Estilos Premium para Controles de Audio/Texto */
        .audio-controls {
            display: flex;
            flex-direction: column;
            align-items: stretch;
            width: 100%;
            gap: 0.5rem;
            margin-top: 0.5rem;
            margin-bottom: 0.5rem;
        }

        .audio-buttons-row {
            display: flex;
            flex-direction: row;
            justify-content: space-between;
            width: 100%;
            gap: 0.5rem;
        }

        .audio-btn {
            flex: 1;
            aspect-ratio: 1;
            justify-content: center;
            font-weight: bold;
            font-size: 1.1rem;
            padding: 10px;
            border: none;
            border-radius: 8px;
            background: #ffffff !important;
            color: var(--text-color);
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            display: flex;
            align-items: center;
            text-transform: lowercase;
        }

        .audio-btn:hover:not(:disabled) {
            background: var(--text-color);
            color: #ffffff;
        }

        .audio-btn:disabled {
            opacity: 0.25;
            cursor: not-allowed;
            border-style: none;
        }

        .audio-btn.playing {
            background: #e74c3c;
            color: white;
            border-color: #e74c3c;
            animation: pulse-ring 2s infinite;
        }

        @keyframes pulse-ring {
            0% { box-shadow: 0 0 0 0 rgba(231, 76, 60, 0.4); }
            70% { box-shadow: 0 0 0 6px rgba(231, 76, 60, 0); }
            100% { box-shadow: 0 0 0 0 rgba(231, 76, 60, 0); }
        }

        /* Autoplay Toggle Premium Switch */
        .autoplay-container {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: #ffffff;
            border-radius: 8px;
            padding: 8px 12px;
            font-weight: bold;
            font-size: 0.9rem;
            color: var(--text-color);
            margin-top: 0.25rem;
        }

        .switch {
            position: relative;
            display: inline-block;
            width: 44px;
            height: 24px;
        }

        .switch input {
            opacity: 0;
            width: 0;
            height: 0;
        }

        .slider {
            position: absolute;
            cursor: pointer;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background-color: #ccc;
            transition: .3s;
            border-radius: 24px;
        }

        .slider:before {
            position: absolute;
            content: "";
            height: 18px;
            width: 18px;
            left: 3px;
            bottom: 3px;
            background-color: white;
            transition: .3s;
            border-radius: 50%;
        }

        input:checked + .slider {
            background-color: #2ecc71;
        }

        input:checked + .slider:before {
            transform: translateX(20px);
        }
    """
    
    if "</style>" in html:
        html = html.replace("</style>", css_to_inject + "\n</style>", 1)

    # Determine languages that actually have audios in this part
    langs_with_audio = set()
    for page_num in audio_map:
        for lang in audio_map[page_num]:
            langs_with_audio.add(lang)

    # Inyección del HTML de los botones de audio
    html_to_inject = '\n            <div class="audio-controls">\n'
    html_to_inject += '                <div class="audio-buttons-row">\n'
    if "es" in langs_with_audio:
        html_to_inject += '                    <button id="play-es" class="audio-btn" disabled>es</button>\n'
    if "en" in langs_with_audio:
        html_to_inject += '                    <button id="play-en" class="audio-btn" disabled>en</button>\n'
    if "de" in langs_with_audio:
        html_to_inject += '                    <button id="play-de" class="audio-btn" disabled>de</button>\n'
    html_to_inject += '                </div>\n'
    html_to_inject += """                <div class="autoplay-container">
                    <span>💡 Manos Libres</span>
                    <label class="switch" title="Cambio automático de página al terminar audio">
                        <input type="checkbox" id="autoplay-toggle" checked>
                        <span class="slider"></span>
                    </label>
                </div>\n"""
    html_to_inject += '            </div>\n'

    if '<div class="zoom-controls">' in html:
        html = html.replace('<div class="zoom-controls">', html_to_inject + '\n            <div class="zoom-controls">', 1)

    # Configuración de nombre del archivo en la UI
    old_logic = """        const urlParams = new URLSearchParams(window.location.search);
        const fileName = urlParams.get('file');
        
        if (!fileName) {
            document.body.innerHTML = "<h1>Error: No se especificó un archivo PDF</h1>";
        } else {
            document.getElementById('filename').textContent = fileName;
            document.title = fileName;
        }"""
    
    new_logic = f"""        const fileName = "{filename}";
        document.getElementById('filename').textContent = fileName;
        document.title = fileName;"""
    
    if old_logic in html:
        html = html.replace(old_logic, new_logic)
    else:
        html = re.sub(r'const urlParams = new URLSearchParams\(window\.location\.search\);.*?document\.title = fileName;\s*\}', new_logic, html, flags=re.DOTALL)

    html = html.replace("pdfjsLib.getDocument(fileName)", "pdfjsLib.getDocument({data: pdfData})")

    # Inyectar pdfData Base64
    data_injection = f'\n        const pdfData = atob("{pdf_base64}");\n'
    insertion_point = "pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;"
    if insertion_point in html:
        html = html.replace(insertion_point, insertion_point + data_injection)
    else:
        html = html.replace("<script>\n        // Setup worker", "<script>\n" + data_injection + "        // Setup worker")

    # Inyectar Lógica de Reproducción de Audio y Estados en JavaScript
    js_to_inject = f"""
        // --- LOGICA DE REPRODUCCION DE AUDIO POR PAGINA ---
        const audioMap = {json.dumps(audio_map, indent=12)};
        let activeAudio = null;
        let activeLang = null;
        if (typeof pageTurnAudio === 'undefined' || !pageTurnAudio) {{
            const pageTurnSoundSrc = "{page_turn_sound_base64}";
            if (pageTurnSoundSrc) {{
                pageTurnAudio = new Audio(pageTurnSoundSrc);
            }}
        }}

        // Get requested lang from URL
        const urlParamsAudio = new URLSearchParams(window.location.search);
        const reqLang = urlParamsAudio.get('lang');
        const fallbackChain = [];
        if (reqLang) fallbackChain.push(reqLang.toLowerCase());
        ['es', 'en', 'de'].forEach(l => {{
            if (!fallbackChain.includes(l)) fallbackChain.push(l);
        }});

        function stopAllAudio() {{
            if (activeAudio) {{
                activeAudio.pause();
                activeAudio = null;
            }}
            const langs = ['en', 'es', 'de'];
            langs.forEach(l => {{
                const btn = document.getElementById('play-' + l);
                if (btn) {{
                    btn.textContent = l;
                    btn.classList.remove('playing');
                }}
            }});
            activeLang = null;
            const globalBtn = document.getElementById('global-play-btn');
            if (globalBtn) globalBtn.textContent = '>';
        }}

        function toggleAudio(lang) {{
            const pageAudioSrc = audioMap[pageNum] && audioMap[pageNum][lang];
            if (!pageAudioSrc) return;

            const btn = document.getElementById('play-' + lang);

            // Si ya se está reproduciendo el mismo idioma, lo detenemos
            if (activeAudio && activeLang === lang) {{
                stopAllAudio();
                return;
            }}

            // Detener cualquier audio previo
            if (activeAudio) {{
                stopAllAudio();
            }}

            // Crear y reproducir el nuevo audio en Base64 (desacoplado, usa el Data URI completo)
            activeAudio = new Audio(pageAudioSrc);
            activeLang = lang;
            
            // Put this lang at the top of the fallback chain so it persists on next pages
            const idx = fallbackChain.indexOf(lang);
            if (idx > -1) fallbackChain.splice(idx, 1);
            fallbackChain.unshift(lang);

            btn.textContent = lang;
            btn.classList.add('playing');
            
            const globalBtn = document.getElementById('global-play-btn');
            if (globalBtn) globalBtn.textContent = '||';

            activeAudio.play().catch(err => {{
                console.error("Error al reproducir audio:", err);
                stopAllAudio();
            }});

            // Ocultar menú al reproducir
            if (headerEl && showHeaderBtn) {{
                headerEl.style.display = 'none';
                showHeaderBtn.style.display = 'block';
                window.dispatchEvent(new Event('resize'));
            }}

            activeAudio.onended = () => {{
                stopAllAudio();
                
                const autoplayActive = document.getElementById('autoplay-toggle')?.checked;
                if (autoplayActive && pageNum < pdfDoc.numPages) {{
                    if (pageTurnAudio) {{
                        pageTurnAudio.play().catch(e => console.error("Error reproduciendo sonido de cambio:", e));
                        pageTurnAudio.onended = () => {{
                            onNextPage();
                        }};
                    }} else {{
                        onNextPage();
                    }}
                }}
            }};
        }}

        let isFirstLoad = true;

        function updateAudioButtons(num) {{
            stopAllAudio();
            const langs = ['en', 'es', 'de'];
            langs.forEach(lang => {{
                const btn = document.getElementById('play-' + lang);
                if (btn) {{
                    const hasAudio = audioMap[num] && audioMap[num][lang];
                    if (hasAudio) {{
                        btn.removeAttribute('disabled');
                        btn.textContent = lang;
                    }} else {{
                        btn.setAttribute('disabled', 'true');
                        btn.textContent = lang;
                    }}
                }}
            }});

            const autoplayActive = document.getElementById('autoplay-toggle')?.checked;
            
            if (isFirstLoad) {{
                if (autoplayActive) {{
                    if (!document.body.classList.contains('sano-mode')) {{
                        document.body.classList.add('sano-mode');
                        if (headerEl && headerEl.style.display !== 'none') {{
                            headerEl.style.display = 'none';
                            if (showHeaderBtn) showHeaderBtn.style.display = 'block';
                        }}
                    }}
                }}
                isFirstLoad = false;
            }}

            // Autoplay only if Sano Mode is currently active
            if (autoplayActive && document.body.classList.contains('sano-mode')) {{
                let played = false;
                for (let i = 0; i < fallbackChain.length; i++) {{
                    const l = fallbackChain[i];
                    if (audioMap[num] && audioMap[num][l]) {{
                        setTimeout(() => toggleAudio(l), 400);
                        played = true;
                        break;
                    }}
                }}
                
                if (!played && pageNum < pdfDoc.numPages) {{
                    if (pageTurnAudio) {{
                        pageTurnAudio.play().catch(e => console.error("Error reproduciendo sonido de cambio:", e));
                        pageTurnAudio.onended = () => {{
                            onNextPage();
                        }};
                    }} else {{
                        setTimeout(() => onNextPage(), 400);
                    }}
                }}
            }}
        }}

        // Enlace de Eventos
        const btnEn = document.getElementById('play-en');
        if (btnEn) btnEn.addEventListener('click', () => toggleAudio('en'));
        const btnEs = document.getElementById('play-es');
        if (btnEs) btnEs.addEventListener('click', () => toggleAudio('es'));
        const btnDe = document.getElementById('play-de');
        if (btnDe) btnDe.addEventListener('click', () => toggleAudio('de'));

        // Lógica de Mostrar/Ocultar Menú
        if (hideHeaderBtn && showHeaderBtn && headerEl) {{
            hideHeaderBtn.addEventListener('click', () => {{
                headerEl.style.display = 'none';
                showHeaderBtn.style.display = 'block';
                window.dispatchEvent(new Event('resize'));
            }});

            showHeaderBtn.addEventListener('click', () => {{
                headerEl.style.display = 'flex';
                showHeaderBtn.style.display = 'none';
                stopAllAudio();
                window.dispatchEvent(new Event('resize'));
            }});
        }}

        // Lógica Global Play Button
        setTimeout(() => {{
            const globalPlayBtn = document.getElementById('global-play-btn');
            if (globalPlayBtn) {{
                globalPlayBtn.addEventListener('click', () => {{
                    if (activeAudio) {{
                        if (activeAudio.paused) {{
                            activeAudio.play();
                            globalPlayBtn.textContent = '||';
                            const btn = document.getElementById('play-' + activeLang);
                            if (btn) btn.classList.add('playing');
                        }} else {{
                            activeAudio.pause();
                            globalPlayBtn.textContent = '>';
                            const btn = document.getElementById('play-' + activeLang);
                            if (btn) btn.classList.remove('playing');
                        }}
                    }} else {{
                        for (let i = 0; i < fallbackChain.length; i++) {{
                            const l = fallbackChain[i];
                            if (audioMap[pageNum] && audioMap[pageNum][l]) {{
                                toggleAudio(l);
                                break;
                            }}
                        }}
                    }}
                }});
            }}
        }}, 50);
    """

    # Inyectar el bloque de JS justo al final del bloque <script> principal
    html_global_play = """
    <button id="global-play-btn" title="Reproducir/Pausar" style="position: fixed; bottom: 20px; right: 20px; z-index: 10000; background: var(--toolbar-bg, white); border: 2px solid var(--border-color, #ccc); border-radius: 50%; width: 50px; height: 50px; font-weight: bold; font-size: 1.5rem; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 10px rgba(0,0,0,0.2); color: var(--text-color, black);">&gt;</button>
    """
    
    script_end = "</script>\n</body>"
    if script_end in html:
        html = html.replace(script_end, js_to_inject + f"\n    </script>\n{html_global_play}\n</body>", 1)
    else:
        html = html.replace("</body>", f"<script>{js_to_inject}</script>\n{html_global_play}\n</body>", 1)

    # Inyectar el hook en renderPage para actualizar botones al cambiar de página
    old_render_end = "if (pageNumEl) pageNumEl.value = num;"
    new_render_end = """if (pageNumEl) pageNumEl.value = num;
            if (typeof updateAudioButtons === 'function') {
                updateAudioButtons(num);
            }"""
    if old_render_end in html:
        html = html.replace(old_render_end, new_render_end, 1)

    # Guardar el HTM generado
    output_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(output_dir, exist_ok=True)
    
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f"[+] Visor htm generado con éxito en: {output_path}")

def main():
    if len(sys.argv) < 3:
        print("Uso: python3 generar_htm_con_audios.py <pdf_path> <output_path> [pdf_js_path] [worker_js_path]")
        sys.exit(1)

    pdf_path = sys.argv[1]
    output_path = sys.argv[2]
    
    template_path = f"{PROJECT_ROOT}/scripting/htm.htm"
    if not os.path.exists(template_path):
        print(f"Error: Template {template_path} no encontrado.")
        sys.exit(1)

    # 1. Leer y normalizar el template base
    print(f"[*] Leyendo el template: {template_path}")
    with open(template_path, 'r', encoding='utf-8') as f:
        template_content = f.read()
    template_content = template_content.replace('\r\n', '\n')

    filename = os.path.basename(pdf_path)
    book_name = get_book_name(pdf_path)
    print(f"[*] Nombre del libro identificado: '{book_name}'")

    # 2. Obtener número de páginas y audios
    print(f"[*] Analizando páginas del PDF...")
    total_pages = pdf_splitter.get_total_pages(pdf_path)
    print(f"[+] Páginas reales: {total_pages}")
    
    print(f"[*] Mapeando audios para '{book_name}'...")
    audio_sizes, audio_files = pdf_splitter.get_audio_sizes_for_book(book_name, total_pages)
    
    # 3. Determinar particionamiento
    dynamic_limit, unique_langs = pdf_splitter.get_dynamic_limit_for_book(book_name, total_pages)
    lang_str = ", ".join(sorted(unique_langs)) if unique_langs else "ninguno"
    print(f"[*] Idiomas con audio detectados: {lang_str}")
    
    # Determinar si el libro eventualmente requerirá ser particionado
    is_partitioned = pdf_splitter.will_require_partitioning(pdf_path, book_name, total_pages, dynamic_limit)
    
    # Encontrar la página máxima con audios para procesar solo hasta ahí incrementalmente
    max_audio_page = max(audio_files.keys()) if audio_files else total_pages
    
    print(f"[*] Evaluando si es necesario dividir el visor htm (Límite dinámico: {dynamic_limit / (1024*1024):.1f} MB)...")
    
    if is_partitioned:
        print(f"[!] ¡El libro requiere ser dividido en partes para no exceder los límites!")
        
        # Eliminar archivo monolítico antiguo si existe para evitar archivos huérfanos
        if os.path.exists(output_path):
            try:
                os.remove(output_path)
                print(f"[!] Eliminado archivo htm monolítico antiguo: {output_path}")
            except Exception as e:
                print(f"Error eliminando {output_path}: {e}")
                
        # Limpiar partes viejas (PDF y HTM)
        pdf_splitter.cleanup_old_parts(pdf_path)
        pdf_splitter.cleanup_old_htm_parts(output_path)
        
        # Obtener particionamiento para las páginas procesadas hasta ahora
        parts = pdf_splitter.partition_pdf(pdf_path, book_name, max_audio_page, audio_sizes, max_html_size=dynamic_limit)
        
        # Generar cada parte
        output_dir = os.path.dirname(output_path)
        output_base, _ = os.path.splitext(os.path.basename(output_path))
        
        for idx, (start, end) in enumerate(parts, 1):
            print(f"\n--- Procesando parte {idx}/{len(parts)} (Páginas {start}-{end}) ---")
            
            # 3a. Generar el PDF recortado
            part_pdf_path, part_suffix = pdf_splitter.split_pdf_file(pdf_path, start, end, idx, len(parts))
            if not part_pdf_path:
                print(f"[❌] Error al generar el PDF recortado para la parte {idx}. Abortando parte.")
                continue
            
            # 3b. Mapear y base64-codificar los audios de la parte (reindexados de 1 a N)
            print(f"[*] Codificando audios de la parte {idx} a Base64...")
            part_audio_map = {}
            for p in range(1, (end - start + 1) + 1):
                orig_page = start + p - 1
                if orig_page in audio_files:
                    for lang, file_path in audio_files[orig_page]:
                        with open(file_path, 'rb') as af:
                            audio_bytes = af.read()
                        audio_base64 = base64.b64encode(audio_bytes).decode('utf-8')
                        ext = file_path.split('.')[-1].lower()
                        mime_type = "audio/wav" if ext == "wav" else "audio/mp3"
                        
                        if p not in part_audio_map:
                            part_audio_map[p] = {}
                        part_audio_map[p][lang] = f"data:{mime_type};base64,{audio_base64}"
            
            # 3c. Codificar el PDF recortado a Base64
            print(f"[*] Codificando PDF de la parte {idx} a Base64...")
            with open(part_pdf_path, 'rb') as f:
                part_pdf_bytes = f.read()
            part_pdf_base64 = base64.b64encode(part_pdf_bytes).decode('utf-8')
            
            # 3d. Generar HTML final para esta parte
            part_output_name = f"{output_base}{part_suffix}.htm"
            part_output_path = os.path.join(output_dir, part_output_name)
            part_filename = os.path.basename(part_pdf_path)
            
            generate_htm(template_content, part_pdf_base64, part_audio_map, part_filename, part_output_path)
            
    else:
        # Modo de archivo único convencional
        print("[+] El visor htm cabe en un único archivo. Generando de forma convencional...")
        
        # Mapear y codificar audios
        print("[*] Codificando todos los audios a Base64...")
        audio_map = {}
        for page_num in audio_files:
            for lang, file_path in audio_files[page_num]:
                with open(file_path, 'rb') as af:
                    audio_bytes = af.read()
                audio_base64 = base64.b64encode(audio_bytes).decode('utf-8')
                ext = file_path.split('.')[-1].lower()
                mime_type = "audio/wav" if ext == "wav" else "audio/mp3"
                
                if page_num not in audio_map:
                    audio_map[page_num] = {}
                audio_map[page_num][lang] = f"data:{mime_type};base64,{audio_base64}"
                
        # Codificar el PDF original a Base64
        print("[*] Codificando PDF original a Base64...")
        with open(pdf_path, 'rb') as f:
            pdf_bytes = f.read()
        pdf_base64 = base64.b64encode(pdf_bytes).decode('utf-8')
        
        generate_htm(template_content, pdf_base64, audio_map, filename, output_path)

if __name__ == "__main__":
    main()
