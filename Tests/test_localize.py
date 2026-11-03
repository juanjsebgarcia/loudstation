"""
Tests for Tools/localize.py's validation, so its checks cannot quietly stop catching problems.

Run by `make test`, or directly with `python3 -I -m unittest discover -s Tests -p 'test_*.py'`.
"""

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("localize", ROOT / "Tools" / "localize.py")
localize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(localize)

ENGLISH = json.loads((ROOT / "Localization" / "en.json").read_text(encoding="utf-8"))


def load(lang: str) -> dict:
    return json.loads((ROOT / "Localization" / f"{lang}.json").read_text(encoding="utf-8"))


class RealTranslations(unittest.TestCase):
    def test_every_language_validates(self):
        for path in sorted((ROOT / "Localization").glob("*.json")):
            with self.subTest(language=path.stem):
                errors, _ = localize.check(path.stem, load(path.stem), ENGLISH)
                self.assertEqual(errors, [])

    def test_every_language_has_plural_rules(self):
        for path in (ROOT / "Localization").glob("*.json"):
            self.assertIn(path.stem, localize.PLURAL_CATEGORIES)


class BrokenTranslations(unittest.TestCase):
    def errors(self, data: dict, lang: str = "de") -> list[str]:
        return localize.check(lang, data, ENGLISH)[0]

    def warnings(self, data: dict, lang: str = "de") -> list[str]:
        return localize.check(lang, data, ENGLISH)[1]

    def german(self) -> dict:
        return copy.deepcopy(load("de"))

    def test_missing_string(self):
        bad = self.german()
        del bad["strings"]["menu.check_now"]
        self.assertIn("missing string menu.check_now", self.errors(bad))

    def test_unknown_string(self):
        bad = self.german()
        bad["strings"]["menu.invented"] = "Erfunden"
        self.assertIn("unknown string menu.invented", self.errors(bad))

    def test_extra_hex_specifier(self):
        bad = self.german()
        bad["strings"]["headline.fixing"] = "Repariere %@ %x …"
        self.assertTrue(any(e.startswith("headline.fixing: placeholders") for e in self.errors(bad)))

    def test_wrong_specifier_type(self):
        bad = self.german()
        bad["strings"]["headline.fixing"] = "Repariere %d …"
        self.assertTrue(any(e.startswith("headline.fixing: placeholders") for e in self.errors(bad)))

    def test_length_modifier_specifier(self):
        bad = self.german()
        bad["strings"]["headline.fixing"] = "Repariere %@ %ld …"
        self.assertTrue(any(e.startswith("headline.fixing: placeholders") for e in self.errors(bad)))

    def test_lost_backticks(self):
        bad = self.german()
        bad["strings"]["cli.status.hint_fix"] = "Führe %@ fix aus."
        self.assertTrue(any("backticked commands" in e for e in self.errors(bad)))

    def test_translated_option(self):
        bad = self.german()
        bad["strings"]["cli.error.see_help"] = "Siehe `%@ --hilfe`."
        self.assertTrue(any("options" in e for e in self.errors(bad)))

    def test_trailing_space(self):
        bad = self.german()
        bad["strings"]["menu.check_now"] = "Jetzt prüfen "
        self.assertIn("menu.check_now: leading or trailing space", self.errors(bad))

    def test_three_dots(self):
        bad = self.german()
        bad["strings"]["status.checking"] = "Prüfe..."
        self.assertTrue(any("ellipsis" in e for e in self.errors(bad)))

    def test_missing_plural_category(self):
        bad = copy.deepcopy(load("pl"))
        bad["plurals"]["note.paused"]["vars"]["tries"].pop("few")
        self.assertTrue(any("needs plural categories" in e for e in self.errors(bad, "pl")))

    def test_plural_value_type(self):
        bad = self.german()
        bad["plurals"]["note.paused"]["vars"]["tries"]["type"] = "@"
        self.assertTrue(any("plural value type" in e for e in self.errors(bad)))

    def test_unknown_language(self):
        self.assertTrue(any("no plural rules" in e for e in self.errors(self.german(), "xx")))

    def test_straight_apostrophe_warns(self):
        bad = self.german()
        bad["strings"]["note.busy"] = "Läuft noch, 'Jetzt reparieren' gleich nochmal."
        self.assertTrue(any("straight apostrophe" in w for w in self.warnings(bad)))

    def test_untranslated_warns(self):
        bad = self.german()
        bad["strings"]["welcome.body"] = ENGLISH["strings"]["welcome.body"]
        self.assertTrue(any("untranslated" in w for w in self.warnings(bad)))

    def test_length_limit_warns(self):
        bad = self.german()
        bad["strings"]["status.working"] = "Funktioniert wirklich ganz hervorragend"
        self.assertTrue(any(w.startswith("status.working is") for w in self.warnings(bad)))


class Helpers(unittest.TestCase):
    def test_wide_characters_count_double(self):
        self.assertEqual(localize.width("音が出ない"), 10)
        self.assertEqual(localize.width("No Sound"), 8)

    def test_positional_placeholders(self):
        self.assertEqual(localize.placeholders("%2$@ then %1$d"), [(1, "d"), (2, "@")])
        self.assertEqual(localize.placeholders("%@ and %d"), [(1, "@"), (2, "d")])
        self.assertEqual(localize.placeholders("100%% sure"), [])

    def test_plural_tokens_are_not_placeholders(self):
        self.assertEqual(localize.placeholders("%1$#@tries@"), [])


if __name__ == "__main__":
    unittest.main()
