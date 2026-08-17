#!/usr/bin/env python3
"""Build the The Choicer Voicer multiplayer mod from a copy of the game you own.

    python install_mod.py "C:\\path\\to\\TheChoicerVoicer_0-5-1 stable compatibility.exe"

Run with --help for the other options.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import time
import traceback
import urllib.request
import webbrowser
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = HERE / "mod"

SUPPORTED_VERSIONS = ["0.5.1", "0.5.2"]
GAME_VERSION = " or ".join(SUPPORTED_VERSIONS)

KNOWN_GAME_SIZES = {
    211382192: "0.5.1 compatibility build",
    211382048: "0.5.1 build",
    199462432: "0.5.2 dev-2 compatibility build",
    208463056: "0.5.2 compatibility build",
    208462000: "0.5.2 standard build",
}

GODOT_VERSION = "4.4.1-stable"
GODOT_TEMPLATE_DIR_NAME = "4.4.1.stable"
GODOT_URL = ("https://github.com/godotengine/godot-builds/releases/download/"
             "4.4.1-stable/Godot_v4.4.1-stable_win64.exe.zip")
TEMPLATES_URL = ("https://github.com/godotengine/godot-builds/releases/download/"
                 "4.4.1-stable/Godot_v4.4.1-stable_export_templates.tpz")
GDRE_VERSION = "v2.6.3"
GDRE_URL = ("https://github.com/GDRETools/gdsdecomp/releases/download/"
            "v2.6.3/GDRE_tools-v2.6.3-windows.zip")

TEMPLATE_MEMBER = "templates/windows_release_x86_64.exe"

EXPORT_PRESET = "Windows Desktop"
OUTPUT_STEM = "TheChoicerVoicer-Multiplayer"

DISCORD_URL = "https://discord.gg/HYhh6V4NZk"
ISSUES_URL = "https://github.com/TypeOneAppolo/tcv-multiplayer-mod/issues"

RUN_LOG_DIR = HERE / "install_logs"

NODE_PATH_RE = re.compile(r'(\$%?[A-Za-z_]\w*)((?:\s*/\s*%?[A-Za-z_]\w*)+)')

AUTOLOAD_ANCHOR = 'Metro="*res://common/globals/metro.gd"'
AUTOLOAD_LINE = 'Net="*res://net/net_manager.gd"'

LOG_ANCHOR = "settings/stdout/verbose_stdout=true"
LOG_LINES = ['file_logging/enable_file_logging=true',
             'file_logging/log_path="user://logs/choicervoicer.log"',
             'file_logging/max_log_files=20']


class Failed(Exception):
    pass


def say(step: str, msg: str) -> None:
    print(f"[{step}] {msg}", flush=True)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def mod_version() -> str:
    """The mod's own version, straight off the constant the lobby shows.

    One source of truth on purpose. The number on the exe is the number two
    people compare when one of them can't join the other, and a name that had to
    be kept in step by hand would eventually stop being."""
    try:
        text = read_text(MOD / "net" / "net_manager.gd")
    except OSError:
        return ""
    match = re.search(r'const\s+MOD_VERSION\s*:\s*String\s*=\s*"([^"]+)"', text)
    return match.group(1) if match else ""


MOD_VERSION = mod_version()
# the version goes on the end so the file sorts next to its neighbours and so
# nobody has to open a build to find out which one it is.
DEFAULT_OUTPUT = f"{OUTPUT_STEM}-{MOD_VERSION}.exe" if MOD_VERSION else f"{OUTPUT_STEM}.exe"


def _https_context() -> ssl.SSLContext | None:
    if os.environ.get("TCV_INSECURE_SSL") == "1":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    try:
        import truststore
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception:
        pass
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    return None


def install_https_opener() -> None:
    ctx = _https_context()
    if ctx is not None:
        handler = urllib.request.HTTPSHandler(context=ctx)
        urllib.request.install_opener(urllib.request.build_opener(handler))


def _tls_hint(exc: Exception) -> str:
    if "CERTIFICATE_VERIFY" not in str(exc):
        return ""
    return (
        "\n\n  This is a TLS certificate error, not a problem with the mod.\n"
        "  Your Python can't verify GitHub's certificate. Fixes, easiest first:\n"
        "    1. pip install certifi truststore   then run this again.\n"
        "    2. If your network or antivirus inspects HTTPS, truststore (above)\n"
        "       picks up its root from the Windows store once installed.\n"
        "    3. Last resort, skip verification for this run:\n"
        "         set TCV_INSECURE_SSL=1     (cmd)\n"
        "         $env:TCV_INSECURE_SSL=1    (PowerShell)\n"
        "       then re-run."
    )


def download(url: str, dest: Path) -> Path:
    if dest.exists() and dest.stat().st_size > 0:
        say("cache", f"already have {dest.name}")
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    say("get", url.rsplit("/", 1)[-1])
    seen = [0]

    def hook(count: int, block: int, total: int) -> None:
        seen[0] = count * block
        if total > 0:
            pct = min(100, seen[0] * 100 // total)
            print(f"\r      {pct:3d}%  ({seen[0] // 1048576} / {total // 1048576} MB)",
                  end="", flush=True)

    try:
        urllib.request.urlretrieve(url, tmp, hook)
    except Exception as exc:
        raise Failed(f"could not download {url}\n  {exc}{_tls_hint(exc)}")
    print()
    tmp.replace(dest)
    return dest


def http_range(url: str, start: int, length: int) -> bytes:
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + length - 1}"})
    with urllib.request.urlopen(req) as resp:
        if resp.status != 206:
            raise Failed("the download server would not serve a partial file")
        return resp.read()


def http_size(url: str) -> int:
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req) as resp:
        return int(resp.headers["Content-Length"])


def download_zip_member(url: str, member: str, dest: Path) -> None:
    import struct
    import zlib

    total = http_size(url)
    tail_len = min(65536 + 22, total)
    tail = http_range(url, total - tail_len, tail_len)
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise Failed("could not read the archive index")
    cd_size, cd_offset = struct.unpack("<II", tail[eocd + 12:eocd + 20])
    if cd_offset == 0xFFFFFFFF:
        raise Failed("zip64 archive, not supported here")

    cd = http_range(url, cd_offset, cd_size)
    pos = 0
    found = None
    while pos < len(cd) - 4 and cd[pos:pos + 4] == b"PK\x01\x02":
        method, = struct.unpack("<H", cd[pos + 10:pos + 12])
        comp_size, uncomp_size = struct.unpack("<II", cd[pos + 20:pos + 28])
        name_len, extra_len, comment_len = struct.unpack("<HHH", cd[pos + 28:pos + 34])
        local_offset, = struct.unpack("<I", cd[pos + 42:pos + 46])
        name = cd[pos + 46:pos + 46 + name_len].decode("utf-8", "replace")
        if name == member:
            found = (method, comp_size, uncomp_size, local_offset)
            break
        pos += 46 + name_len + extra_len + comment_len
    if not found:
        raise Failed(f"{member} is not in the archive")

    method, comp_size, uncomp_size, local_offset = found
    head = http_range(url, local_offset, 30)
    if head[:4] != b"PK\x03\x04":
        raise Failed("archive index points at nothing")
    lname_len, lextra_len = struct.unpack("<HH", head[26:30])
    data_at = local_offset + 30 + lname_len + lextra_len

    say("get", f"{member.rsplit('/', 1)[-1]} ({comp_size // 1048576} MB "
               f"instead of {total // 1048576} MB)")
    blob = http_range(url, data_at, comp_size)
    if method == 0:
        raw = blob
    elif method == 8:
        raw = zlib.decompress(blob, -15)
    else:
        raise Failed(f"unsupported compression method {method}")
    if len(raw) != uncomp_size:
        raise Failed("the extracted file is the wrong size")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(raw)


def unzip(archive: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        zf.extractall(dest)


def run(cmd: list[str], what: str) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    log_subprocess(what, cmd, proc)
    if proc.returncode != 0:
        tail = (proc.stdout or "") + (proc.stderr or "")
        raise Failed(f"{what} failed (exit {proc.returncode})\n"
                     + "\n".join(tail.strip().splitlines()[-25:]))
    return proc


# --- debug logging & diagnostics ------------------------------------------
#
# Every run gets its own timestamped log with the full output of every
# external tool it called, not just the tail printed on screen when
# something goes wrong. On failure -- expected or not -- that log gets
# bundled with the game's own logs into a zip a user can drag straight onto
# a GitHub issue. "It didn't work" turns into a report someone can act on
# without a back-and-forth to ask what actually happened.

CURRENT_RUN_LOG: Path | None = None
_LOG_FH = None


class _Tee:
    """Mirrors writes to several streams at once, e.g. the real console and a
    log file, so nothing printed during a run is only ever seen once."""

    def __init__(self, *streams) -> None:
        self.streams = streams

    def write(self, data: str) -> int:
        for stream in self.streams:
            try:
                stream.write(data)
            except Exception:
                pass
        return len(data)

    def flush(self) -> None:
        for stream in self.streams:
            try:
                stream.flush()
            except Exception:
                pass

    def isatty(self) -> bool:
        return bool(self.streams) and self.streams[0].isatty()


def game_log_dir() -> Path | None:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return None
    path = Path(appdata) / "YeahMaybe" / "ChoicerVoicer" / "logs"
    return path if path.is_dir() else None


def start_run_log() -> None:
    """Best-effort: a machine where this can't be set up still gets to run
    the installer, it just won't have a log to show for it afterwards."""
    global CURRENT_RUN_LOG, _LOG_FH
    try:
        RUN_LOG_DIR.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = RUN_LOG_DIR / f"install-{stamp}.log"
        fh = open(path, "w", encoding="utf-8", errors="replace")
        fh.write("The Choicer Voicer multiplayer mod installer -- log started "
                  f"{stamp}\n")
        fh.write(f"mod version:  {MOD_VERSION or '(unknown)'}\n")
        fh.write(f"python:       {sys.version.split()[0]}\n")
        fh.write(f"platform:     {platform.platform()}\n")
        fh.write(f"command line: {' '.join(sys.argv)}\n")
        fh.write("-" * 70 + "\n\n")
        fh.flush()
    except OSError:
        return

    CURRENT_RUN_LOG = path
    _LOG_FH = fh
    sys.stdout = _Tee(sys.stdout, fh)
    sys.stderr = _Tee(sys.stderr, fh)

    for stale in sorted(RUN_LOG_DIR.glob("install-*.log"),
                        key=lambda p: p.stat().st_mtime, reverse=True)[10:]:
        try:
            stale.unlink()
        except OSError:
            pass


def log_subprocess(what: str, cmd: list[str], proc: subprocess.CompletedProcess) -> None:
    """The console only ever sees the last few lines of a failed command --
    the full output of everything run, pass or fail, goes straight to the log
    file instead of the screen so it's there later without cluttering now."""
    if not _LOG_FH:
        return
    try:
        _LOG_FH.write(f"\n$ {what}\n  {' '.join(cmd)}\n  exit code: {proc.returncode}\n")
        if proc.stdout:
            _LOG_FH.write("  --- stdout ---\n" + proc.stdout)
            if not proc.stdout.endswith("\n"):
                _LOG_FH.write("\n")
        if proc.stderr:
            _LOG_FH.write("  --- stderr ---\n" + proc.stderr)
            if not proc.stderr.endswith("\n"):
                _LOG_FH.write("\n")
        _LOG_FH.flush()
    except OSError:
        pass


def zip_diagnostics() -> Path | None:
    """Bundles this run's log (plus a few recent ones), the game's own logs,
    and a note on where to send it all into one zip. Returns None if there
    was nothing worth zipping."""
    desktop = Path.home() / "Desktop"
    out_dir = desktop if desktop.is_dir() else HERE
    zip_path = out_dir / f"tcv-diagnostics-{time.strftime('%Y%m%d-%H%M%S')}.zip"

    added_anything = False
    try:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            if _LOG_FH:
                try:
                    _LOG_FH.flush()
                except OSError:
                    pass
            logs = sorted(RUN_LOG_DIR.glob("install-*.log"),
                          key=lambda p: p.stat().st_mtime, reverse=True)[:5]
            for log in logs:
                zf.write(log, f"install_log/{log.name}")
                added_anything = True

            game_logs = game_log_dir()
            if game_logs:
                for f in game_logs.rglob("*"):
                    if f.is_file():
                        zf.write(f, f"game_logs/{f.relative_to(game_logs)}")
                        added_anything = True

            zf.writestr("README.txt",
                "What's in here\n"
                "---------------\n"
                "install_log/  -- what the multiplayer mod installer did and said,\n"
                "                 most recent run(s) first.\n"
                "game_logs/    -- the game's own logs, straight from\n"
                "                 %APPDATA%\\YeahMaybe\\ChoicerVoicer\\logs\\, with\n"
                "                 [NET] lines showing what the multiplayer mod did.\n"
                "\n"
                f"Attach this zip to an issue: {ISSUES_URL}\n")
    except OSError:
        return None

    return zip_path if added_anything else None


def parse_hunks(patch_text: str) -> list[tuple[int, list[str]]]:
    lines = patch_text.split("\n")
    hunks: list[tuple[int, list[str]]] = []
    i = 0
    while i < len(lines):
        head = re.match(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", lines[i])
        if not head:
            i += 1
            continue
        start = int(head.group(1))
        body: list[str] = []
        i += 1
        while i < len(lines):
            line = lines[i]
            if line.startswith("@@") or line.startswith("--- ") or line.startswith("+++ "):
                break
            if line.startswith(("\\",)):
                i += 1
                continue
            body.append(line)
            i += 1
        while body and body[-1] == "":
            body.pop()
        hunks.append((start, body))
    return hunks


def apply_patch(target: Path, patch_text: str, version: str = "") -> None:
    lines = read_text(target).split("\n")
    offset = 0
    for index, (start, body) in enumerate(parse_hunks(patch_text), 1):
        old: list[str] = []
        new: list[str] = []
        for raw in body:
            tag, content = raw[:1], raw[1:]
            if tag == "-":
                old.append(content)
            elif tag == "+":
                new.append(content)
            else:
                old.append(content)
                new.append(content)

        want = start - 1 + offset
        found = -1
        for delta in range(0, 400):
            for pos in {want + delta, want - delta}:
                if 0 <= pos <= len(lines) - len(old) and lines[pos:pos + len(old)] == old:
                    found = pos
                    break
            if found >= 0:
                break
        if found < 0:
            raise Failed(f"{target.name}: hunk {index} does not match.\n"
                         f"  This build looks like {version or 'an unknown version'}, "
                         "but its scripts are not what the mod expects.\n"
                         "  Either it is a version this mod has not caught up with, "
                         "or the project is already patched.")
        lines[found:found + len(old)] = new
        offset += len(new) - len(old)
    write_text(target, "\n".join(lines))


def steam_libraries() -> list[Path]:
    roots: list[Path] = []
    for env in ("ProgramFiles(x86)", "ProgramFiles"):
        base = os.environ.get(env)
        if base:
            roots.append(Path(base) / "Steam")
    home = os.environ.get("LOCALAPPDATA")
    if home:
        roots.append(Path(home) / "Steam")

    libs: list[Path] = []
    for root in roots:
        apps = root / "steamapps"
        if apps.is_dir():
            libs.append(apps / "common")
        vdf = apps / "libraryfolders.vdf"
        if vdf.is_file():
            try:
                for match in re.finditer(r'"path"\s+"([^"]+)"', read_text(vdf)):
                    libs.append(Path(match.group(1).replace("\\\\", "\\")) / "steamapps" / "common")
            except OSError:
                pass
    return [lib for lib in libs if lib.is_dir()]


def find_game_exe() -> list[Path]:
    candidates: list[Path] = []
    seen: set[str] = set()

    def consider(path: Path) -> None:
        key = str(path).lower()
        if key in seen or not path.is_file():
            return
        seen.add(key)
        # anything we built ourselves, whichever version is on the end of it.
        if path.stem.lower().startswith(OUTPUT_STEM.lower()):
            return
        candidates.append(path)

    places = list(steam_libraries())
    home = Path.home()
    places += [home / "Downloads", home / "Desktop", home / "Documents", Path.cwd()]
    local = os.environ.get("LOCALAPPDATA")
    if local:
        places.append(Path(local) / "itch" / "apps")

    for place in places:
        if not place.is_dir():
            continue
        try:
            for pattern in ("TheChoicerVoicer*.exe", "*/TheChoicerVoicer*.exe",
                            "*/*/TheChoicerVoicer*.exe"):
                for hit in place.glob(pattern):
                    consider(hit)
        except OSError:
            continue

    candidates.sort(key=lambda p: (p.stat().st_size not in KNOWN_GAME_SIZES, str(p).lower()))
    return candidates


def choose_game_exe() -> Path:
    print("Looking for your copy of the game...")
    found = find_game_exe()

    if len(found) == 1 and found[0].stat().st_size in KNOWN_GAME_SIZES:
        print(f"Found: {found[0]}")
        return found[0]

    if found:
        print("\nWhich copy of the game should I use?\n")
        for i, path in enumerate(found[:9], 1):
            tag = "" if path.stat().st_size in KNOWN_GAME_SIZES else "   (untested version)"
            print(f"  {i}. {path}{tag}")
        print("  0. none of these, let me type the path\n")
        answer = input("Number: ").strip()
        if answer.isdigit() and 1 <= int(answer) <= len(found[:9]):
            return found[int(answer) - 1]
    else:
        print("No copy found automatically.\n")

    print("Drag your game exe onto this window and press Enter,")
    print("or paste the full path to it.\n")
    typed = input("Game exe: ").strip().strip('"')
    if not typed:
        raise Failed("no game exe given")
    return Path(typed)


def check_game_exe(exe: Path) -> None:
    if not exe.is_file():
        raise Failed(f"no such file: {exe}")
    known = KNOWN_GAME_SIZES.get(exe.stat().st_size)
    if known:
        say("game", f"{exe.name} looks like the {known}")
    else:
        say("warn", f"{exe.name} is not a build this mod has been tested against.\n"
                    f"        Trying anyway. Expect a clear error shortly if it is "
                    f"not Windows {GAME_VERSION}.")


def get_gdre(cache: Path, supplied: str | None) -> Path:
    if supplied:
        path = Path(supplied)
        if not path.is_file():
            raise Failed(f"--gdre {path} does not exist")
        return path
    archive = download(GDRE_URL, cache / f"gdre-{GDRE_VERSION}.zip")
    out = cache / f"gdre-{GDRE_VERSION}"
    if not out.exists():
        unzip(archive, out)
    for candidate in out.rglob("gdre_tools.exe"):
        return candidate
    raise Failed("gdre_tools.exe not found inside the downloaded archive")


def get_godot(cache: Path, supplied: str | None) -> Path:
    if supplied:
        path = Path(supplied)
        if path.is_dir():
            inner = list(path.glob("Godot_v*_win64.exe"))
            if inner:
                return inner[0]
        if not path.is_file():
            raise Failed(f"--godot {path} does not exist")
        return path
    archive = download(GODOT_URL, cache / f"godot-{GODOT_VERSION}.zip")
    out = cache / f"godot-{GODOT_VERSION}"
    if not out.exists():
        unzip(archive, out)
    for candidate in out.rglob("Godot_v*_win64.exe"):
        if "console" not in candidate.name:
            return candidate
    raise Failed("Godot executable not found inside the downloaded archive")


def templates_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "Godot" / "export_templates" / GODOT_TEMPLATE_DIR_NAME
    return (Path.home() / ".local" / "share" / "godot" / "export_templates"
            / GODOT_TEMPLATE_DIR_NAME)


def install_full_templates(cache: Path, dest: Path) -> None:
    archive = download(TEMPLATES_URL, cache / f"godot-templates-{GODOT_VERSION}.tpz")
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        for entry in zf.namelist():
            if entry.endswith("/"):
                continue
            name = entry.split("/", 1)[1] if "/" in entry else entry
            with zf.open(entry) as src, open(dest / name, "wb") as dst:
                shutil.copyfileobj(src, dst)


def ensure_templates(cache: Path) -> None:
    dest = templates_dir()
    wanted = dest / TEMPLATE_MEMBER.rsplit("/", 1)[-1]
    if wanted.is_file():
        say("skip", f"export template already installed in {dest}")
        return
    try:
        download_zip_member(TEMPLATES_URL, TEMPLATE_MEMBER, wanted)
    except Exception as exc:
        say("warn", f"could not grab just the one template ({exc}); "
                    "falling back to the full 1.1 GB archive")
        install_full_templates(cache, dest)


def decompile(gdre: Path, exe: Path, work: Path) -> None:
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    run([str(gdre), "--headless", f"--recover={exe}", f"--output-dir={work}"],
        "decompiling the game")
    if not (work / "project.godot").is_file():
        raise Failed("decompile produced no project.godot -- is that the game exe?")


def repair_node_paths(work: Path) -> int:
    fixed = 0
    for path in work.rglob("*.gd"):
        text = read_text(path)
        patched = NODE_PATH_RE.sub(
            lambda m: m.group(1) + re.sub(r"\s*/\s*", "/", m.group(2)), text)
        if patched != text:
            write_text(path, patched)
            fixed += 1
    return fixed


def patch_project_godot(work: Path) -> None:
    path = work / "project.godot"
    text = read_text(path)
    if AUTOLOAD_LINE in text:
        raise Failed("project.godot already has the Net autoload -- "
                     "this project is already patched")
    if AUTOLOAD_ANCHOR not in text:
        raise Failed("project.godot has no Metro autoload to anchor to; "
                     "unexpected game version")
    text = text.replace(AUTOLOAD_ANCHOR, AUTOLOAD_ANCHOR + "\n" + AUTOLOAD_LINE, 1)
    if LOG_ANCHOR in text and LOG_LINES[0] not in text:
        text = text.replace(LOG_ANCHOR, "\n".join([LOG_ANCHOR] + LOG_LINES), 1)
    write_text(path, text)


def detect_version(work: Path) -> str:
    match = re.search(r'config/version="([^"]+)"', read_text(work / "project.godot"))
    if not match:
        raise Failed("project.godot has no config/version -- unexpected game build")
    return match.group(1)


def patch_set_for(version: str) -> list[Path]:
    version_dir = MOD / "patches" / ("v" + version.replace(".", "_"))
    if not version_dir.is_dir():
        raise Failed(
            f"this build reports version {version}, which the mod does not "
            f"handle yet.\n  Supported: {', '.join(SUPPORTED_VERSIONS)}.")
    return sorted((MOD / "patches" / "common").glob("*.patch")) + \
        sorted(version_dir.glob("*.patch"))


def apply_mod(work: Path) -> None:
    if (work / "net" / "net_manager.gd").exists():
        raise Failed("this project already contains the mod")

    version = detect_version(work)
    say("mod", f"project reports version {version}")

    say("mod", f"repaired {repair_node_paths(work)} decompiler node-path artifacts")

    shutil.copytree(MOD / "net", work / "net", dirs_exist_ok=True)
    say("mod", "added multiplayer, pack sharing and community pack browser scripts")

    count = 0
    for patch in patch_set_for(version):
        rel = patch.name[: -len(".patch")].replace("__", "/")
        target = work / rel
        if not target.is_file():
            raise Failed(f"expected game file missing: {rel}")
        apply_patch(target, read_text(patch), version)
        count += 1
    say("mod", f"patched {count} game scripts")

    patch_project_godot(work)
    write_export_preset(work)
    say("mod", "registered the Net autoload and export preset")


def write_export_preset(work: Path) -> None:
    """The exporter is told where to put the build on the command line, so this
    path only matters to a modder who opens the project and hits Export. Stamp
    the version on it there too rather than leaving them the one name that says
    nothing."""
    text = read_text(MOD / "export_presets.cfg")
    if MOD_VERSION:
        text = text.replace(f'export_path="{OUTPUT_STEM}.exe"',
                            f'export_path="{DEFAULT_OUTPUT}"', 1)
    write_text(work / "export_presets.cfg", text)


def powershell(script: str, timeout: int = 30) -> str:
    exe = shutil.which("powershell") or shutil.which("pwsh")
    if not exe:
        return ""
    try:
        proc = subprocess.run([exe, "-NoProfile", "-NonInteractive", "-Command", script],
                              capture_output=True, text=True, errors="replace",
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return proc.stdout.strip()


def defender_detections(output: Path) -> list[str]:
    """Recent Defender detections that name our build. Empty if it isn't Defender."""
    raw = powershell(
        "Get-MpThreatDetection -ErrorAction SilentlyContinue | "
        "Sort-Object InitialDetectionTime | Select-Object -Last 12 | ForEach-Object { "
        "\"$($_.InitialDetectionTime)  $($_.ThreatName)  $($_.Resources -join ' ')\" }")
    stem = output.stem.lower()
    return [line.strip() for line in raw.splitlines() if stem in line.lower()]


def realtime_protection_on() -> bool:
    answer = powershell("(Get-MpComputerStatus -ErrorAction SilentlyContinue)"
                        ".RealTimeProtectionEnabled")
    return answer.strip().lower() == "true"


def recover_leftover_build(output: Path, work: Path) -> bool:
    """Godot builds to <name>.tmp and renames it at the very end. If that rename
    lost a race, the whole build is sitting right there under the wrong name."""
    for stray in (output.with_suffix(".tmp"), work / (output.stem + ".tmp")):
        if stray.is_file() and stray.stat().st_size > 1048576:
            stray.replace(output)
            say("build", f"the exporter left the build as {stray.name}; renamed it")
            return True
    return False


def explain_missing_export(proc: subprocess.CompletedProcess, output: Path) -> None:
    tail = ((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()
    interesting = [line for line in tail
                   if "ERROR" in line or "error" in line or "Failed" in line]
    if interesting:
        print("\nGodot said:")
        for line in interesting[-8:]:
            print(f"  {line}")

    print(f"\nGodot finished without complaining, but {output.name} is not there.")

    hits = defender_detections(output)
    if hits:
        print("\nWindows Defender deleted it. Its own log says so:")
        for line in hits[-3:]:
            print(f"  {line}")
    elif realtime_protection_on():
        print("\nAlmost always this is antivirus. A freshly built, unsigned Godot game")
        print("looks exactly like the thing malware scanners are trained to catch, and")
        print("Defender quarantines it the moment the file is renamed to .exe.")
    else:
        print("\nUsually this is antivirus quarantining the new .exe the instant it")
        print("appears. Check whatever scanner you run for a blocked item.")

    folder = output.resolve().parent
    print("\nTo let it through, open PowerShell as administrator and run:")
    print(f'  Add-MpPreference -ExclusionPath "{folder}"')
    print("\nIf Defender already took a copy, release it too:")
    print("  Start-Process ms-settings:windowsdefender")
    print("  (Virus & threat protection -> Protection history -> Allow)")
    print("\nThe exclusion only covers that one folder, and you can drop it again")
    print(f'afterwards with Remove-MpPreference -ExclusionPath "{folder}".')


def export(godot: Path, work: Path, output: Path) -> None:
    say("build", "importing project assets (this takes a minute)")
    import_cmd = [str(godot), "--headless", "--path", str(work), "--import"]
    probe = subprocess.run(import_cmd, capture_output=True, text=True, errors="replace")
    log_subprocess("checking whether the project needs a one-time editor import",
                   import_cmd, probe)
    if probe.returncode != 0:
        run([str(godot), "--headless", "--path", str(work), "--editor", "--quit"],
            "importing the project")

    output.parent.mkdir(parents=True, exist_ok=True)
    while True:
        say("build", f"exporting to {output}")
        proc = run([str(godot), "--headless", "--path", str(work),
                    "--export-release", EXPORT_PRESET, str(output.resolve())],
                   "exporting the game")
        if output.is_file() or recover_leftover_build(output, work):
            return
        explain_missing_export(proc, output)
        if not sys.stdin.isatty():
            raise Failed("the export produced no file -- see the notes above")
        print()
        if input("Press Enter to build again once that's done, or type q to give up: "
                 ).strip().lower().startswith("q"):
            raise Failed("the export produced no file -- see the notes above")


def open_the_discord() -> None:
    """Nobody plays this on their own, and half of what goes wrong is somebody
    on the wrong build or the wrong voice packs -- both of which take one message
    to sort out and an evening to work out alone. The link is printed either way,
    so a machine with no browser to open loses nothing."""
    print(f"\nCome say hello, find people to play with, or shout at me when it breaks:")
    print(f"  {DISCORD_URL}")
    try:
        opened = webbrowser.open(DISCORD_URL)
    except Exception:
        opened = False
    if opened:
        print("  (opening that in your browser now)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Build The Choicer Voicer multiplayer mod from your own copy of the game.",
        epilog="You need to own the game. This tool never downloads it.")
    ap.add_argument("game_exe", nargs="?",
                    help="your official TheChoicerVoicer Windows exe "
                         f"({' or '.join(SUPPORTED_VERSIONS)})")
    ap.add_argument("-o", "--output", default=DEFAULT_OUTPUT,
                    help=f"where to write the modded exe (default: {DEFAULT_OUTPUT})")
    ap.add_argument("--no-discord", action="store_true",
                    help="don't open the Discord invite when the build finishes")
    ap.add_argument("--zip-logs", action="store_true",
                    help="bundle this tool's logs and the game's own logs into a zip "
                         "you can attach to a GitHub issue, then exit -- no game exe "
                         "needed")
    ap.add_argument("--project", metavar="DIR",
                    help="patch an already-decompiled project instead of an exe, "
                         "and stop before exporting (for modders)")
    ap.add_argument("--godot", help="path to Godot 4.4.1 instead of downloading it")
    ap.add_argument("--gdre", help="path to gdre_tools.exe instead of downloading it")
    ap.add_argument("--cache", default=str(HERE / ".cache"),
                    help="where downloads are kept between runs")
    ap.add_argument("--work", default=str(HERE / "work"),
                    help="scratch directory for the decompiled project")
    ap.add_argument("--keep-work", action="store_true",
                    help="do not delete the decompiled project afterwards")
    args = ap.parse_args(argv)

    install_https_opener()

    if args.zip_logs:
        bundle = zip_diagnostics()
        if bundle:
            print(f"Saved a diagnostics zip:\n  {bundle}")
            print(f"\nAttach it to an issue: {ISSUES_URL}")
        else:
            checked = game_log_dir() or (Path(os.environ.get("APPDATA", ""))
                                         / "YeahMaybe" / "ChoicerVoicer" / "logs")
            print("Nothing to zip yet -- no installer logs and no game logs found at")
            print(f"  {checked}")
        return 0

    if not MOD.is_dir():
        raise Failed(f"mod/ folder missing next to {Path(__file__).name}")

    cache = Path(args.cache)
    work = Path(args.work)

    if args.project:
        work = Path(args.project)
        if not (work / "project.godot").is_file():
            raise Failed(f"{work} is not a Godot project")
        apply_mod(work)
        print(f"\nPatched {work}. Open it in Godot {GODOT_VERSION} and export.")
        return 0

    exe = Path(args.game_exe) if args.game_exe else choose_game_exe()
    check_game_exe(exe)

    say("1/5", "getting gdRE Tools")
    gdre = get_gdre(cache, args.gdre)

    say("2/5", "decompiling your copy of the game")
    decompile(gdre, exe, work)

    say("3/5", "applying the multiplayer mod")
    apply_mod(work)

    say("4/5", "getting Godot and export templates")
    godot = get_godot(cache, args.godot)
    ensure_templates(cache)

    say("5/5", "building")
    output = Path(args.output)
    export(godot, work, output)

    if not args.keep_work:
        shutil.rmtree(work, ignore_errors=True)

    size = output.stat().st_size
    print(f"\nDone -> {output.resolve()}  ({size // 1048576} MB)")
    print("Launch it, press F9 on the main menu to open the online lobby.")
    print("Everyone you play with needs to build this same version themselves.")
    if not args.no_discord:
        open_the_discord()
    return 0


def _report_failure() -> None:
    """A message on its own means someone has to copy-paste the error and
    then get asked "what were you running it against" anyway. Handing back a
    ready-made zip skips that whole round trip."""
    try:
        bundle = zip_diagnostics()
    except Exception:
        bundle = None
    if bundle:
        print(f"\nSaved a diagnostics zip you can attach to an issue:\n  {bundle}",
              file=sys.stderr)
        print(f"Open one here: {ISSUES_URL}", file=sys.stderr)


if __name__ == "__main__":
    start_run_log()
    try:
        sys.exit(main(sys.argv[1:]))
    except Failed as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        _report_failure()
        sys.exit(1)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
    except Exception:
        print("\nERROR: something went wrong that the installer didn't expect.",
              file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        _report_failure()
        sys.exit(1)
