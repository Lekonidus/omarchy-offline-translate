"""Tests for bin/offline-translate. Run with the plugin venv: tests/run_all.sh

Server tests use OMARCHY_TRANSLATE_FAKE=1 (no model) in a private runtime and
config dir. Detection and real-model tests need `offline-translate setup`.
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parent.parent / "bin" / "offline-translate"
loader = importlib.machinery.SourceFileLoader("offline_translate", str(HELPER))
spec = importlib.util.spec_from_loader("offline_translate", loader)
ot = importlib.util.module_from_spec(spec)
loader.exec_module(ot)

HAVE_LID = ot.LID_FILE.is_file()
HAVE_MODEL = ot.is_installed(ot.load_config())


class Isolated(unittest.TestCase):
    """Private XDG_RUNTIME_DIR / XDG_CONFIG_HOME; fake translator."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "run").mkdir(mode=0o700)
        self.env = {**os.environ, "XDG_RUNTIME_DIR": str(root / "run"), "XDG_CONFIG_HOME": str(root / "cfg"),
                    "OMARCHY_TRANSLATE_FAKE": "1"}
        self.rd = root / "run" / "omarchy-offline-translate"
        self.config({"idleSeconds": 5})

    def tearDown(self):
        self.helper("stop")
        self.tmp.cleanup()

    def config(self, cfg):
        path = Path(self.env["XDG_CONFIG_HOME"]) / "omarchy-offline-translate" / "config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(cfg))

    def helper(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, str(HELPER), *args], input=stdin, capture_output=True, text=True,
                              env={**self.env, **(env or {})}, timeout=60)

    def run_translate(self, text, src="he"):
        out = self.helper("run", stdin=json.dumps({"text": text, "src": src}) + "\n").stdout
        return json.loads(out)

    def server_pid(self):
        return json.loads((self.rd / "state.json").read_text())["pid"]


class TextStructure(unittest.TestCase):
    def test_lines_and_blank_lines_survive(self):
        text = "The first line here. Second sentence.\n\nThird line"
        fake = ot.FakeTranslator(None)
        self.assertEqual(ot.translate_text(fake, text, "he"),
                         "[heb_Hebr] The first line here. [heb_Hebr] Second sentence.\n\n[heb_Hebr] Third line")

    def test_short_fragments_join_next_sentence(self):
        self.assertEqual(ot.split_text("Hi! How are you? I am fine today."),
                         [["Hi! How are you?", "I am fine today."]])

    def test_cjk_sentence_marks_split_without_spaces(self):
        self.assertEqual(ot.split_text("これはテストの文章です。明日また会いましょう。"),
                         [["これはテストの文章です。", "明日また会いましょう。"]])

    def test_long_line_without_punctuation_stays_one_chunk(self):
        line = "word " * 300
        self.assertEqual(ot.split_text(line), [[line.strip()]])


@unittest.skipUnless(HAVE_LID, "run offline-translate setup first")
class Detection(unittest.TestCase):
    def popup(self, text):
        label, conf = ot.detect(text)
        return ot.should_popup(text, label, conf, 0.5)

    def test_non_english_pops_up(self):
        for text in ["שלום, מה שלומך היום?", "Привет, как дела?", "Bonjour tout le monde, comment ça va ?",
                     "今日はいい天気ですね", "مرحبا كيف حالك", "Das ist ein Test", "這是一個測試"]:
            with self.subTest(text=text):
                self.assertTrue(self.popup(text))

    def test_english_and_noise_do_not(self):
        for text in ["Hello world, this is a test.", "ok", "Merci", "hola", "https://example.com/a/b",
                     "/usr/share/omarchy", "def foo(x): return x+1", "1234 5678", "git commit -m 'fix'",
                     "npm install", "OK", "Thanks!"]:
            with self.subTest(text=text):
                self.assertFalse(self.popup(text))

    def test_every_language_maps_to_an_nllb_code(self):
        if not HAVE_MODEL:
            self.skipTest("model not installed")
        vocab = set(json.loads((ot.model_dir(ot.load_config()) / "shared_vocabulary.json").read_text()))
        self.assertEqual([k for k, (code, _) in ot.LANGS.items() if code not in vocab], [])


class Server(Isolated):
    def test_starts_on_demand_reuses_and_exits_when_idle(self):
        self.assertFalse((self.rd / "sock").exists())
        first = self.run_translate("שלום")
        self.assertEqual(first["text"], "[heb_Hebr] שלום")
        pid = self.server_pid()
        self.run_translate("עוד")
        self.assertEqual(self.server_pid(), pid, "second request must reuse the server")
        deadline = time.time() + 15
        while (self.rd / "state.json").exists() and time.time() < deadline:
            time.sleep(0.25)
        self.assertFalse((self.rd / "state.json").exists(), "server must exit after idleSeconds")
        self.assertFalse((self.rd / "sock").exists())
        time.sleep(0.3)
        self.assertFalse(Path(f"/proc/{pid}").exists(), "server process must be gone (RAM released)")

    def test_stop_unloads(self):
        self.run_translate("שלום")
        pid = self.server_pid()
        self.helper("stop")
        time.sleep(0.5)
        self.assertFalse(Path(f"/proc/{pid}").exists())

    def test_concurrent_first_requests_share_one_server(self):
        results, pids = [], set()

        def go(i):
            results.append(self.run_translate(f"טקסט {i}"))

        threads = [threading.Thread(target=go, args=(i,)) for i in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(results), 6)
        self.assertTrue(all(r["ok"] for r in results), results)
        time.sleep(1)  # extra spawns notice the live server and leave
        live = subprocess.run(["pgrep", "-f", f"{HELPER} serve"], capture_output=True, text=True).stdout.split()
        mine = []
        for p in live:
            try:
                if self.env["XDG_RUNTIME_DIR"] in Path(f"/proc/{p}/environ").read_bytes().decode(errors="replace"):
                    mine.append(p)
            except OSError:
                pass
        self.assertEqual(mine, [str(self.server_pid())], "exactly one server stays")

    def test_request_after_idle_exit_restarts(self):
        self.config({"idleSeconds": 1})
        self.run_translate("שלום")
        time.sleep(7)  # idle floor is 5 s
        self.assertTrue(self.run_translate("שוב")["ok"])

    def test_bad_requests_get_errors_not_crashes(self):
        self.assertFalse(self.run_translate("")["ok"])
        self.assertFalse(self.run_translate("x" * (ot.MAX_TEXT + 1))["ok"])
        resp = self.run_translate("hello", src="xx")
        self.assertFalse(resp["ok"])
        self.assertIn("not supported", resp["error"])
        self.assertTrue(self.run_translate("שלום")["ok"], "server still serves after bad requests")

    def test_slow_model_load_does_not_time_out(self):
        resp = self.helper("run", stdin=json.dumps({"text": "שלום", "src": "he"}) + "\n",
                           env={"OMARCHY_TRANSLATE_FAKE_LOAD": "3"}).stdout
        self.assertTrue(json.loads(resp)["ok"])


FAKE_NOTIFY = """#!/bin/bash
printf '%s\\n' "$(printf '%s\\x1f' "$@")" >> "$FAKE_LOG"
[[ " $* " == *" -p "* ]] && echo 42
[[ " $* " == *" -A "* ]] && echo "${FAKE_ACTION:-}"
exit 0
"""


@unittest.skipUnless(HAVE_LID, "run offline-translate setup first")
class OnCopy(Isolated):
    """on-copy with fake notify-send / wl-paste / wl-copy on PATH."""

    def setUp(self):
        super().setUp()
        root = Path(self.tmp.name)
        fake = root / "fakebin"
        fake.mkdir()
        (fake / "notify-send").write_text(FAKE_NOTIFY)
        (fake / "wl-paste").write_text('#!/bin/bash\nprintf "%b\\n" "${FAKE_TYPES:-text/plain;charset=utf-8\\nUTF8_STRING}"\n')
        (fake / "wl-copy").write_text('#!/bin/bash\ncat > "$FAKE_COPIED"\n')
        for f in fake.iterdir():
            f.chmod(0o755)
        self.log = root / "notify.log"
        self.copied = root / "copied"
        self.env.update(PATH=f"{fake}:{os.environ['PATH']}", FAKE_LOG=str(self.log), FAKE_COPIED=str(self.copied),
                        OMARCHY_TRANSLATE_INITIAL_OK="1")

    def on_copy(self, text, env=None):
        self.helper("on-copy", stdin=text, env=env)
        return (self.rd / "last-copy").exists()

    def notifications(self, count, timeout=15):
        deadline = time.time() + timeout
        while time.time() < deadline:
            lines = self.log.read_text().splitlines() if self.log.exists() else []
            if len(lines) >= count:
                return [line.split("\x1f") for line in lines]
            time.sleep(0.1)
        self.fail(f"expected {count} notifications, got {self.log.read_text() if self.log.exists() else 'none'}")

    def test_popup_shows_translation_and_copy_works(self):
        self.assertTrue(self.on_copy("שלום, מה שלומך היום?", env={"FAKE_ACTION": "copy"}))
        placeholder, final = self.notifications(2)
        self.assertIn("Hebrew → English", placeholder)
        self.assertIn("-r", final)
        self.assertIn("42", final, "result replaces the placeholder bubble")
        self.assertIn("[heb_Hebr] שלום, מה שלומך היום?", final)
        deadline = time.time() + 5
        while not self.copied.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.assertEqual(self.copied.read_text(), "[heb_Hebr] שלום, מה שלומך היום?")

    def test_markup_in_translation_is_escaped(self):
        self.on_copy("שלום <b>עולם</b> & חברים")
        self.assertIn("&lt;b&gt;", self.notifications(2)[1][-2])

    def test_same_text_twice_pops_up_once(self):
        self.assertTrue(self.on_copy("שלום, מה שלומך היום?"))
        self.notifications(2)
        self.on_copy("שלום, מה שלומך היום?")
        time.sleep(1)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)

    def test_initial_clipboard_when_watcher_starts_is_ignored(self):
        # The helper's parent here is a bash that just started, like a fresh wl-paste --watch.
        env = {**self.env}
        del env["OMARCHY_TRANSLATE_INITIAL_OK"]
        subprocess.run(["bash", "-c", f'"{sys.executable}" "{HELPER}" on-copy; true'], input="שלום, מה שלומך היום?",
                       text=True, env=env, timeout=30)
        self.assertFalse((self.rd / "last-copy").exists())

    def test_password_manager_hint_is_ignored(self):
        self.assertFalse(self.on_copy("סיסמה סודית מאוד", env={"FAKE_TYPES": "text/plain\\nx-kde-passwordManagerHint"}))

    def test_sensitive_clipboard_is_ignored(self):
        self.assertFalse(self.on_copy("סיסמה סודית מאוד", env={"CLIPBOARD_STATE": "sensitive"}))

    def test_popups_off_is_respected(self):
        self.config({"clipboardPopups": False})
        self.assertFalse(self.on_copy("שלום, מה שלומך היום?"))

    def test_english_is_ignored(self):
        self.assertFalse(self.on_copy("Just some English text here."))

    def test_huge_clipboard_is_ignored(self):
        self.assertFalse(self.on_copy("שלום " * 10000))

    def test_toggle_command(self):
        self.assertEqual(self.helper("popups", "off").stdout.strip(), "off")
        self.assertEqual(self.helper("popups", "toggle").stdout.strip(), "on")
        self.assertTrue(json.loads(self.helper("status").stdout)["config"]["clipboardPopups"])


@unittest.skipUnless(HAVE_MODEL, "model not installed")
class RealModel(unittest.TestCase):
    def test_hebrew_to_english(self):
        tr = ot.Translator(ot.model_dir(ot.load_config()))
        out = ot.translate_text(tr, "אני רוצה להזמין שולחן לשניים.\nתודה רבה!", "he").lower()
        self.assertIn("table", out)
        self.assertIn("\n", out)
        self.assertIn("thank", out)


if __name__ == "__main__":
    unittest.main()
