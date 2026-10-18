#!/usr/bin/env python3
"""Checks the app's String Catalogs before a release.

  check-localizations.py [--stringsdata DIR --sources DIR] CATALOG...

Every string must be translated into every language the app ships, keep the
English placeholders, and use no em dashes. With --stringsdata (what swiftc
writes with -emit-localized-strings), Localizable.xcstrings must also hold
exactly the strings the code looks up: a new string with no translations
would show in English, and a stale one is translation work for nothing.
swiftc writes one file per source file and only for files it recompiles, so
the folder is kept between builds and, with --sources, only files whose
source still exists count.
"""

import argparse
import glob
import json
import os
import re
import sys

LANGUAGES = ["de", "es", "fil", "fr", "it", "ja", "ko", "nl", "pt-BR", "sv", "zh-Hans"]
# Languages whose plural rules have no "one" form.
OTHER_ONLY = {"ja", "ko", "zh-Hans"}
SPECIFIER = re.compile(r"%(?:\d+\$)?(lld|ld|d|@|\.\d+f|f)")
EM_DASH = "—"


def specifiers(text):
    return sorted(SPECIFIER.findall(text))


def units(entry, language):
    """(variant, value, state) for each form of one language's translation."""
    localization = entry.get("localizations", {}).get(language)
    if localization is None:
        return None
    if "stringUnit" in localization:
        unit = localization["stringUnit"]
        return [(None, unit.get("value", ""), unit.get("state"))]
    plural = localization.get("variations", {}).get("plural", {})
    return [(category, form["stringUnit"].get("value", ""), form["stringUnit"].get("state"))
            for category, form in plural.items()]


def check_catalog(path):
    problems = []
    catalog = json.load(open(path, encoding="utf-8"))
    for key, entry in catalog["strings"].items():
        english = units(entry, "en") or [(None, key, "translated")]
        source = dict((variant, value) for variant, value, _ in english)
        reference = specifiers(source.get("other", source.get(None, key)))
        is_plural = english[0][0] is not None

        for variant, value, _ in english:
            if EM_DASH in value:
                problems.append(f"{key!r} (en): em dash")

        for language in LANGUAGES:
            forms = units(entry, language)
            if not forms:
                problems.append(f"{key!r}: no {language} translation")
                continue
            categories = {variant for variant, _, _ in forms}
            if is_plural:
                needed = {"other"} if language in OTHER_ONLY else {"one", "other"}
                if not needed <= categories:
                    problems.append(f"{key!r} ({language}): plural forms {sorted(categories)}, needs {sorted(needed)}")
            elif categories != {None}:
                problems.append(f"{key!r} ({language}): plural forms where English has none")
            for variant, value, state in forms:
                where = f"{key!r} ({language}{'/' + variant if variant else ''})"
                if state != "translated" or not value.strip():
                    problems.append(f"{where}: not translated")
                    continue
                if EM_DASH in value:
                    problems.append(f"{where}: em dash")
                found = specifiers(value)
                # A "one" form may say the number in words instead.
                if variant in ("one", "zero"):
                    if any(found.count(s) > reference.count(s) for s in found):
                        problems.append(f"{where}: placeholders {found}, English has {reference}")
                elif found != reference:
                    problems.append(f"{where}: placeholders {found}, English has {reference}")
    return catalog, problems


def extracted_keys(directory, table, sources=None):
    current = None
    if sources:
        current = {os.path.splitext(os.path.basename(p))[0]
                   for p in glob.glob(os.path.join(sources, "**", "*.swift"), recursive=True)}
    keys = set()
    for path in glob.glob(os.path.join(directory, "*.stringsdata")):
        if current is not None and os.path.splitext(os.path.basename(path))[0] not in current:
            continue
        data = json.load(open(path, encoding="utf-8"))
        keys.update(entry["key"] for entry in data.get("tables", {}).get(table, []))
    return keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stringsdata")
    parser.add_argument("--sources")
    parser.add_argument("catalogs", nargs="+")
    args = parser.parse_args()

    problems = []
    for path in args.catalogs:
        catalog, found = check_catalog(path)
        problems += [f"{os.path.basename(path)}: {p}" for p in found]
        table = os.path.splitext(os.path.basename(path))[0]
        if args.stringsdata and table == "Localizable":
            in_code = extracted_keys(args.stringsdata, table, args.sources)
            if not in_code:
                problems.append(f"no strings found in {args.stringsdata}")
            in_catalog = set(catalog["strings"])
            problems += [f"{table}: {k!r} is in the code but not the catalog" for k in sorted(in_code - in_catalog)]
            problems += [f"{table}: {k!r} is in the catalog but no longer in the code" for k in sorted(in_catalog - in_code)]

    for problem in problems:
        print(f"ERROR: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print(f"Localizations verified: {len(LANGUAGES)} languages besides English.")


if __name__ == "__main__":
    main()
