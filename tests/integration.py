import codecs
import io
import os
import random
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

import psutil
import pyte

if os.name == "nt":
    import queue
    import threading

    from winpty import PtyProcess
else:
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios


REPO = Path(__file__).resolve().parents[1]
YAZI = os.environ.get("YAZI_BIN") or shutil.which("yazi")
YA = os.environ.get("YA_BIN") or shutil.which("ya")
SEVEN = next((shutil.which(n) for n in ("7zz", "7z", "7za") if shutil.which(n)), None)
TOOLS = {
    n: shutil.which(n) for n in ("zip", "tar", "bsdtar", "gzip", "xz", "bzip2", "zstd", "lz4", "lha", "rar")
}
CONTENT = b"selected archive content\n"
ARTIFACTS = Path(os.environ.get("TEST_ARTIFACTS", "test-results")).resolve()


class Terminal:
    def __init__(self, args, env):
        if os.name == "nt":
            self.process = PtyProcess.spawn(args, env=env, dimensions=(36, 140))
            self.output = queue.Queue()

            def read():
                try:
                    while True:
                        self.output.put(self.process.read(65536))
                except (EOFError, OSError):
                    pass

            threading.Thread(target=read, daemon=True).start()
        else:
            self.fd, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 140, 0, 0))

            def setup():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            self.process = subprocess.Popen(
                args, stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=setup
            )
            os.close(slave)
        self.pid = self.process.pid

    def write(self, text):
        if os.name == "nt":
            self.process.write(text)
        else:
            os.write(self.fd, text.encode())

    def read(self):
        if os.name == "nt":
            try:
                return self.output.get(timeout=0.02)
            except queue.Empty:
                return ""
        if select.select([self.fd], [], [], 0.02)[0]:
            try:
                return os.read(self.fd, 65536)
            except OSError:
                pass
        return b""

    def close(self):
        if os.name == "nt":
            self.process.close(force=True)
        else:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=10)
            os.close(self.fd)


class Session:
    def __init__(self, name, profile="full"):
        self.temp = tempfile.TemporaryDirectory(prefix="compress-")
        self.root = Path(self.temp.name).resolve()
        self.data = self.root / "data"
        self.data.mkdir()
        (self.data / "sample.txt").write_bytes(CONTENT)
        config = self.root / "config"
        plugin = config / "plugins/compress.yazi"
        plugin.mkdir(parents=True)
        shutil.copy2(REPO / "main.lua", plugin / "main.lua")
        (config / "keymap.toml").write_text("""[[mgr.prepend_keymap]]
on = "C"
run = "plugin compress"
[[mgr.prepend_keymap]]
on = "Q"
run = "plugin compress zip"
[[mgr.prepend_keymap]]
on = "P"
run = "plugin compress -p"
[[mgr.prepend_keymap]]
on = "H"
run = "plugin compress -h"
[[mgr.prepend_keymap]]
on = "L"
run = "plugin compress '-l 7z'"
""")
        (config / "yazi.toml").write_text("[tasks]\nplugin_workers = 1\n")
        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        tools = dict(TOOLS)
        if profile == "native":
            tools.pop("rar", None)
        elif profile == "bsd":
            tools = {
                n: p
                for n, p in tools.items()
                if n == "bsdtar"
                or n == "tar"
                and p
                and "bsdtar" in subprocess.check_output([p, "--version"], text=True)
            }
        if profile == "full":
            tools[Path(SEVEN).stem] = SEVEN
        elif profile == "seven":
            tools = {n: p for n, p in tools.items() if n in ("tar", "bsdtar")}
            tools[Path(SEVEN).stem] = SEVEN
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        for tool_name, path in tools.items():
            if not path:
                continue
            target = binary_dir / (tool_name + (".exe" if os.name == "nt" else ""))
            if os.name == "nt":
                shutil.copy2(path, target)
                if not Path(path).is_relative_to(Path(os.environ["WINDIR"])):
                    for dll in Path(path).parent.glob("*.dll"):
                        if not (binary_dir / dll.name).exists():
                            shutil.copy2(dll, binary_dir / dll.name)
            else:
                target.symlink_to(path)
        self.env = dict(
            os.environ,
            PATH=str(binary_dir),
            YAZI_CONFIG_HOME=str(config),
            XDG_RUNTIME_DIR=str(runtime),
            XDG_CACHE_HOME=str(self.root / "cache"),
            XDG_STATE_HOME=str(self.root / "state"),
            TERM="xterm-256color",
            YAZI_LOG="debug",
        )
        self.client = str(random.randrange(1_000_000, 2_000_000_000))
        self.terminal = Terminal([YAZI, "--client-id", self.client, str(self.data)], self.env)
        self.name = name
        self.log = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        terminal = self.terminal

        class Screen(pyte.Screen):
            def report_device_status(self, mode, **kwargs):
                if mode == 6:
                    terminal.write("\x1b[1;1R")

            def report_device_attributes(self, *args, **kwargs):
                terminal.write("\x1b[?1;2c")

        self.screen = Screen(140, 36)
        self.stream = pyte.Stream(self.screen)
        try:
            self.until(lambda: "sample.txt" in self.text)
        except BaseException:
            self.close()
            raise

    @property
    def text(self):
        return "\n".join(self.screen.display)

    def pump(self, seconds=0.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            data = self.terminal.read()
            if isinstance(data, bytes):
                data = self.decoder.decode(data)
            if data:
                self.log += data
                self.stream.feed(data)
            elif os.name == "nt":
                time.sleep(0.01)

    def until(self, condition, timeout=20):
        end = time.monotonic() + timeout
        while not condition():
            if time.monotonic() >= end:
                raise AssertionError(self.text + "\n" + self.log[-3000:])
            self.pump()

    def key(self, text):
        self.terminal.write(text)
        self.pump()

    def fill(self, text):
        self.key("\x1b[H\x0b\x1b[200~" + text + "\x1b[201~\r")

    def emit(self, *args):
        subprocess.run(
            [YA, "emit-to", self.client, *map(str, args)],
            env=self.env,
            check=True,
            capture_output=True,
            timeout=10,
        )
        self.pump()

    def create(self, name, key="Q", inputs=(), wait=True):
        self.key(key)
        self.until(lambda: "Create archive:" in self.text)
        self.fill(name)
        for prompt, value in inputs:
            self.until(lambda: prompt in self.text)
            self.fill(value)
        target = self.data / name
        if wait:
            self.until(target.exists, timeout=60)
            self.until(lambda: not list(self.data.glob(".tmp_compress*")))
        return target

    def close(self):
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / (self.name + ".terminal.txt")).write_text(self.log, encoding="utf-8")
        state = self.root / "state/yazi/yazi.log"
        if state.exists():
            shutil.copy2(state, ARTIFACTS / (self.name + ".yazi.log"))
        self.terminal.close()
        self.temp.cleanup()


def contents(path, password=None):
    args = [SEVEN, "x", "-so", "-p" + (password or ""), str(path)]
    filter_tool = next(
        (
            tool
            for tool, suffixes in (("lz4", (".tar.lz4", ".tlz4")), ("zstd", (".tar.zst", ".tzst")))
            if path.name.endswith(suffixes)
        ),
        None,
    )
    if filter_tool:
        if not TOOLS[filter_tool]:
            return subprocess.check_output([TOOLS["bsdtar"] or TOOLS["tar"], "-xOf", str(path)])
        args = [TOOLS[filter_tool], "-dc", str(path)]
    data = subprocess.check_output(args, stderr=subprocess.PIPE)
    if ".tar." in path.name or path.suffix[1:] in ("tgz", "txz", "tbz", "tbz2", "tzst", "tlz4"):
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            return archive.extractfile(next(e for e in archive if e.isfile())).read()
    return data


class Integration(unittest.TestCase):
    def session(self, profile="full"):
        session = Session(self._testMethodName + "-" + profile, profile)
        self.addCleanup(session.close)
        return session

    def test_menu_and_encryption(self):
        s = self.session()
        s.key("C")
        s.until(lambda: "Format:" in s.text)
        self.assertNotIn("Backend:", s.text)
        self.assertNotRegex(s.text, r"Format: [^\n]*\(")
        s.key("p")
        s.until(lambda: "Password: on" in s.text)
        s.key("f")
        s.until(lambda: re.search(r"\b7z\b", s.text))
        self.assertNotRegex(s.text, r"\btar(?:\.\w+)*\b")
        s.key("7")
        s.until(lambda: "Format: 7z" in s.text)
        s.key("h")
        s.until(lambda: "Hide filenames: on" in s.text)
        s.key("l")
        s.until(lambda: "Compression level" in s.text)
        s.fill("9")
        s.until(lambda: "Level: 9" in s.text)
        target = s.create(
            "secure.7z", "c", [("Enter password:", "test-password"), ("Confirm password:", "test-password")]
        )
        self.assertEqual(contents(target, "test-password"), CONTENT)
        self.assertNotEqual(
            subprocess.run([SEVEN, "l", "-pwrong", str(target)], capture_output=True).returncode, 0
        )
        s.emit("reveal", s.data / "sample.txt")
        target = s.create(
            "secure.zip", "P", [("Enter password:", "test-password"), ("Confirm password:", "test-password")]
        )
        self.assertEqual(contents(target, "test-password"), CONTENT)
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.infolist()[0].compress_type, 99)
        if TOOLS["rar"]:
            s.emit("reveal", s.data / "sample.txt")
            target = s.create(
                "secure.rar",
                "H",
                [("Enter password:", "test-password"), ("Confirm password:", "test-password")],
            )
            self.assertEqual(
                subprocess.check_output([TOOLS["rar"], "p", "-inul", "-ptest-password", str(target)]), CONTENT
            )
            self.assertNotEqual(
                subprocess.run([TOOLS["rar"], "lb", "-pwrong", str(target)], capture_output=True).returncode,
                0,
            )

    def test_formats_and_aliases(self):
        s = self.session()
        formats = [
            "zip",
            "cbz",
            "7z",
            "cb7",
            "tar",
            "tar.gz",
            "tgz",
            "tar.xz",
            "txz",
            "tar.bz2",
            "tbz",
            "tbz2",
        ]
        for tool, extensions in (
            ("zstd", ["tar.zst", "tzst"]),
            ("lz4", ["tar.lz4", "tlz4"]),
            ("lha", ["tar.lha"]),
        ):
            if TOOLS[tool]:
                formats += extensions
        if TOOLS["rar"]:
            formats += ["rar", "cbr"]
        for extension in formats:
            with self.subTest(extension=extension):
                s.emit("reveal", s.data / "sample.txt")
                self.assertEqual(contents(s.create("archive." + extension)), CONTENT)

    def test_fallbacks(self):
        for profile in ("native", "seven", "bsd"):
            s = self.session(profile)
            formats = ["zip", "tar"]
            if profile == "seven":
                formats += ["tar.gz", "tar.xz", "tar.bz2"]
            elif profile == "native":
                formats += [
                    "tar." + ext
                    for ext, tool in (
                        ("gz", "gzip"),
                        ("xz", "xz"),
                        ("bz2", "bzip2"),
                        ("zst", "zstd"),
                        ("lz4", "lz4"),
                    )
                    if TOOLS[tool]
                ]
            else:
                bsd = TOOLS["bsdtar"] or TOOLS["tar"]
                version = subprocess.check_output([bsd, "--version"], text=True)
                formats += [
                    "tar." + ext
                    for ext, flag in (
                        ("gz", "-z"),
                        ("xz", "-J"),
                        ("bz2", "-j"),
                        ("zst", "--zstd"),
                        ("lz4", "--lz4"),
                    )
                    if subprocess.run(
                        [bsd, flag, "-cf", os.devnull, "-T", os.devnull], capture_output=True, env=s.env
                    ).returncode
                    == 0
                ]
                print("BSD tar codecs:", version.strip(), flush=True)
                if os.environ.get("REQUIRE_BSD_CODECS"):
                    self.assertEqual(
                        set(formats), {"zip", "tar", "tar.gz", "tar.xz", "tar.bz2", "tar.zst", "tar.lz4"}
                    )
            for extension in formats:
                with self.subTest(profile=profile, extension=extension):
                    s.emit("reveal", s.data / "sample.txt")
                    self.assertEqual(contents(s.create(profile + "." + extension)), CONTENT)

    def test_failures_paths_and_overwrite(self):
        s = self.session()
        for name, inputs in (
            ("empty.zip", [("Enter password:", "")]),
            ("mismatch.zip", [("Enter password:", "one"), ("Confirm password:", "two")]),
        ):
            s.create(name, "P", inputs, wait=False)
            s.until(lambda: "aborted" in s.text or "do not match" in s.text)
            self.assertFalse((s.data / name).exists())
        target = s.data / "existing.zip"
        target.write_bytes(b"preserve existing file")
        s.create("existing.zip", wait=False)
        s.until(lambda: len(list(s.data.glob("existing*"))) == 2)
        self.assertEqual(target.read_bytes(), b"preserve existing file")
        for name in ("-leading.tar.gz", "@leading.tar.xz", "space ü.tar.bz2"):
            s.emit("reveal", s.data / "sample.txt")
            self.assertEqual(contents(s.create(name)), CONTENT)
        if TOOLS["lha"]:
            s.emit("reveal", s.data / "sample.txt")
            target = s.create("space ü.tar.lha")
            self.assertEqual(contents(target), CONTENT)
            self.assertNotIn(
                ".tmp_compress", subprocess.check_output([SEVEN, "l", "-slt", str(target)], text=True)
            )
        for directory, value in (("a", b"first"), ("b", b"second")):
            (s.data / directory).mkdir()
            (s.data / directory / "same.txt").write_bytes(value)
            s.emit("reveal", s.data / directory / "same.txt")
            s.emit("toggle", "--state=on")
        s.emit("cd", s.data)
        archive = s.create("selected.tar")
        with tarfile.open(archive) as packed:
            self.assertEqual(packed.extractfile("./a/same.txt").read(), b"first")
            self.assertEqual(packed.extractfile("./b/same.txt").read(), b"second")

    def test_progress_and_cancellation(self):
        s = self.session()
        (s.data / "large.bin").write_bytes(random.Random(42).randbytes(64 * 1024 * 1024))
        s.emit("reveal", s.data / "large.bin")
        s.create("running.7z", "L", [("Compression level", "9")], wait=False)
        s.key("w")
        s.until(lambda: re.search(r"\b(?:[1-9]|[1-9][0-9])%", s.text) is not None, timeout=60)
        children = [
            p
            for p in psutil.Process(s.terminal.pid).children(recursive=True)
            if p.name().lower().startswith("7z")
        ]
        self.assertTrue(children, s.text)
        s.key("\x1b")
        s.emit("reveal", s.data / "sample.txt")
        s.create("queued.zip", wait=False)
        s.key("w")
        s.until(lambda: "Compress queued.zip" in s.text and "Compress running.7z" in s.text)
        lines = s.text.splitlines()
        s.key("kkkk")
        if next(i for i, line in enumerate(lines) if "Compress queued.zip" in line) > next(
            i for i, line in enumerate(lines) if "Compress running.7z" in line
        ):
            s.key("j")
        s.key("x")
        s.until(lambda: "Compress queued.zip" not in s.text)
        s.key("x")
        s.until(
            lambda: (
                not list(s.data.glob(".tmp_compress*"))
                and all(not p.is_running() or p.status() == psutil.STATUS_ZOMBIE for p in children)
            )
        )
        self.assertFalse((s.data / "running.7z").exists())
        self.assertFalse((s.data / "queued.zip").exists())
        s.key("\x1b")
        self.assertEqual(contents(s.create("after.zip")), CONTENT)


if __name__ == "__main__":
    if not all((YAZI, YA, SEVEN)):
        raise SystemExit("yazi, ya and 7-Zip must be in PATH")
    print(subprocess.check_output([YAZI, "--version"], text=True), flush=True)
    print("Tools:", TOOLS, flush=True)
    unittest.main(verbosity=2, failfast=True)
