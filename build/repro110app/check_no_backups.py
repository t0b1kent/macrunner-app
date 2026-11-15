#!/usr/bin/env python3 -I
"""INTEGRATE111 gate (curator 07.11 night): zero backup copies inside any lib/wine tree of an engine / package / floor
(names *.BYLO*, *БЫЛО*, *.bak, *.orig; NFC and NFD forms). Bottle update copies lib/wine whole, so a backup next to a module can be
registered instead of it (DSNATIVE: mmdevapi.dll.BYLO-181805 as the COM server). Exit 0 = none; 1 = found (listed).
usage: check_no_backups.py <dir>...   (each dir scanned recursively; matches anywhere are listed, those under lib/wine fail)"""
import os, sys, unicodedata
bad_total = 0
def is_backup(n):
    for f in (unicodedata.normalize('NFC', n), unicodedata.normalize('NFD', n)):
        u = f.upper()
        if '.BYLO' in u or unicodedata.normalize('NFC', 'БЫЛО') in unicodedata.normalize('NFC', f).upper() or u.endswith('.BAK') or u.endswith('.ORIG'):
            return True
    return False
for root in sys.argv[1:]:
    libwine = other = 0; hits = []
    for dp, dn, fn in os.walk(root, followlinks=False):
        for n in fn + dn:
            if is_backup(n):
                p = os.path.join(dp, n)
                if '/lib/wine' in p: libwine += 1; hits.append(p)
                else: other += 1
    bad_total += libwine
    print(f'{"PASS" if libwine == 0 else "FAIL"} {root}: backups under lib/wine {libwine}, elsewhere {other}')
    for h in hits[:20]: print('   ', h)
sys.exit(1 if bad_total else 0)
