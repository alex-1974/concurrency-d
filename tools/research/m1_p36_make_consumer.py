#!/usr/bin/env python3
"""P36 research-only consumer derived from source-pinned P35 consumer."""
from pathlib import Path
import subprocess
import sys


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('P36 consumer drift: ' + before[:64])
    return text.replace(before, after, 1)


def main():
    root, source, target = map(Path, sys.argv[1:4])
    intermediate = target.with_suffix('.p35.tmp')
    try:
        subprocess.run([sys.executable, str(root/'tools/research/m1_p35_make_consumer.py'),
                        str(source), str(intermediate)], check=True)
        text = intermediate.read_text()
    finally:
        intermediate.unlink(missing_ok=True)
    text = once(text, 'module concurrency.research.p35_generational_owner;',
                'module concurrency.research.p36_generational_owner;')
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(text)
    print('P36_CONSUMER_PIN_PASS')

if __name__ == '__main__':
    main()
