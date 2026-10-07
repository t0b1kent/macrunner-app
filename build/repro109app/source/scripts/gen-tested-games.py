#!/usr/bin/env python3
"""Generate bundled result history from TESTED_GAMES.md; routing stays separate.

The public repository should publish this same Markdown file. Do not edit known
results in graphics-profiles.json: build/CI checks fail on any generated drift.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import re

APP = Path(__file__).resolve().parents[1]
RESOURCE = APP / 'Sources/MacRunnerControlCenter/Resources/graphics-profiles.json'
IDS = {
    'Hollow Knight': 'hollow-knight', 'Divinity: Original Sin — Enhanced Edition': 'divinity-os-ee',
    'Factorio': 'factorio', 'Vampire Survivors': 'vampire-survivors',
    'Hedon Bloodrite': 'hedon', 'Hedon Bloodrite 2.4.2': 'hedon', 'DOOM 64': 'doom-64',
    'Ion Fury': 'ion-fury', 'Dome Keeper': 'dome-keeper', 'WRATH: Aeon of Ruin': 'wrath',
}
NEW_ROUTES = [
    dict(id='vampire-survivors', name='Vampire Survivors', exe=['VampireSurvivors.exe'], apis=['d3d11']),
    dict(id='doom-64', name='DOOM 64', exe=['DOOM64_x64.exe'], apis=['opengl']),
    dict(id='dome-keeper', name='Dome Keeper', exe=['Dome Keeper.exe', 'DomeKeeper.exe'], apis=['opengl']),
    dict(id='heroes-iii', name='Heroes III', exe=['Heroes3.exe'], apis=[]),
]
NEW_ROUTES += json.loads((APP/'Sources/MacRunnerControlCenter/Resources/indiana-profile.json').read_text())['profiles']

def plain(s):
    return re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', s.replace('**', '')).strip()

def date(s):
    return dt.datetime.strptime(plain(s), '%B %d, %Y').date().isoformat()

def tables(text):
    section = ''
    header = None
    for line in text.splitlines():
        if line.startswith('## '): section, header = line[3:], None
        if not line.startswith('|'): continue
        cells = [plain(x) for x in line.strip('|').split('|')]
        if all(re.fullmatch(r'[-: ]+', x) for x in cells): continue
        if header is None: header = cells; continue
        if len(header) != len(cells): raise ValueError('Malformed table in '+section)
        yield section, dict(zip(header, cells))

def record(day, reached, engine, note, evidence):
    return dict(date=day, reached=reached, engine=engine, displayEngine=engine, note=note, evidence=evidence)

def generate(text, routes):
    history = {}
    release_seen = set()
    source = 'TESTED_GAMES.md'
    for section, row in tables(text):
        game = row.get('Game')
        if game not in IDS: continue
        key = IDS[game]
        if 'What was verified' in row or 'Confirmed result' in row:
            observed = row.get('What was verified', row.get('Confirmed result'))
            limit = row.get('Remaining limits', row.get('Still to verify'))
            history.setdefault(key, []).append(record(date(row['Check date']), 'gameplay',
                'Historical FEX + Wine · '+row['Graphics path'],
                observed+' Limits: '+limit+' FPS: '+row['FPS']+'.', source+'#'+section))
        elif 'Checked in 1.0.7' in row:
            observed = row['Checked in 1.0.7']
            if observed.startswith('Not rechecked'): reached = 'notRechecked'
            elif 'main menu' in observed.lower() or 'Main menu' in observed: reached = 'menu'
            elif any(x in observed for x in ['intro', 'Loading screen', 'Language selection']): reached = 'window'
            else: raise ValueError('Unclassified release observation: '+observed)
            history.setdefault(key, []).append(record('2026-10-03', reached,
                'MacRunner 1.0.7 · startup/menu check', observed+' Still to check: '+row['Still to check']+
                ' FPS from one screenshot: '+row['FPS from one screenshot']+'.', source+'#'+section))
            release_seen.add(key)
    if release_seen != set(IDS.values()): raise ValueError('Missing or changed 1.0.7 game table')
    # This title has a dedicated prose section, rather than a table row.
    section = text.split('## Elden Ring — tested & working\n', 1)[1].split('\n## ', 1)[0]
    if 'September 23, 2026' not in section or 'Tested & working — DirectX 12' not in section:
        raise ValueError('Elden Ring section changed; review its classification')
    history['elden-ring'] = [record('2026-09-23', 'gameplay',
        'Historical FEX + Wine · DXMT-based DirectX 12 development', plain(section),
        source+'#Elden Ring — tested & working')]
    heroes = re.search(r'^Heroes III also reached.*$', text, re.M)
    if heroes is None: raise ValueError('Heroes III release observation missing')
    history['heroes-iii'] = [record('2026-10-03', 'menu', 'MacRunner 1.0.7 · 32-bit startup check',
        plain(heroes.group()), source+'#MacRunner 1.0.7 · October 3 checks')]
    indiana = text.split('## Indiana Jones — 1.0.6-indiana experimental preview\n', 1)[1].split('\n## ', 1)[0]
    history['indiana-jones-great-circle'] = [record('2026-10-01', 'window',
        'MacRunner 1.0.6-indiana · separate experimental preview', plain(indiana),
        source+'#Indiana Jones — 1.0.6-indiana experimental preview')]
    for sec, row in tables(text):
        if sec == 'Release checks since 1.0.3' and row.get('Build and date', '').startswith('1.0.5,'):
            if 'ABZU' not in row['Observed result'] or 'menus' not in row['Observed result']:
                raise ValueError('ABZU release check changed')
            history['abzu'] = [record('2026-09-30', 'menu', 'MacRunner 1.0.5 · menu check',
                row['Observed result']+' Limits: '+row['Limit'], source+'#'+sec),
                record('2026-10-03', 'notRechecked', 'MacRunner 1.0.7',
                'Not listed among the October 3 release checks; the earlier menu result remains historical.',
                source+'#MacRunner 1.0.7 · October 3 checks')]
    result = copy.deepcopy(routes)
    for profile in NEW_ROUTES:
        if not any(x['id'] == profile['id'] for x in result['profiles']):
            result['profiles'].append(dict(profile, evidence=source+'#Game engines & test coverage'))
    for profile in result['profiles']:
        profile.pop('known', None)
        if profile['id'] in history:
            profile['known'] = sorted(history[profile['id']], key=lambda x: x['date'])
    result['testedGamesSource'] = dict(path='TESTED_GAMES.md', sha256=hashlib.sha256(text.encode()).hexdigest())
    result['note'] = 'Generated by scripts/gen-tested-games.py. Results come only from TESTED_GAMES.md; launch routing comes from graphics-profile-routes.json. Historical checks do not certify the current release.'
    return result

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, default=APP/'TESTED_GAMES.md')
    p.add_argument('--check', action='store_true')
    args = p.parse_args()
    output = json.dumps(generate(args.source.read_text(), json.loads((APP/'graphics-profile-routes.json').read_text())), ensure_ascii=False, indent=2)+'\n'
    if args.check:
        if not RESOURCE.exists() or RESOURCE.read_text() != output: p.exit(1, 'Bundled game results drifted: run scripts/gen-tested-games.py\n')
    else: RESOURCE.write_text(output)
    print('TESTED_GAMES → graphics-profiles: synchronized')

if __name__ == '__main__': main()
