# The Choicer Voicer — Online Multiplayer Mod

Play The Choicer Voicer with up to 4 people online. Everyone records on their
own mic, on their own PC, and the show stays in sync. One contestant performs at
a time, the host clicks through the dialogue for everyone, and scores are worked
out in one place so you don't end up looking at different leaderboards.

Works for the normal game show and for dub mode, where you take turns on
alternating clips and then watch the finished dub together.

## You need to own the game

There's no game in this repo. No code, no assets, no exe. Just the netcode I
wrote, a set of patches, and a script that builds the mod using the copy of the
game you already bought.

The installer never downloads the game. It decompiles your own copy, on your
own PC, applies the mod, and builds you a new exe next to it.

Get the game here first: https://yeahmaybe.itch.io/the-choicer-voicer

## Installing

Download this repo as a zip, unzip it anywhere, and **double-click
`Install.bat`**. That's it.

It'll find your copy of the game on its own (it checks Steam, itch, Downloads
and Desktop). If it finds more than one it'll ask which. If it can't find any,
you can drag your game exe straight onto `Install.bat` instead, or paste the
path when it asks.

You don't need Python. If you haven't got it, the installer grabs a small copy
into `.cache` and uses that. Nothing gets installed on your system.

It downloads about 140 MB of tools ([gdRE Tools](https://github.com/GDRETools/gdsdecomp)
and [Godot](https://godotengine.org), both free and open source), builds the
mod, and drops `TheChoicerVoicer-Multiplayer.exe` in the same folder. Takes a
few minutes. Run it again later and it reuses the downloads.

Both Windows 0.5.1 builds work, Steam and itch.

Your saves, settings and packs aren't touched. The modded exe reads the same
`%APPDATA%\YeahMaybe\ChoicerVoicer` folder, so keep both exes around and launch
whichever you feel like.

### If you'd rather use a terminal

```
python install_mod.py "C:\path\to\TheChoicerVoicer_0-5-1 stable.exe"
```

| Flag | What it does |
| --- | --- |
| `-o PATH` | Where to put the modded exe |
| `--godot PATH` | Use a Godot 4.4.1 you already have |
| `--gdre PATH` | Use a `gdre_tools.exe` you already have |
| `--keep-work` | Keep the decompiled project around |
| `--project DIR` | Patch a decompiled project and stop, for modders |

## Playing

**Everyone needs the same voice packs.** This is the one that catches people
out. Scores are worked out against the clips you're performing, so everyone
needs the actual clip files the host picks. Copy the host's
`%APPDATA%\YeahMaybe\ChoicerVoicer\game\packs_voice` folder to everyone else.
The lobby lists any differences it spots, and the mod would rather refuse to
start than let you desync halfway through a round.

Then:

1. Launch the modded exe and press **F9** at the main menu. That opens the
   online lobby. (F9 is a stopgap, there's no menu button for it yet.)
2. Host presses **Host**. Everyone else types the host's IP and presses **Join**.
3. Host presses **Start (choose clips)**, or **Start (dub mode)**, picks a pack,
   and everyone gets pulled into the match together.

It uses **UDP port 7654**. Over the internet the host has to forward that port.
If you'd rather not mess with your router, something like ZeroTier, Tailscale or
Radmin works fine, just connect on the virtual IPs. 2 to 4 players.

The host drives. They click through dialogue, replays and the end-of-round menu
for the whole table so nobody drifts out of step. When it's your turn to
perform, your mic opens on your machine and only yours.

## Why there's no drag-and-drop install

Fair question, since that's how most game mods work. The problem is that Godot
games ship as one exe with everything packed inside it, and this game's build
has the pack embedded rather than sitting next to it as a `.pck`. Godot only
looks for loose override files when there's no embedded pack, so dropping
scripts next to the exe does nothing at all. The game never reads them.

On top of that the scripts inside the pack are compiled to bytecode, not stored
as text, so there's nothing to hand-edit even if you cracked the exe open.

Which leaves rebuilding the exe, and that's what the installer does. The upside
is it's honest: no game files get passed around, and everyone builds from the
copy they paid for.

## How it works

The base game is already turn-based, so this didn't need much. A contestant's
score comes entirely from three small byte arrays of waveform data, so there's
no realtime state to sync. The mod just has to agree whose turn it is, ship one
performance per turn, and stop machines drifting apart between phases.

- ENet client/server, host is authoritative and always slot 0.
- Recorded takes get chunked, sent to everyone, and fed into the waveform as if
  they'd been recorded locally.
- Scoring happens on the host and gets published, so float rounding can't give
  two people different leaderboards.
- Phase barriers hold everyone at each stage of a round, with timeouts so one
  crashed player can't freeze the table.
- Every show carries a generation stamp. Round state is keyed by round number
  and contestant slot, and both restart at zero, so without it the leftovers of
  a finished match look identical to a fresh one.

What's in `mod/`:

```
mod/net/net_manager.gd    all the netcode, one autoload
mod/net/lobby.gd          the lobby screen, built in code
mod/net/_selftest.gd      compiles every script in the project
mod/net/_nettest.gd       headless host/client smoke test
mod/patches/*.patch       edits to 7 of the game's scripts
mod/export_presets.cfg    the Windows export preset
```

Two new files, plus about 370 changed lines across 7 game scripts. The installer
also fixes a gdRE bug that writes node paths as `$A / B`, which every decompiled
build needs whether you're modding it or not.

## Working on it

```
python install_mod.py --project path/to/decompiled
```

That patches a project in place and stops. Open it in Godot 4.4.1 from there.

The two test scripts aren't autoloads in the committed project. Register one
temporarily when you want to run it, and never both at once, because the
self-test quits the tree the moment it finishes.

```
# compile every script
godot --headless --path project

# network smoke test, two terminals
godot --headless --path project -- host
godot --headless --path project -- client
```

`_nettest.gd` covers the bug that used to make the game unplayable after one
pack: it runs a second show reusing the same contestant slot and barrier tags,
and checks the new take turns up instead of the old one.

To regenerate the patches after editing a game script, diff your project against
a clean decompile with the node-path fix applied.

## Rough edges

- Lobby is on F9, not a menu button.
- Windows 0.5.1 only. Other versions will fail with a clear error once it tries
  to patch them.
- Twitch modes are singleplayer and untouched.
- Pack differences are only checked against the clips actually picked.

## Credits

The Choicer Voicer is by **YeahMaybe**. This is an unofficial fan mod, nothing
to do with them, and not endorsed by them. All the game's code and assets stay
their copyright and none of it is in here.

My code (`mod/net/`, `install_mod.py`) is MIT, see [LICENSE](LICENSE). Built with
[Godot](https://godotengine.org) and [gdRE Tools](https://github.com/GDRETools/gdsdecomp).
