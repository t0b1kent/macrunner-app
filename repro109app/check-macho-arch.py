#!/usr/bin/env python3
"""check-macho-arch.py — в пакете не должно быть родных (Mach-O) файлов без среза arm64.

Зачем (куратор, 06.10.2026): в этот день владелец поставил Rosetta 2, чтобы мерить эталоны (CrossOver). До этого любой
случайный x86_64 Mach-O в нашем дереве падал громко («Bad CPU type in executable»), и это было бесплатными воротами.
Теперь такой файл молча исполнится через Rosetta на машине разработки — и не запустится у пользователя, у которого
Rosetta нет (а «без Rosetta» — свойство продукта). Проверка читает только заголовки файлов, ничего не исполняет.

  check-macho-arch.py <каталог|файл> [...]        печатает сводку и каждый негодный файл
  check-macho-arch.py --list <каталог>            дополнительно печатает все Mach-O с их срезами

Код 0 — все Mach-O несут arm64 (или arm64e); 1 — есть файл без arm64; 2 — нечего проверять или ошибка аргументов.
Файлы PE (MZ) и всё прочее не рассматриваются: гостевые модули Windows — не предмет этой проверки.
"""
import os
import struct
import sys

CPU = {0x01000007: 'x86_64', 0x00000007: 'i386', 0x0100000C: 'arm64', 0x0200000C: 'arm64_32', 0x0000000C: 'arm'}
THIN = {b'\xcf\xfa\xed\xfe': '<', b'\xce\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>', b'\xfe\xed\xfa\xce': '>'}


def slices(path):
    """Срезы Mach-O файла: список имён архитектур; None — не Mach-O."""
    try:
        with open(path, 'rb') as f:
            head = f.read(4096)
    except OSError:
        return None
    if len(head) < 8:
        return None
    magic = head[:4]
    if magic in THIN:
        cputype = struct.unpack(THIN[magic] + 'I', head[4:8])[0]
        return [CPU.get(cputype, hex(cputype))]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack('>I', head[4:8])[0]
        # Файлы классов Java начинаются теми же четырьмя байтами; у них на месте счётчика версия (45 и больше).
        if not 1 <= count <= 8:
            return None
        step = 20 if magic.endswith(b'\xbe') else 32
        if 8 + count * step > len(head):
            return None
        found = []
        for index in range(count):
            cputype = struct.unpack('>I', head[8 + index * step:12 + index * step])[0]
            if cputype not in CPU:
                return None
            found.append(CPU[cputype])
        return found
    return None


def walk(root):
    if os.path.isfile(root):
        yield root
        return
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(base, name)
            if not os.path.islink(path):
                yield path


def main():
    args = sys.argv[1:]
    listing = '--list' in args
    roots = [a for a in args if a != '--list']
    if not roots:
        print(__doc__)
        return 2
    total = 0
    bad = []
    kinds = {}
    for root in roots:
        if not os.path.exists(root):
            print(f'нет пути: {root}')
            return 2
        for path in walk(root):
            found = slices(path)
            if found is None:
                continue
            total += 1
            key = '+'.join(found)
            kinds[key] = kinds.get(key, 0) + 1
            if listing:
                print(f'{key}\t{path}')
            if not any(arch.startswith('arm64') and arch != 'arm64_32' for arch in found):
                bad.append((key, path))
    if total == 0:
        print('Mach-O не найдено — проверять нечего (путь верный?)')
        return 2
    summary = ', '.join(f'{name}: {count}' for name, count in sorted(kinds.items()))
    print(f'Mach-O файлов: {total} ({summary})')
    for key, path in bad:
        print(f'БЕЗ arm64 [{key}]: {path}')
    if bad:
        print(f'ОТКАЗ: {len(bad)} файл(ов) без среза arm64 — у пользователя без Rosetta не запустятся')
        return 1
    print('ЧИСТО: каждый Mach-O несёт arm64')
    return 0


if __name__ == '__main__':
    sys.exit(main())
