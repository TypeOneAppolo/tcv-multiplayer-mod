# The Choicer Voicer Online Multiplayer

<p align="center">
  <a href="https://ko-fi.com/appolodev">
    <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy me a coffee on Ko-fi" height="40">
  </a>
  &nbsp;
  <a href="https://ko-fi.com/appolodev/goal?g=0">
    <img src="https://img.shields.io/badge/Ko--fi-see%20the%20goal-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white" alt="Ko-fi goal" height="40">
  </a>
</p>

<p align="center">
  <em>This mod is free and always will be. If it got your group playing together,
  a coffee helps me keep working on it.</em>
</p>

Play The Choicer Voicer with up to 4 people online. Everyone records on their own
mic on their own pc and it all stays in sync, so one person performs at a time,
the host clicks through the dialogue for everybody, and the scores get worked out
in one place so you're not all sat looking at different numbers.

Works for the normal game show and for dub mode, where you take turns on
alternating clips and then watch the finished thing together.

**Windows 0.5.1 only. You need to own the game.**

## contents

- [Quick start](#quick-start)
- [You need to own the game](#you-need-to-own-the-game)
- [Installing](#installing)
  - [Command line options](#command-line-options)
- [Setting up a game](#setting-up-a-game)
- [Playing](#playing)
- [Is this a virus](#is-this-a-virus)
- [Troubleshooting](#troubleshooting)
- [Why you cant just drop files in](#why-you-cant-just-drop-files-in)
- [How it works](#how-it-works)
- [Working on it](#working-on-it)
- [Rough edges](#rough-edges)
- [Credits](#credits)

## quick start

1. Buy the game: https://yeahmaybe.itch.io/the-choicer-voicer
2. Download this repo as a zip and unzip it anywhere.
3. Double click **Install.bat** and wait a few minutes. It'll ask you to
   install python first if you haven't got it.
4. Copy the host's voice packs to everyone else (see
   [setting up a game](#setting-up-a-game)).
5. Launch the new exe, press **F9**, host or join.

## you need to own the game

There's no game files in here at all. No code, no assets, no exe. It's just my
netcode, a few patches, and a script that builds the mod out of the copy you
already bought.

The installer never downloads the game. It takes your copy, on your pc, patches
it and builds you a new exe.

## installing

Download the zip, unzip it wherever, double click **Install.bat**. That's pretty
much all of it.

It goes looking for your game on its own, it checks itch, downloads and
desktop. If it turns up a few copies it just asks which one you want. If it
can't find anything you can drag your game exe onto Install.bat instead, or
paste the path in when it asks you.

You need python installed. If you haven't got it the installer offers to get it
through winget, which is Microsoft's own package manager and already on your pc,
or you can grab it yourself from [python.org](https://www.python.org/downloads/)
and tick "Add python.exe to PATH" on the first screen.

An earlier version downloaded a copy of python itself and ran it. That's exactly
what a malware dropper does and antivirus started flagging the download, so it
doesn't do that any more. See
[is this a virus](#is-this-a-virus).

It downloads about 140mb of tools ([gdRE](https://github.com/GDRETools/gdsdecomp)
and [Godot](https://godotengine.org), both free), builds the mod, and leaves
`TheChoicerVoicer-Multiplayer.exe` sat in the same folder. Takes a few minutes.
Run it again later and it reuses the downloads so it's quicker the second time.

Your saves and packs don't get touched. The modded exe reads the same
`%APPDATA%\YeahMaybe\ChoicerVoicer` folder as the normal one, so just keep both
exes and launch whichever you fancy.

**Everyone playing needs to run the installer themselves.** Don't send people
the built exe, that's the whole game and it's not yours to hand out. Send them
this repo instead.

### command line options

If you'd rather use a terminal:

```
python install_mod.py "C:\path\to\TheChoicerVoicer_0-5-1 stable.exe"
```

| Flag | What it does |
| --- | --- |
| `-o PATH` | where to put the modded exe |
| `--godot PATH` | use a Godot 4.4.1 you've already got |
| `--gdre PATH` | use a `gdre_tools.exe` you've already got |
| `--keep-work` | keep the decompiled project instead of binning it |
| `--project DIR` | patch a decompiled project and stop, for modders |

## setting up a game

**Everybody needs the same voice packs.** This is the bit that trips people up,
so do it before you try to play. Scores get worked out against the clips you're
performing, so everyone needs the actual clip files the host picks.

Copy the host's

```
%APPDATA%\YeahMaybe\ChoicerVoicer\game\packs_voice
```

folder over to everyone else, into the same place. Paste that path straight into
explorer's address bar if you can't find it.

The lobby lists anything it spots as different, and the mod would rather flat out
refuse to start than let you desync halfway through a round.

**Everyone also needs the same build of the mod.** If someone installed an older
version they get kicked with a message saying so. Just get them to run the
installer again.

**Networking.** It runs on **UDP port 7654**. Over the internet the host has to
forward that port on their router. If you'd rather not be messing about in there,
ZeroTier, Tailscale or Radmin all work, you just connect on the virtual IPs
instead. 2 to 4 players.

## playing

1. Launch the modded exe and hit **F9** on the main menu, that opens the online
   lobby. (F9 is a bit of a bodge, there's no proper menu button yet.)
2. Host hits **Host**. Everyone else types the host's IP in and hits **Join**.
3. Once everyone's showing in the list, host hits **Start (choose clips)** for the
   normal game show, or **Start (dub mode)**, picks a pack, and everyone gets
   dragged into the match together.

The host drives everything. They click through the dialogue, the replays and the
end of round menu for the whole table so nobody ends up out of step. When it's
your turn to perform your mic opens on your machine and only yours. Everyone else
just watches and hears your take once it's uploaded.

When the pack's finished you all get put back in the lobby and the host can pick
another one. No need to restart anything.

## is this a virus

No, and you don't have to take my word for it, everything's readable right here.

Some people's antivirus flags the download as `Trojan:Script/Wacatac.H!ml`. The
`!ml` on the end means a machine learning guess rather than an actual match
against known malware, and that particular name is one of the most common false
positives going.

It was my fault. `Install.bat` used to download a copy of python off the internet
and run it if you didn't have one. That's convenient, and it's also exactly the
shape of a malware dropper: a batch file quietly launching powershell, pulling a
zip off the web and running the exe inside it. Antivirus doesn't know why you're
doing it, only that you are. That code is gone now, the launcher doesn't download
or run anything by itself.

If you want to check for yourself:

- The whole thing is 22 text files, about 100kb. Open `Install.bat` and
  `install_mod.py` in notepad and read them, that's all there is.
- The installer does download [Godot](https://godotengine.org) and
  [gdRE](https://github.com/GDRETools/gdsdecomp) and run them, because it needs
  them to rebuild the game. Both are well known open source tools and the urls
  are sat in plain sight at the top of `install_mod.py`, pointing at their
  official GitHub releases.
- Browsers warn about new files nobody's downloaded before, separately from any
  antivirus. That one goes away on its own as more people grab it.

If your antivirus still complains, please report it to the vendor as a false
positive rather than just turning your antivirus off. That fixes it for the next
person too.

## troubleshooting

**It can't find my game.** Drag your game exe onto `Install.bat`, or paste the
full path when it asks. It only auto checks itch, downloads and desktop.

**The installer stops with a "hunk does not match" error.** Your game isn't
Windows 0.5.1. That's the only version the patches are written against.

**Antivirus flags the download.** See [is this a virus](#is-this-a-virus).

**Windows says the modded exe it built is unsafe.** That one's separate. It's an
unsigned exe that got built on your machine a minute ago, so nothing vouches for
it yet. Same thing happens to anybody building a Godot game.

**F9 does nothing.** You have to be on the main menu, and it has to be the modded
exe, not your original one.

**Nobody can join me.** Port 7654 UDP needs forwarding to your pc, and the game
needs allowing through your firewall. Try one of the LAN tools above first, it's
much less hassle and it proves whether the rest of it works.

**Match won't start, says clips are missing.** Someone hasn't got the voice packs
the host picked. Copy `packs_voice` over again and make sure it went to the right
folder.

**Somebody got kicked for a different mod version.** They're on an older build of
the mod. Everyone runs the installer again off the same version of this repo.

**Someone crashed or alt f4'd mid match.** Everyone else carries on after about a
minute. It won't hang forever waiting for them.

**Where are the logs.** `%APPDATA%\YeahMaybe\ChoicerVoicer\logs\`. Grab
`choicervoicer.log` off everyone involved if you're reporting something, the
network stuff all gets logged with `[NET]` in front of it.

## why you cant just drop files in

Fair question because that's how most mods work. Problem is Godot games are one
exe with everything packed inside them, and this one's got the pack baked into
the exe rather than sat next to it as a `.pck`. Godot only bothers looking for
loose override files when there's no pack inside the exe, so anything you drop
next to it just gets ignored. The game never even reads it.

And the scripts inside that pack are compiled down to bytecode anyway, they're
not text, so there'd be nothing to edit even if you did crack it open.

So the only way is rebuilding the exe, which is what the installer does. Upside
is it keeps everything above board, nobody's passing game files around and
everyone builds from the copy they paid for.

## how it works

The base game is already turn based so this didn't need loads. A contestant's
score comes entirely out of three small byte arrays of waveform data, so there's
no realtime state to sync at all. The mod just has to agree whose turn it is,
send one performance per turn, and stop everyone drifting apart between phases.

- ENet client/server, host is authoritative and always slot 0.
- Recorded takes get chunked up, sent to everyone, and fed into the waveform like
  they'd been recorded on that machine.
- Scoring happens on the host then gets published out, so float rounding can't
  give two people different leaderboards.
- Phase barriers hold everyone at each stage of a round, with timeouts so one
  person crashing can't freeze the whole table.
- Every show carries a generation stamp. Round state is keyed by round number and
  contestant slot and both of those restart at zero, so without it the leftovers
  of a finished match look exactly like a fresh one.

What's in `mod/`:

```
mod/net/net_manager.gd    all the netcode, one autoload
mod/net/lobby.gd          the lobby screen, built in code
mod/net/_selftest.gd      compiles every script in the project
mod/net/_nettest.gd       headless host/client smoke test
mod/patches/*.patch       edits to 7 of the game's scripts
mod/export_presets.cfg    the windows export preset
```

Two new files and about 370 changed lines across 7 of the game's scripts. The
installer also fixes a gdRE bug where it writes node paths as `$A / B`, which
every decompiled build needs sorting whether you're modding it or not.

## working on it

```
python install_mod.py --project path/to/decompiled
```

That patches a project in place and stops, then you open it in Godot 4.4.1.

The two test scripts aren't autoloads in the committed project. Register one
temporarily when you want to run it, and never both at the same time, because the
self test quits the tree the second it finishes.

```
# compile every script
godot --headless --path project

# network smoke test, two terminals
godot --headless --path project -- host
godot --headless --path project -- client
```

`_nettest.gd` covers the bug that used to make the game unplayable after one
pack. It runs a second show reusing the same contestant slot and barrier tags and
checks the new take turns up instead of the old one.

If you edit a game script and want to regenerate the patches, diff your project
against a clean decompile with the node path fix applied.

## rough edges

- Lobby's on F9, not a menu button.
- Windows 0.5.1 only. Anything else fails with a clear error when it goes to
  patch it.
- Twitch modes are singleplayer, haven't touched them.
- Pack differences only get checked against the clips actually picked.

## credits

The Choicer Voicer is by **YeahMaybe**. This is just an unofficial fan mod,
nothing to do with them and not endorsed by them. All the game's code and assets
stay their copyright and none of it is in here.

My code (`mod/net/`, `install_mod.py`) is MIT, see [LICENSE](LICENSE). Built with
[Godot](https://godotengine.org) and [gdRE](https://github.com/GDRETools/gdsdecomp).
