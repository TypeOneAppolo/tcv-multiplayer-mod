# The Choicer Voicer — Online Multiplayer Mod

Play The Choicer Voicer with up to four people over the internet. Everyone
records on their own microphone, on their own machine, and the show stays in
sync: one contestant performs at a time, the host drives the dialogue, and the
scores are worked out in one place so nobody sees a different leaderboard.

Works for the standard game show and for dub mode, where players take turns on
alternating clips and then watch the finished dub together.

## This repository contains no game files

**You need to own The Choicer Voicer.** This repo holds the mod's own network
code, a set of patches, and a build script. It contains no game code, no
assets, and no executable. Nothing here will let you play the game without
buying it, and that is deliberate.

The installer works on *your* copy: it decompiles the exe you already own, on
your machine, applies the mod, and builds you a modded exe. The game never
leaves your computer and is never downloaded.

Buy the game first, from YeahMaybe's official store page.
<!-- TODO: drop the real store link here before making this repo public. -->

If you have not bought it, nothing in this repo is of any use to you.

## Installing

You need [Python 3.9+](https://www.python.org/downloads/), about 3 GB of free
disk space, and your official **Windows 0.5.1** copy of the game.

```
git clone https://github.com/TypeOneAppolo/tcv-multiplayer-mod
cd tcv-multiplayer-mod
python install_mod.py "C:\path\to\TheChoicerVoicer_0-5-1 stable compatibility.exe"
```

That is the whole thing. It downloads [gdRE Tools](https://github.com/GDRETools/gdsdecomp)
and [Godot 4.4.1](https://godotengine.org) (both free and open source), decompiles
your copy, applies the mod, and writes `TheChoicerVoicer-Multiplayer.exe` next to
the script. Expect five to fifteen minutes, most of it downloading.

The downloads are kept in `.cache/` so a second run is quick. Useful flags:

| Flag | What it does |
| --- | --- |
| `-o PATH` | Where to write the modded exe |
| `--godot PATH` | Use a Godot 4.4.1 you already have |
| `--gdre PATH` | Use a `gdre_tools.exe` you already have |
| `--keep-work` | Keep the decompiled project for poking at |
| `--project DIR` | Patch an already-decompiled project and stop (for modders) |
| `--force` | Try anyway on an untested game version |

Your saves, settings and packs are untouched — the modded build reads the same
`%APPDATA%\YeahMaybe\ChoicerVoicer` folder as the original, so you can keep both
executables side by side.

## Playing

1. **Everyone needs the same voice packs.** Scores are worked out against the
   clips being played, so every player needs the clip files the host picks.
   Copy the host's `%APPDATA%\YeahMaybe\ChoicerVoicer\game\packs_voice` folder to
   everyone else. The lobby shows a warning listing any differences, and the mod
   refuses to start a match rather than desync if someone is missing a clip the
   host chose.
2. Launch the modded exe and press **F9** on the main menu to open the online
   lobby. (F9 is a stopgap — there is no menu button for it yet.)
3. The host presses **Host**. Everyone else types the host's IP and presses
   **Join**.
4. The host presses **Start (choose clips)** for the game show, or
   **Start (dub mode)** for dub mode, picks a pack, and everyone is pulled into
   the match together.

**Networking.** The mod uses **UDP port 7654**. Over the internet the host needs
to forward that port, or everyone can use a LAN emulator such as ZeroTier,
Tailscale or Radmin and connect on the virtual addresses. Two to four players.

**Who drives.** The host clicks through the dialogue, replays and end-of-round
menu for the whole table, so everybody is looking at the same thing. Followers
watch. When it is your turn to perform, your microphone opens on your machine
and only yours.

## How the mod works

The base game is already turn-based, which makes it a good fit for a light
touch. A contestant's score comes entirely from three small byte arrays of
waveform data, so there is no realtime state to sync — the mod only has to agree
whose turn it is, ship one performance per turn, and keep everyone on the same
phase of the round.

- **Topology.** ENet client/server, host-authoritative, host is always slot 0.
- **Performances.** The recorded take is chunked and sent to every peer, then
  fed into the waveform exactly as if it had been recorded there.
- **Scoring.** Done on the host alone and published, so a float rounding
  difference cannot produce two different leaderboards.
- **Phase barriers.** Nobody leaves a stage of the round until every machine has
  arrived, with timeouts so one crashed player cannot freeze the table.
- **Sessions.** Every show carries a generation stamp. Round state is keyed by
  round number and contestant slot, both of which restart at zero, so without it
  the leftovers of a finished match are indistinguishable from a new one.

Everything lives in `mod/`:

```
mod/net/net_manager.gd    the whole netcode, one autoload
mod/net/lobby.gd          the lobby screen, built in code
mod/net/_selftest.gd      compiles every script in the project
mod/net/_nettest.gd       headless host/client smoke test
mod/patches/*.patch       edits to 7 game scripts
mod/export_presets.cfg    the Windows export preset
```

The mod adds two files and changes about 370 lines across seven of the game's
scripts. The patcher also repairs a gdRE Tools bug that writes node paths as
`$A / B`, which every decompiled build needs whether it is modded or not.

## Working on the mod

```
python install_mod.py --project path/to/decompiled --gdre ... # patch a project in place
```

Then open it in Godot 4.4.1. The two test scripts are not autoloads in the
committed project; register one temporarily to run it, and never both at once
because the self-test quits the tree as soon as it finishes.

```
# compile every script
godot --headless --path project

# network smoke test: host in one terminal, client in another
godot --headless --path project -- host
godot --headless --path project -- client
```

`_nettest.gd` covers the case that used to break the game: a second show that
reuses the same contestant slot and barrier tags, checking the new take arrives
instead of the previous show's.

To regenerate the patches after changing a game script, diff your patched
project against a clean decompile with the node-path repair applied.

## Known rough edges

- The lobby is opened with F9 rather than a menu button.
- Only the Windows 0.5.1 build is supported. Other versions will fail the
  version check, and `--force` is a gamble.
- Twitch modes are singleplayer only and untouched by this mod.
- Voice pack differences are only checked against the clips actually chosen.

## Credits and licence

The Choicer Voicer is by **YeahMaybe**. This is an unofficial fan mod, not
affiliated with or endorsed by the developer. All game code and assets remain
their copyright — none of it is included here.

The mod's own code (`mod/net/`, `install_mod.py`) is MIT licensed, see
[LICENSE](LICENSE). Built on [Godot](https://godotengine.org) and
[gdRE Tools](https://github.com/GDRETools/gdsdecomp).
