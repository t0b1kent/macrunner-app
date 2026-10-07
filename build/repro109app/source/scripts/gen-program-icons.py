#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Собирает набор фирменных значков для каталога программ MacRunner.

Источник — Simple Icons (CC0): официальная ФОРМА знака и официальный ЦВЕТ бренда
(поле `hex` в data/simple-icons.json). Ни сети в рантайме, ни посредников: значки
кладутся в ресурсы приложения, соответствие — в program-icons.json.

Что делает:
  1. находит (или скачивает в /tmp) набор simple-icons;
  2. строит указатель «нормализованное имя -> slug + hex» по title/aka/old/loc;
  3. сопоставляет с нашими программами из programs-catalog.json;
  4. копирует ТОЛЬКО нужные icons/<slug>.svg в Resources/program-icons/;
  5. пишет Resources/program-icons.json;
  6. гоняет свои проверки (положительный и отрицательный контроль, hex, файлы).

Запуск:
    python3 scripts/gen-program-icons.py                 # скачает набор при нужде
    python3 scripts/gen-program-icons.py --simple-icons <распакованный simple-icons>
    python3 scripts/gen-program-icons.py --check         # ничего не писать, только проверить

Правила, из-за которых здесь много ручного разбора:
  * знак ИЗДАТЕЛЯ вместо знака ПРОГРАММЫ не ставим (Autodesk на строке Civil 3D врёт
    хуже монограммы) — см. PUBLISHER_ONLY / ALLOW_VENDOR_MARK;
  * похожий slug не подставляем: нет знака — строка остаётся с монограммой;
  * `aliases.dup` из Simple Icons НЕ используется: у dup нет своего файла, глиф
    родительский (например «SolidWorks» нарисован знаком Dassault Systemes).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import unicodedata
import urllib.request
import zipfile

# ---------------------------------------------------------------- пути

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)                                  # .../macr-control-center
RES = os.path.join(APP, "Sources", "MacRunnerControlCenter", "Resources")
CATALOG = os.path.join(RES, "programs-catalog.json")
OUT_JSON = os.path.join(RES, "program-icons.json")
OUT_DIR = os.path.join(RES, "program-icons")

SI_URL = "https://github.com/simple-icons/simple-icons/archive/refs/heads/master.zip"
SI_TMP = "/tmp/macrunner-simple-icons"

FORMAT_VERSION = 1

# ---------------------------------------------------------------- тёмный знак

# Интерфейс у нас чёрный. Порог: яркость знака ниже яркости #202020 (по WCAG,
# относительная светимость). В долях это L < 0.01446, то есть контраст к чистому
# чёрному ниже 1.29:1 — такой знак на нашем фоне не виден, витрина обязана
# перекрасить его в светлый.
DARK_REF_HEX = "202020"


def luminance(hex6: str) -> float:
    """Относительная светимость по WCAG 2.1 (0 — чёрный, 1 — белый)."""
    def chan(v: int) -> float:
        s = v / 255.0
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4
    r = chan(int(hex6[0:2], 16))
    g = chan(int(hex6[2:4], 16))
    b = chan(int(hex6[4:6], 16))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


DARK_THRESHOLD = luminance(DARK_REF_HEX)


def contrast_on_black(hex6: str) -> float:
    return (luminance(hex6) + 0.05) / 0.05


# ---------------------------------------------------------------- slug и нормализация

# Порт titleToSlug из simple-icons/sdk.mjs — slug в наборе вычисляется из title,
# а поле "slug" в данных стоит только там, где обычное правило даёт коллизию.
SLUG_REPLACEMENTS = {
    "+": "plus", ".": "dot", "&": "and", "đ": "d", "ħ": "h", "ı": "i",
    "ĸ": "k", "ŀ": "l", "ł": "l", "ß": "ss", "ŧ": "t", "ø": "o",
}


def si_slug(title: str) -> str:
    s = title.lower()
    s = "".join(SLUG_REPLACEMENTS.get(c, c) for c in s)
    s = unicodedata.normalize("NFD", s)
    return re.sub(r"[^a-z0-9]", "", s)


def norm(name: str) -> str:
    """Ключ сопоставления: без пробелов, точек, дефисов, в нижнем регистре."""
    s = unicodedata.normalize("NFD", name.lower())
    return re.sub(r"[^a-z0-9]", "", s)


# ---------------------------------------------------------------- ручной разбор

# Наше имя программы -> slug Simple Icons. Только там, где имена не совпадают
# буквально, а знак ТОТ ЖЕ САМЫЙ (тот же продукт под другим названием).
MANUAL = {
    "videolan.vlc":                 ("vlcmediaplayer", "у них название «VLC media player»"),
    "mozilla.firefox":              ("firefox",        "у них без издателя: «Firefox»"),
    "mozilla.thunderbird":          ("thunderbird",    "у них без издателя: «Thunderbird»"),
    "mcneel.rhino":                 ("rhinoceros",     "Rhino = Rhinoceros 3D, один продукт"),
    "autodesk.revit":               ("autodeskrevit",  "у них с издателем: «Autodesk Revit»"),
    "autodesk.autocadlt":           ("autocad",        "LT — облегчённая редакция AutoCAD, знак тот же"),
    "magix.vegaspro":               ("vegas",          "VEGAS — марка продукта, MAGIX — издатель"),
    # Марка вендора И ЕСТЬ значок приложения (см. ALLOW_VENDOR_MARK ниже).
    "docker.dockerdesktop":         ("docker",         "Docker Desktop носит знак-кита Docker"),
    "epicgames.epicgameslauncher":  ("epicgames",      "у лончера собственного знака нет, стоит знак Epic"),
    "gog.galaxy":                   ("gogdotcom",      "GOG Galaxy носит знак GOG"),
    "rockstargames.launcher":       ("rockstargames",  "лончер носит знак Rockstar"),
}

# Знаки, которые в Simple Icons есть, но это марка ИЗДАТЕЛЯ, а не программы.
# Автосопоставление их не берёт никогда; ручное — только через ALLOW_VENDOR_MARK.
PUBLISHER_ONLY = {
    "autodesk": "издатель Autodesk (Civil 3D, Fusion, EAGLE, 3ds Max, Inventor, Navisworks…)",
    "siemens": "издатель Siemens (NX, Solid Edge, JT2Go)",
    "bentley": "издатель Bentley (STAAD.Pro, PLAXIS)",
    "dassaultsystemes": "издатель Dassault (SolidWorks, Abaqus)",
    "trimble": "издатель Trimble (Tekla Structures, SketchUp)",
    "jetbrains": "издатель JetBrains (dotPeek, dotTrace, dotUltimate)",
    "stardock": "издатель Stardock (Fences, Start11, Groupy)",
    "veeam": "издатель Veeam (Agent for Windows)",
    "malwarebytes": "издатель Malwarebytes (AdwCleaner)",
    "msi": "издатель MSI (Afterburner — свой знак, не дракон MSI)",
    "coreldraw": "другая программа Corel, не PaintShop Pro",
    "epicgames": "марка Epic Games",
    "gogdotcom": "марка GOG",
    "rockstargames": "марка Rockstar Games",
    "docker": "марка Docker",
}

# Поимённое разрешение: здесь марка вендора и есть значок этой программы.
ALLOW_VENDOR_MARK = {
    ("docker.dockerdesktop", "docker"),
    ("epicgames.epicgameslauncher", "epicgames"),
    ("gog.galaxy", "gogdotcom"),
    ("rockstargames.launcher", "rockstargames"),
}

# Положительный контроль указателя: эти имена ОБЯЗАНЫ найтись по имени.
# NB: «VLC» в наборе называется «VLC media player» — по короткому имени его НЕТ,
# и он приходит через MANUAL. Поэтому контроль двухступенчатый: указатель и итог.
POSITIVE_CONTROL = ["Notepad++", "7-Zip", "Blender", "Krita", "VLC media player",
                    "FileZilla", "Git", "Inkscape"]
# Имена, которых в Simple Icons НЕТ ВОВСЕ (владельцы требуют удаления знаков).
# Сопоставление обязано отвечать «нет», а не подставлять похожее.
NEGATIVE_CONTROL = ["Несуществующая Программа", "PuTTY", "WinSCP",
                    "Microsoft Word", "Adobe Photoshop", "Slack", "VLC"]

# Сквозной контроль итога: у этих наших записей значок ОБЯЗАН оказаться...
POSITIVE_CONTROL_IDS = ["notepadplusplus.notepadplusplus", "sevenzip.sevenzip",
                        "blender.blender", "kde.krita", "videolan.vlc",
                        "filezilla.client", "mozilla.firefox", "mcneel.rhino",
                        "docker.dockerdesktop"]
# ...а у этих ОБЯЗАН отсутствовать: знака нет вовсе либо есть только знак издателя.
NEGATIVE_CONTROL_IDS = ["putty.putty", "winscp.winscp", "microsoft.word",
                        "adobe.photoshop", "autodesk.civil3d",
                        "dassault.solidworks", "jetbrains.dotpeek"]


# ---------------------------------------------------------------- набор simple-icons

def ensure_simple_icons(explicit: str | None) -> str:
    if explicit:
        root = os.path.abspath(explicit)
        if not os.path.isfile(os.path.join(root, "data", "simple-icons.json")):
            sys.exit("нет data/simple-icons.json в %s" % root)
        return root
    # уже распакован рядом?
    for cand in (SI_TMP, os.path.join(SI_TMP, "simple-icons-master")):
        if os.path.isfile(os.path.join(cand, "data", "simple-icons.json")):
            return cand
    os.makedirs(SI_TMP, exist_ok=True)
    zpath = os.path.join(SI_TMP, "master.zip")
    if not os.path.isfile(zpath):
        print("скачиваю набор Simple Icons -> %s" % zpath)
        urllib.request.urlretrieve(SI_URL, zpath)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(SI_TMP)
    root = os.path.join(SI_TMP, "simple-icons-master")
    if not os.path.isfile(os.path.join(root, "data", "simple-icons.json")):
        sys.exit("распаковка не дала data/simple-icons.json")
    return root


def build_index(si_root: str):
    """нормализованное имя -> (slug, hex, вид ключа, title)."""
    items = json.load(open(os.path.join(si_root, "data", "simple-icons.json")))
    index: dict[str, tuple[str, str, str, str]] = {}
    for x in items:
        slug = x.get("slug") or si_slug(x["title"])
        hexv = x["hex"].upper()
        al = x.get("aliases") or {}
        names = [(x["title"], "title")]
        names += [(a, "aka") for a in al.get("aka", [])]
        names += [(a, "old") for a in al.get("old", [])]
        names += [(a, "loc") for a in (al.get("loc") or {}).values()]
        # aliases.dup сознательно пропущен: своего файла у dup нет, глиф родительский
        for nm, kind in names:
            k = norm(nm)
            if not k:
                continue
            cur = index.get(k)
            if cur is None or (cur[2] != "title" and kind == "title"):
                index[k] = (slug, hexv, kind, x["title"])
    return items, index


def lookup(index, name: str):
    """Строгое сопоставление по нормализованному имени. Похожих не подбираем."""
    return index.get(norm(name))


# ---------------------------------------------------------------- основная работа

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--simple-icons", default=os.environ.get("SIMPLE_ICONS_DIR"))
    ap.add_argument("--check", action="store_true", help="ничего не писать")
    args = ap.parse_args()

    si_root = ensure_simple_icons(args.simple_icons)
    items, index = build_index(si_root)
    icons_dir = os.path.join(si_root, "icons")
    print("Simple Icons: %d знаков, %d ключей имён" % (len(items), len(index)))

    progs = json.load(open(CATALOG))["programs"]
    print("каталог программ: %d записей" % len(progs))

    # --- контроль приборов ДО работы: сломанное сопоставление лучше увидеть здесь
    print("\n-- положительный контроль (обязаны найтись):")
    broken = []
    for nm in POSITIVE_CONTROL:
        hit = lookup(index, nm)
        print("   %-14s %s" % (nm, ("%s  #%s  (%s: %s)" % (hit[0], hit[1], hit[2], hit[3]))
                               if hit else "НЕ НАЙДЕН <- прибор сломан"))
        if not hit:
            broken.append(nm)
    print("-- отрицательный контроль (обязаны НЕ найтись):")
    for nm in NEGATIVE_CONTROL:
        hit = lookup(index, nm)
        print("   %-26s %s" % (nm, "нет (верно)" if not hit
                               else "НАЙДЕН %s <- подстановка, прибор сломан" % hit[0]))
        if hit:
            broken.append(nm)
    if broken:
        sys.exit("контроль сопоставления не пройден: %s" % ", ".join(broken))

    # --- сопоставление
    icons: dict[str, dict] = {}
    by_source: dict[str, list[str]] = {"имя": [], "вручную": []}
    refused: list[tuple[str, str, str]] = []
    missing: list[tuple[str, str]] = []

    for p in progs:
        pid, name = p["id"], p["name"]
        manual = MANUAL.get(pid)
        if manual:
            slug, why = manual
            src = "вручную"
            row = next((x for x in items if (x.get("slug") or si_slug(x["title"])) == slug), None)
            if row is None:
                sys.exit("ручное правило указывает на отсутствующий slug: %s -> %s" % (pid, slug))
            hexv = row["hex"].upper()
        else:
            hit = lookup(index, name)
            if not hit:
                missing.append((pid, name))
                continue
            slug, hexv, _kind, _title = hit
            src, why = "имя", ""

        if slug in PUBLISHER_ONLY and (pid, slug) not in ALLOW_VENDOR_MARK:
            refused.append((pid, name, "%s — %s" % (slug, PUBLISHER_ONLY[slug])))
            continue

        svg = os.path.join(icons_dir, slug + ".svg")
        if not os.path.isfile(svg):
            refused.append((pid, name, "%s — нет файла svg в наборе" % slug))
            continue

        entry = {"slug": slug, "hex": hexv}
        if luminance(hexv) < DARK_THRESHOLD:
            entry["dark"] = True
        icons[pid] = entry
        by_source[src].append("%s -> %s%s" % (pid, slug, (" (%s)" % why) if why else ""))

    print("\nсовпало по имени: %d, вручную: %d, всего: %d"
          % (len(by_source["имя"]), len(by_source["вручную"]), len(icons)))

    # --- сквозной контроль: прибор доказывается на ИТОГЕ, а не только на указателе
    print("\n-- сквозной контроль итога:")
    e2e_bad = []
    for pid in POSITIVE_CONTROL_IDS:
        got = icons.get(pid)
        print("   %-34s %s" % (pid, ("%s #%s" % (got["slug"], got["hex"])) if got
                               else "ЗНАЧКА НЕТ <- сборка сломана"))
        if not got:
            e2e_bad.append(pid)
    for pid in NEGATIVE_CONTROL_IDS:
        got = icons.get(pid)
        print("   %-34s %s" % (pid, "пусто (верно)" if not got
                               else "ПОДСТАВЛЕН %s <- сборка врёт" % got["slug"]))
        if got:
            e2e_bad.append(pid)
    if e2e_bad:
        sys.exit("сквозной контроль не пройден: %s" % ", ".join(e2e_bad))

    if refused:
        print("отказано (знак издателя или нет файла): %d" % len(refused))
        for pid, name, why in refused:
            print("   %-34s %-28s %s" % (pid, name, why))

    # --- запись
    if args.check:
        print("\n--check: ничего не записано")
    else:
        os.makedirs(OUT_DIR, exist_ok=True)
        needed = sorted({v["slug"] for v in icons.values()})
        for slug in needed:
            shutil.copyfile(os.path.join(icons_dir, slug + ".svg"),
                            os.path.join(OUT_DIR, slug + ".svg"))
        # чистим то, что перестало быть нужным (папка наша целиком)
        for f in sorted(os.listdir(OUT_DIR)):
            if f.endswith(".svg") and f[:-4] not in needed:
                os.remove(os.path.join(OUT_DIR, f))
                print("удалён лишний %s" % f)
        import datetime
        doc = {
            "version": FORMAT_VERSION,
            "generated": datetime.date.today().isoformat(),
            "source": "Simple Icons (CC0), https://github.com/simple-icons/simple-icons",
            "dark_threshold_hex": DARK_REF_HEX,
            "icons": dict(sorted(icons.items())),
        }
        with open(OUT_JSON, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=2, sort_keys=False)
            fh.write("\n")
        print("\nзаписано: %s (%d значков), %s (%d svg)"
              % (os.path.relpath(OUT_JSON, APP), len(icons),
                 os.path.relpath(OUT_DIR, APP), len(needed)))

    # --- проверки результата
    ids = {p["id"] for p in progs}
    bad_id = [k for k in icons if k not in ids]
    bad_hex = [(k, v["hex"]) for k, v in icons.items()
               if not re.fullmatch(r"[0-9A-Fa-f]{6}", v["hex"])]
    bad_svg = []
    if not args.check:
        for k, v in icons.items():
            f = os.path.join(OUT_DIR, v["slug"] + ".svg")
            if not (os.path.isfile(f) and os.path.getsize(f) > 0):
                bad_svg.append((k, v["slug"]))
    assert not bad_id, ("id вне каталога", bad_id[:5])
    assert not bad_hex, ("плохой hex", bad_hex[:5])
    assert not bad_svg, ("нет или пуст svg", bad_svg[:5])

    dark = sorted(k for k, v in icons.items() if v.get("dark"))
    print("\nпроверки: id в каталоге — все %d; hex 6 знаков — все; svg непустые — все" % len(icons))
    print("тёмных (ниже #%s, контраст к чёрному < %.2f:1): %d"
          % (DARK_REF_HEX, contrast_on_black(DARK_REF_HEX), len(dark)))
    for k in dark:
        print("   %-34s #%s  контраст %.2f:1" % (k, icons[k]["hex"], contrast_on_black(icons[k]["hex"])))
    marginal = sorted((contrast_on_black(v["hex"]), k) for k, v in icons.items()
                      if not v.get("dark") and contrast_on_black(v["hex"]) < 2.0)
    if marginal:
        print("на грани (выше порога, но контраст < 2:1 — решение владельца):")
        for c, k in marginal:
            print("   %-34s #%s  контраст %.2f:1" % (k, icons[k]["hex"], c))

    print("\nзнака НЕ нашлось: %d записей (витрина оставит монограмму)" % len(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
