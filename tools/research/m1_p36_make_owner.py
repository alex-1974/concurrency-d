#!/usr/bin/env python3
"""P36: generate a source-pinned owned critical-phase probe."""
from pathlib import Path
import subprocess
import sys

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('P36 source anchor drift: ' + old[:64])
    return text.replace(old, new, 1)

def main():
    root, p23, p36 = map(Path, sys.argv[1:4])
    subprocess.run([sys.executable, str(root/'tools/research/m1_p23_make_owned.py'),
                    str(root/'source/concurrency/internal/owned_task.d'),str(p23)],check=True)
    text = p23.read_text()
    text = replace_once(text,'module concurrency.research.m1_p23_owned;',
                       'module concurrency.research.m1_p36_owned;')
    p36.parent.mkdir(parents=True,exist_ok=True)
    p36.write_text(text)
    print('P36_OWNER_SOURCE_PIN_PASS')

if __name__ == '__main__':
    main()
