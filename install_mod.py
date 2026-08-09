#!/usr/bin/env python3
"""Build The Choicer Voicer multiplayer mod from your own copy of the game.

This mod ships no game code and no game assets. It is a set of edits that are
applied to a copy of the game you already own: the script decompiles your exe
on your machine, applies the mod, and re-exports. Nothing leaves your computer
except downloads of Godot and gdRE Tools, both free and open source.

    python install_mod.py "C:\\path\\to\\TheChoicerVoicer_0-5-1 stable compatibility.exe"

Run with --help for the other options.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = HERE / "mod"

GAME_VERSION = "0.5.1"
## Official Windows 0.5.1 builds this mod has been tested against. Both ship
## identical scripts -- they differ only in which renderer the project forces --
## so the same patches apply to either.
KNOWN_GAME_SIZES = {
    211382192: "0.5.1 compatibility build",
    211382048: "0.5.1 build",
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

## The template archive is 1.15 GB of every platform Godot supports. Exporting a
## Windows release build needs exactly one 32 MB file out of it, and GitHub's
## downloads accept range requests, so we reach in and take just that one.
TEMPLATE_MEMBER = "templates/windows_release_x86_64.exe"

EXPORT_PRESET = "Windows Desktop"
DEFAULT_OUTPUT = "TheChoicerVoicer-Multiplayer.exe"

## gdRE Tools writes node paths as `$A / B`, which is not valid GDScript -- it
## parses as division. Every decompiled build needs this before it will run, mod
## or no mod, so the fix is applied as a rule rather than shipped as a patch.
NODE_PATH_RE = re.compile(r'(\$%?[A-Za-z_]\w*)((?:\s*/\s*%?[A-Za-z_]\w*)+)')

## Added to [autoload] so the mod's network singleton exists everywhere.
AUTOLOAD_ANCHOR = 'Metro="*res://common/globals/metro.gd"'
AUTOLOAD_LINE = 'Net="*res://net/net_manager.gd"'

## Turns on Godot's file logging, so players can send you a log when something
## goes wrong online.
LOG_ANCHOR = "settings/stdout/verbose_stdout=true"
LOG_LINES = ['file_logging/enable_file_logging=true',
             'file_logging/log_path="user://logs/choicervoicer.log"',
             'file_logging/max_log_files=20']


class Failed(Exception):
    """Anything that should stop the build with a readable message."""


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

def say(step: str, msg: str) -> None:
    print(f"[{step}] {msg}", flush=True)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    ## newline="" so the LF endings the decompiler produced survive on Windows.
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


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
    except Exception as exc:  # network, TLS, 404...
        raise Failed(f"could not download {url}\n  {exc}")
    print()
    tmp.replace(dest)
    return dest


def http_range(url: str, start: int, length: int) -> bytes:
    """Fetch `length` bytes from `start`. Raises if the server ignores us."""
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
    """Pull a single file out of a remote zip without fetching the whole thing.

    Reads the zip's own index over HTTP range requests, then downloads only the
    bytes belonging to `member`. Falls back to the caller on any surprise, since
    a plain full download is always correct if slower.
    """
    import struct
    import zlib

    total = http_size(url)
    ## End-of-central-directory record lives in the last 64 KB at most.
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
    ## The local header repeats the name and may have differently sized extras,
    ## so read it rather than trusting the central directory's copy.
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
    if proc.returncode != 0:
        tail = (proc.stdout or "") + (proc.stderr or "")
        raise Failed(f"{what} failed (exit {proc.returncode})\n"
                     + "\n".join(tail.strip().splitlines()[-25:]))
    return proc


# --------------------------------------------------------------------------
# unified diff application
# --------------------------------------------------------------------------

def parse_hunks(patch_text: str) -> list[tuple[int, list[str]]]:
    """Return [(old_start_line, body_lines)] from a unified diff."""
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
            if line.startswith(("\\",)):  # "\ No newline at end of file"
                i += 1
                continue
            body.append(line)
            i += 1
        ## diff can leave one trailing empty element from the final newline.
        while body and body[-1] == "":
            body.pop()
        hunks.append((start, body))
    return hunks


def apply_patch(target: Path, patch_text: str) -> None:
    """Apply a unified diff, matching each hunk by its context.

    Deliberately strict: a hunk that cannot be located is an error rather than
    something to force through, because a half-applied script produces a build
    that compiles and then misbehaves in a match.
    """
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
            else:  # ' ' context, or '' for a blank context line
                old.append(content)
                new.append(content)

        want = start - 1 + offset
        found = -1
        ## Search outwards from where the diff said it should be, so the patch
        ## still lands if an earlier hunk changed the line count.
        for delta in range(0, 400):
            for pos in {want + delta, want - delta}:
                if 0 <= pos <= len(lines) - len(old) and lines[pos:pos + len(old)] == old:
                    found = pos
                    break
            if found >= 0:
                break
        if found < 0:
            raise Failed(f"{target.name}: hunk {index} does not match.\n"
                         "  Your game version is probably not "
                         f"{GAME_VERSION}, or the project is already patched.")
        lines[found:found + len(old)] = new
        offset += len(new) - len(old)
    write_text(target, "\n".join(lines))


# --------------------------------------------------------------------------
# build steps
# --------------------------------------------------------------------------

def steam_libraries() -> list[Path]:
    """Every Steam library folder on this machine, not just the default one."""
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
    """Guess where the player keeps the game. Best matches first."""
    candidates: list[Path] = []
    seen: set[str] = set()

    def consider(path: Path) -> None:
        key = str(path).lower()
        if key in seen or not path.is_file():
            return
        seen.add(key)
        ## Never offer a build this script produced.
        if path.name.lower() == DEFAULT_OUTPUT.lower():
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
            ## Two levels down covers "Downloads/TheChoicerVoicer 0.5.1 (Windows)/x.exe"
            for pattern in ("TheChoicerVoicer*.exe", "*/TheChoicerVoicer*.exe",
                            "*/*/TheChoicerVoicer*.exe"):
                for hit in place.glob(pattern):
                    consider(hit)
        except OSError:
            continue

    ## An exact size match is almost certainly the right build.
    candidates.sort(key=lambda p: (p.stat().st_size not in KNOWN_GAME_SIZES, str(p).lower()))
    return candidates


def choose_game_exe() -> Path:
    """Interactive pick, for when the script is double-clicked with no arguments."""
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
    """Report what we think this is. Never fatal.

    The real check is the patches themselves: every edit is matched against the
    surrounding lines of the script it belongs to, so a version this mod cannot
    handle fails clearly a few seconds later instead of building something
    subtly broken.
    """
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
        if path.is_dir():  # the release unzips to a folder of the same name
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
            ## Entries live under "templates/"; flatten that away.
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


def apply_mod(work: Path) -> None:
    if (work / "net" / "net_manager.gd").exists():
        raise Failed("this project already contains the mod")

    say("mod", f"repaired {repair_node_paths(work)} decompiler node-path artifacts")

    shutil.copytree(MOD / "net", work / "net", dirs_exist_ok=True)
    say("mod", "added net/net_manager.gd, net/lobby.gd")

    count = 0
    for patch in sorted((MOD / "patches").glob("*.patch")):
        rel = patch.name[: -len(".patch")].replace("__", "/")
        target = work / rel
        if not target.is_file():
            raise Failed(f"expected game file missing: {rel}")
        apply_patch(target, read_text(patch))
        count += 1
    say("mod", f"patched {count} game scripts")

    patch_project_godot(work)
    shutil.copy2(MOD / "export_presets.cfg", work / "export_presets.cfg")
    say("mod", "registered the Net autoload and export preset")


def export(godot: Path, work: Path, output: Path) -> None:
    ## A freshly decompiled project has no .godot/, so assets must be imported
    ## before anything can be exported. --import is the 4.4 way; the editor
    ## round trip is the fallback for builds that predate it.
    say("build", "importing project assets (this takes a minute)")
    probe = subprocess.run([str(godot), "--headless", "--path", str(work), "--import"],
                           capture_output=True, text=True, errors="replace")
    if probe.returncode != 0:
        run([str(godot), "--headless", "--path", str(work), "--editor", "--quit"],
            "importing the project")

    output.parent.mkdir(parents=True, exist_ok=True)
    say("build", f"exporting to {output}")
    run([str(godot), "--headless", "--path", str(work),
         "--export-release", EXPORT_PRESET, str(output.resolve())],
        "exporting the game")
    if not output.is_file():
        raise Failed("the export reported success but produced no file")


# --------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Build The Choicer Voicer multiplayer mod from your own copy of the game.",
        epilog="You need to own the game. This tool never downloads it.")
    ap.add_argument("game_exe", nargs="?",
                    help="your official TheChoicerVoicer 0.5.1 Windows exe")
    ap.add_argument("-o", "--output", default=DEFAULT_OUTPUT,
                    help=f"where to write the modded exe (default: {DEFAULT_OUTPUT})")
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

    if not MOD.is_dir():
        raise Failed(f"mod/ folder missing next to {Path(__file__).name}")

    cache = Path(args.cache)
    work = Path(args.work)

    ## Modder mode: patch a project directory in place, no exe, no export.
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
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Failed as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
