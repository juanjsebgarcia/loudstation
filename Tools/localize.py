#!/usr/bin/env python3
"""
Build LoudStation's translations from Localization/<language>.json.

Validates every language against English (same keys, same placeholders, the plural
categories that language needs, length limits for tight UI), then writes
Resources/<language>.lproj/Localizable.strings and .stringsdict for the app bundle and
Sources/Core/EnglishStrings.swift, the compiled-in fallback the CLI uses when it cannot
find the app bundle. Run `python3 Tools/localize.py` after editing any Localization file;
the generated files are committed so building needs no Python. `--check` only validates and
writes nothing, for `make test`.
"""

import json
import plistlib
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Localization"
RESOURCES = ROOT / "Resources"
ENGLISH_SWIFT = ROOT / "Sources" / "Core" / "EnglishStrings.swift"

# CLDR plural categories each language needs for integers (cardinal), per
# https://www.unicode.org/cldr/charts/latest/supplemental/language_plural_rules.html
PLURAL_CATEGORIES = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "ca": {"one", "other"}, "cs": {"one", "few", "other"}, "da": {"one", "other"},
    "de": {"one", "other"}, "el": {"one", "other"}, "en": {"one", "other"},
    "es": {"one", "other"}, "es-419": {"one", "other"}, "fi": {"one", "other"},
    "fr": {"one", "other"}, "fr-CA": {"one", "other"}, "he": {"one", "two", "other"},
    "hi": {"one", "other"}, "hr": {"one", "few", "other"}, "hu": {"one", "other"},
    "id": {"other"}, "it": {"one", "other"}, "ja": {"other"}, "ko": {"other"},
    "ms": {"other"}, "nb": {"one", "other"}, "nl": {"one", "other"},
    "pl": {"one", "few", "many", "other"}, "pt-BR": {"one", "other"}, "pt-PT": {"one", "other"},
    "ro": {"one", "few", "other"}, "ru": {"one", "few", "many", "other"},
    "sk": {"one", "few", "other"}, "sv": {"one", "other"}, "th": {"other"},
    "tr": {"one", "other"}, "uk": {"one", "few", "many", "other"}, "vi": {"other"},
    "zh-Hans": {"other"}, "zh-Hant": {"other"}, "zh-HK": {"other"},
}

# Tight UI: menu bar menu items, row statuses and terminal columns. Limits are in display
# columns (East Asian wide characters count double), generous enough for German.
LIMITS = [
    (re.compile(r"^status\.|^cli\.status\.(working|no_sound|couldnt_check)$"), 16),
    (re.compile(r"^row\.tag\."), 22),
    (re.compile(r"^(menu\.|submenu\.)"), 48),
    (re.compile(r"^headline\."), 52),
    (re.compile(r"^(welcome\.fix_automatically|welcome\.status_only|confirm\.fix|confirm\.cancel|update\.button\.[a-z_]+)$"), 24),
    (re.compile(r"^notify\..*\.title$"), 48),
    (re.compile(r"^note\."), 110),
    (re.compile(r"^notify\..*body"), 170),
]

# The full printf conversion grammar, so an unexpected specifier such as %x, %ld or %*d is
# seen and rejected rather than passing as "no placeholder"; such strings can crash or leak
# memory when formatted.
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@[A-Za-z_]+@|[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?[@dfsSxXoucCpneEgGaA%])")


def width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def placeholders(text: str) -> list[tuple[int, str]]:
    """Positional placeholders as (position, type), numbering unnumbered ones in order."""
    found, sequence = [], 0
    for position, kind in SPECIFIER.findall(text.replace("%%", "")):
        if kind.startswith("#@") or kind == "%":
            continue
        sequence += 1
        found.append((int(position) if position else sequence, kind))
    return sorted(set(found))


def plural_placeholders(entry: dict) -> list[tuple[int, str]]:
    found = set(placeholders(entry["format"]))
    for var in entry["vars"].values():
        for category, text in var.items():
            if category != "type":
                found.update(placeholders(text))
    return sorted(found)


def limit_for(key: str):
    for pattern, limit in LIMITS:
        if pattern.search(key):
            return limit
    return None


BACKTICKS = re.compile(r"`[^`]*`")
OPTION = re.compile(r"(?<![\w-])--[a-z]+")


def hygiene(lang: str, key: str, text: str, english_text: str) -> tuple[list[str], list[str]]:
    """Cross-language checks: commands and options intact, spacing, apostrophes, untranslated text."""
    errors, warnings = [], []
    if sorted(BACKTICKS.findall(text)) != sorted(BACKTICKS.findall(english_text)):
        errors.append(f"{key}: backticked commands {BACKTICKS.findall(text)} != English {BACKTICKS.findall(english_text)}")
    if sorted(OPTION.findall(text)) != sorted(OPTION.findall(english_text)):
        errors.append(f"{key}: options {OPTION.findall(text)} != English {OPTION.findall(english_text)}")
    if text != text.strip(" \t"):
        errors.append(f"{key}: leading or trailing space")
    if "  " in text:
        warnings.append(f"{key}: double space")
    if lang != "en" and "'" in BACKTICKS.sub("", text):
        warnings.append(f"{key}: straight apostrophe; use ’ or the language's own quotation marks")
    plain = SPECIFIER.sub("", english_text)
    if lang != "en" and text == english_text and len(re.sub(r"\W", "", plain)) > 8:
        warnings.append(f"{key}: identical to English, probably untranslated")
    return errors, warnings


def check(lang: str, data: dict, english: dict) -> tuple[list[str], list[str]]:
    errors, warnings = [], []
    strings, plurals = data.get("strings", {}), data.get("plurals", {})
    for key, text in english["strings"].items():
        if key not in strings:
            errors.append(f"missing string {key}")
            continue
        more_errors, more_warnings = hygiene(lang, key, strings[key], text)
        errors += more_errors
        warnings += more_warnings
        if placeholders(strings[key]) != placeholders(text):
            errors.append(f"{key}: placeholders {placeholders(strings[key])} != English {placeholders(text)}")
        limit = limit_for(key)
        if limit and width(strings[key]) > limit:
            warnings.append(f"{key} is {width(strings[key])} columns (limit {limit}): {strings[key]}")
        if "..." in strings[key]:
            errors.append(f"{key}: use the ellipsis character … not three dots")
    for key in strings:
        if key not in english["strings"]:
            errors.append(f"unknown string {key}")
    needed = PLURAL_CATEGORIES.get(lang)
    if needed is None:
        errors.append(f"no plural rules recorded for {lang}; add it to PLURAL_CATEGORIES")
        needed = {"other"}
    for key, entry in english["plurals"].items():
        if key not in plurals:
            errors.append(f"missing plural {key}")
            continue
        mine = plurals[key]
        if set(mine["vars"]) != set(entry["vars"]):
            errors.append(f"{key}: plural variables {sorted(mine['vars'])} != English {sorted(entry['vars'])}")
            continue
        for name, var in mine["vars"].items():
            if var.get("type", "d") != entry["vars"][name].get("type", "d"):
                errors.append(f"{key}.{name}: plural value type {var.get('type')} != English {entry['vars'][name].get('type')}")
            categories = {c for c in var if c != "type"}
            if not needed <= categories:
                errors.append(f"{key}.{name}: needs plural categories {sorted(needed)}, has {sorted(categories)}")
            if "other" not in categories:
                errors.append(f"{key}.{name}: the 'other' category is required")
        if plural_placeholders(mine) != plural_placeholders(entry):
            errors.append(f"{key}: plural placeholders {plural_placeholders(mine)} != English {plural_placeholders(entry)}")
        limit = limit_for(key)
        for name, var in mine["vars"].items():
            for category, text in var.items():
                if category != "type" and limit and width(text) > limit:
                    warnings.append(f"{key}.{name}.{category} is {width(text)} columns (limit {limit}): {text}")
    for key in plurals:
        if key not in english["plurals"]:
            errors.append(f"unknown plural {key}")
    return errors, warnings


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")


def write_lproj(lang: str, data: dict) -> None:
    folder = RESOURCES / f"{lang}.lproj"
    folder.mkdir(parents=True, exist_ok=True)
    lines = [f"/* Generated by Tools/localize.py from Localization/{lang}.json. Do not edit. */", ""]
    for key in sorted(data["strings"]):
        lines.append(f"\"{escape(key)}\" = \"{escape(data['strings'][key])}\";")
    (folder / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    plist = {}
    for key, entry in sorted(data["plurals"].items()):
        item = {"NSStringLocalizedFormatKey": entry["format"]}
        for name, var in entry["vars"].items():
            rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": var.get("type", "d")}
            rule.update({c: t for c, t in var.items() if c != "type"})
            item[name] = rule
        plist[key] = item
    with open(folder / "Localizable.stringsdict", "wb") as handle:
        plistlib.dump(plist, handle, fmt=plistlib.FMT_XML, sort_keys=True)


def swift_literal(text: str) -> str:
    return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""


def write_english_swift(english: dict) -> None:
    out = [
        "// Generated by Tools/localize.py from Localization/en.json. Do not edit.",
        "// English fallback for when no app bundle with translations can be found (the CLI on its own).",
        "",
        "struct EnglishPlural {",
        "    let format: String",
        "    let variables: [String: (one: String, other: String)]",
        "}",
        "",
        "let englishStrings: [String: String] = [",
    ]
    out += [f"    {swift_literal(k)}: {swift_literal(v)}," for k, v in sorted(english["strings"].items())]
    out += ["]", "", "let englishPlurals: [String: EnglishPlural] = ["]
    for key, entry in sorted(english["plurals"].items()):
        variables = ", ".join(
            f"{swift_literal(n)}: (one: {swift_literal(v['one'])}, other: {swift_literal(v['other'])})"
            for n, v in entry["vars"].items()
        )
        out.append(f"    {swift_literal(key)}: EnglishPlural(format: {swift_literal(entry['format'])}, variables: [{variables}]),")
    out += ["]", ""]
    ENGLISH_SWIFT.write_text("\n".join(out), encoding="utf-8")


def main() -> int:
    check_only = "--check" in sys.argv[1:]
    english = json.loads((SOURCE / "en.json").read_text(encoding="utf-8"))
    failed = False
    languages = []
    for path in sorted(SOURCE.glob("*.json")):
        lang = path.stem
        data = json.loads(path.read_text(encoding="utf-8"))
        errors, warnings = check(lang, data, english)
        for warning in warnings:
            print(f"warning {lang}: {warning}")
        for error in errors:
            print(f"ERROR {lang}: {error}")
        if errors and check_only:
            failed = True
            continue
        if errors:
            failed = True
            # A language that fails is removed rather than shipped with stale strings, whose
            # placeholders may no longer match the code. macOS then falls back to English.
            stale = RESOURCES / f"{lang}.lproj"
            if stale.exists():
                for item in stale.iterdir():
                    item.unlink()
                stale.rmdir()
                print(f"removed Resources/{lang}.lproj until Localization/{lang}.json validates")
            continue
        if not check_only:
            write_lproj(lang, data)
        languages.append(lang)
    stale = {p.name[:-6] for p in RESOURCES.glob("*.lproj")} - set(languages)
    for lang in sorted(stale):
        print(f"note: Resources/{lang}.lproj has no valid Localization/{lang}.json; left as is")
    if check_only:
        print(f"{len(languages)} languages valid")
        return 1 if failed else 0
    write_english_swift(english)
    print(f"{len(languages)} languages written: {' '.join(languages)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
