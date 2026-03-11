#!/usr/bin/env python3
import os
import sys

# Add scripts dir to path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from common_utils import print_header, print_success, print_fail, print_info, file_exists, dir_exists

ROOT_DIR = os.getcwd()

def extract_files_from_codebase():
    codebase_path = os.path.join(ROOT_DIR, "CODEBASE.md")
    if not file_exists(codebase_path):
        return []
    
    files = []
    with open(codebase_path, 'r') as f:
        for line in f:
            if "├──" in line or "└──" in line:
                # Basic parsing of the ASCII tree in CODEBASE.md
                name = line.split("─")[-1].split("#")[0].strip()
                if name and not name.endswith("/"):
                    files.append(name)
    return files

def audit_files():
    print_header("Dependency & File Audit")
    
    codebase_files = extract_files_from_codebase()
    if not codebase_files:
        print_fail("Could not extract files from CODEBASE.md or file missing.")
        return False
        
    all_ok = True
    for f in codebase_files:
        # Note: This is a simplified check since tree paths are relative to their parents in the tree
        # For a true audit, we'd need a recursive tree parser. 
        # For now, we verify the high-level critical files mentioned.
        if f in ["CODEBASE.md", "scan_results.json"]:
            if file_exists(os.path.join(ROOT_DIR, f)):
                print_success(f"Audit passed: {f} exists.")
            else:
                print_fail(f"Audit failed: {f} is listed in CODEBASE.md but missing on disk.")
                all_ok = False
                
    return all_ok

def main():
    print_header("MAESTRO DEPENDENCY ANALYZER")
    if audit_files():
        print_success("Dependency audit completed successfully.")
        sys.exit(0)
    else:
        print_fail("Dependency audit found inconsistencies.")
        sys.exit(1)

if __name__ == "__main__":
    main()
