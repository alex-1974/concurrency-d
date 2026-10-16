#!/usr/bin/env python3
"""Generate a P35-only observation copy from the exact P23 owner."""
from pathlib import Path
import subprocess
import sys

def main():
    root, p23, p35 = map(Path, sys.argv[1:4])
    subprocess.run([sys.executable, str(root / 'tools/research/m1_p23_make_owned.py'),
                    str(root / 'source/concurrency/internal/owned_task.d'), str(p23)],check=True)
    text = p23.read_text()
    text = text.replace('module concurrency.research.m1_p23_owned;',
                        'module concurrency.research.m1_p35_owned;')
    p35.parent.mkdir(parents=True,exist_ok=True)
    p35.write_text(text)
    print('P35_OWNER_OVERLAY_PIN_PASS')

if __name__ == '__main__':
    main()
