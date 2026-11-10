"""Keeps the Windows sources plain ASCII, so they compile the same on every PC whatever
its language settings. In C# files, other characters become \\uXXXX escapes (fine inside
ordinary string literals). Anything else that is not ASCII is reported.

    python3 desktop-windows/test/ascii.py          rewrite the C# files, check the rest
"""
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent.parent
bad = False
for path in sorted(here.rglob('*')):
    if path.suffix not in ('.cs', '.ps1') or 'build' in path.parts:
        continue
    text = path.read_text(encoding='utf-8')
    if text.isascii():
        continue
    if path.suffix == '.cs':
        fixed = ''.join(c if ord(c) < 128 else '\\u%04X' % ord(c) for c in text)
        path.write_text(fixed, encoding='ascii', newline='\n')
        print('escaped', path.name)
    else:
        bad = True
        for number, line in enumerate(text.splitlines(), 1):
            if not line.isascii():
                print('%s:%d is not ASCII: %s' % (path.name, number, line.strip()))
sys.exit(1 if bad else 0)
