import os
import sys
import re

if len(sys.argv) < 2:
    print("Usage: patch_workspace_paths.py <project_dir>")
    sys.exit(1)

project_dir = os.path.abspath(sys.argv[1])

def get_old_project_dir(p_dir):
    # Try to extract the old path from the stable apertium.pc file
    pc_path = os.path.join(p_dir, 'portable-bin-for-rocky-linux-8-PATH', 'lib', 'pkgconfig', 'apertium.pc')
    if os.path.exists(pc_path):
        try:
            with open(pc_path, 'r', encoding='utf-8') as f:
                for line in f:
                    if line.startswith('prefix='):
                        path = line.strip().split('=')[1]
                        suffix = '/portable-bin-for-rocky-linux-8-PATH'
                        if path.endswith(suffix):
                            return path[:-len(suffix)]
        except Exception:
            pass
            
    # Try alternative modes files from any portable-bin directory
    for folder in ['portable-bin-for-gentoo-2026-PATH', 'portable-bin-for-rocky-linux-8-PATH']:
        modes_dir = os.path.join(p_dir, folder, 'share', 'apertium', 'modes')
        if os.path.exists(modes_dir):
            for file in os.listdir(modes_dir):
                if file.endswith('.mode'):
                    filepath = os.path.join(modes_dir, file)
                    try:
                        with open(filepath, 'r', encoding='utf-8') as f:
                            c = f.read()
                            match = re.search(r"'(/home/user/[^']+?)/portable-bin-", c)
                            if match:
                                return match.group(1)
                    except Exception:
                        pass
    return None

old_project_dir = get_old_project_dir(project_dir)

if old_project_dir:
    print(f"[Auto-Patch] Detected old project directory: {old_project_dir}")
    # Replace the old project dir path exactly
    pattern = re.compile(re.escape(old_project_dir))
else:
    # Safe fallback regex if old path cannot be resolved from files
    print("[Auto-Patch] Could not detect old directory from files, using fallback pattern")
    pattern = re.compile(r'/home/user/Libros(?:-[a-zA-Z0-9_-]+)?')

def is_binary(filepath):
    # Check if a file is binary by looking for null bytes in the first 8000 bytes
    try:
        with open(filepath, 'rb') as f:
            chunk = f.read(8000)
            return b'\x00' in chunk
    except Exception:
        return True

def process_file(filepath):
    if is_binary(filepath):
        return
        
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            
        new_content = pattern.sub(project_dir, content)
        
        if new_content != content:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
            print(f"[Auto-Patch] Updated paths in: {os.path.relpath(filepath, project_dir)}")
    except Exception as e:
        print(f"[Auto-Patch] Error processing {filepath}: {e}")

if old_project_dir == project_dir:
    print("[Auto-Patch] No path changes needed (current directory matches previous run).")
else:
    # Walk through all directories in the project
    for root, dirs, files in os.walk(project_dir):
        # Exclude git directory and temporary files
        if '.git' in root or 'var' in root:
            continue
        for file in files:
            filepath = os.path.join(root, file)
            # Avoid patching ourselves
            if file == 'patch_workspace_paths.py':
                continue
            process_file(filepath)
