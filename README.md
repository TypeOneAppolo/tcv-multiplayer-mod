# The Choicer Voicer Online Multiplayer

<p align="center">
  <a href="https://discord.gg/HYhh6V4NZk">
    <img src="https://img.shields.io/badge/Discord-join%20the%20server-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join the Discord" height="40">
  </a>
  &nbsp;
  <a href="https://ko-fi.com/appolodev">
    <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="Buy me a coffee on Ko-fi" height="40">
  </a>
  &nbsp;
  <a href="https://ko-fi.com/appolodev/goal?g=0">
    <img src="https://img.shields.io/badge/Ko--fi-see%20the%20goal-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white" alt="Ko-fi goal" height="40">
  </a>
</p>

<p align="center">
  <em>Stuck on the install, or short of people to play with?
  <a href="https://discord.gg/HYhh6V4NZk">The Discord</a> is the place to ask.</em>
</p>

<p align="center">
  <em>This mod is free and always will be. If it got your group playing together,
  a coffee helps me keep working on it.</em>
</p>

Play The Choicer Voicer with up to 4 people online. Everyone records on their own
mic on their own pc and it all stays in sync, so one person performs at a time,
the host clicks through the dialogue for everybody, and the scores get worked out
in one place so you're not all sat looking at different numbers.

Works for the normal game show and for dub mode, where you pick which character
you're dubbing and then watch the finished thing together.

**Windows 0.5.1 and 0.5.2 dev-2. You need to own the game.**

## contents

- [Video tutorial](#video-tutorial)
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

## video tutorial

If you'd rather watch someone do it than read all this, there's a walkthrough of
installing it and getting a game going:

<p align="center">
  <a href="https://youtu.be/YoHYlGWCE_g">
    <img src="https://img.youtube.com/vi/YoHYlGWCE_g/maxresdefault.jpg" alt="Watch the install and setup walkthrough on YouTube" width="640">
  </a>
</p>

<p align="center">
  <a href="https://youtu.be/YoHYlGWCE_g">https://youtu.be/YoHYlGWCE_g</a>
</p>

## quick start

1. Buy the game: https://yeahmaybe.itch.io/the-choicer-voicer
2. Download this repo as a zip and unzip it anywhere. **Unzip it properly, don't
   run Install.bat from inside the zip**, see
   [troubleshooting](#troubleshooting).
3. Double click **Install.bat** and wait a few minutes. It'll ask you to
   install python first if you haven't got it.
4. Copy the host's voice packs to everyone else (see
   [setting up a game](#setting-up-a-game)).
5. Launch the new exe and click **ONLINE** in the top right of the main menu
   (or press **F9**), then host or join.

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
`TheChoicerVoicer-Multiplayer-1.1.8.exe` sat in the same folder. Takes a few
minutes. Run it again later and it reuses the downloads so it's quicker the
second time.

The version is on the end of the name on purpose. Everyone in a lobby has to be
on the same build, so when a join goes wrong the first question is always "which
one are you running" — and now the answer is on the exe you launched rather than
buried in a menu. Old builds are left alone, so you can keep one around to play
with somebody who hasn't updated yet.

When it finishes it opens the Discord invite in your browser. `--no-discord`
turns that off.

Your saves and packs don't get touched. The modded exe reads the same
`%APPDATA%\YeahMaybe\ChoicerVoicer` folder as the normal one, so just keep both
exes and launch whichever you fancy.

Everyone playing needs to run the installer themselves. Don't send people the
built exe, that's the whole game and it's not yours to hand out. Send them this
repo instead.

### command line options

If you'd rather use a terminal:

```
python install_mod.py "C:\path\to\TheChoicerVoicer_0-5-1 stable.exe"
```

| Flag | What it does |
| --- | --- |
| `-o PATH` | where to put the modded exe |
| `--no-discord` | don't open the Discord invite when the build finishes |
| `--godot PATH` | use a Godot 4.4.1 you've already got |
| `--gdre PATH` | use a `gdre_tools.exe` you've already got |
| `--keep-work` | keep the decompiled project instead of binning it |
| `--project DIR` | patch a decompiled project and stop, for modders |
| `--zip-logs` | bundle this tool's logs and the game's own logs into a zip on your Desktop and exit — no game exe needed |

## setting up a game

Everybody needs the same voice packs. This is the bit that trips people up, so
do it before you try to play. Scores get worked out against the clips you're
performing, so everyone needs the actual clip files the host picks.

Copy the host's

```
%APPDATA%\YeahMaybe\ChoicerVoicer\game\packs_voice
```

folder over to everyone else, into the same place. Paste that path straight into
explorer's address bar if you can't find it.

The lobby lists anything it spots as different, and the mod would rather flat out
refuse to start than let you desync halfway through a round.

Everyone also needs the same build of the mod. If someone installed an older
version they get kicked with a message saying so. Just get them to run the
installer again.

On the networking side it runs on UDP port 7654. Over the internet the host has
to forward that port on their router. If you'd rather not be messing about in
there, ZeroTier, Tailscale, Radmin and Hamachi all work, you just connect on the
virtual IPs instead. On Hamachi that's the IPv4 address shown next to the host's
name, not their real one. 2 to 4 players.

## playing

1. Launch the modded exe. There's an **ONLINE** button in the top right of the
   main menu, that opens the online lobby. **F9** does the same thing. If you
   can't see the button, you're running your original exe and not the modded
   one.
2. Host hits **Host**. Everyone else types the host's IP in and hits **Join**.
3. Once everyone's showing in the list, host hits **Start (choose clips)** for the
   normal game show, or **Start (dub mode)**, picks a pack, and everyone gets
   dragged into the match together.

### picking who you dub

Dub mode opens on a casting screen. Tick the characters you want and everyone
sees the list fill in as people choose. Every clip goes to whoever took that
character, so if you take Tuco and someone else takes Heisenberg you each get
your own lines instead of just alternating.

Nothing has to line up neatly. Clips for a character nobody picked, and clips the
pack doesn't tag at all, get shared out evenly. If two of you pick the same
character the one higher up the list gets those clips, and the screen warns you.
The host can hit **Split the cast for us** to deal the characters out, and starts
everyone with **Begin dub**.

Packs that don't tag their clips with characters still work, they just split
evenly the way they always did.

The host drives everything. They click through the dialogue, the replays and the
end of round menu for the whole table so nobody ends up out of step. When it's
your turn to perform your mic opens on your machine and only yours. Everyone else
just watches and hears your take once it's uploaded.

Once the last clip is done everyone lands on the results screen, and **Watch**
plays the finished dub for the whole table at once. Whoever presses it starts it
for everybody — but not instantly. Scoring the clips takes as long as the slowest
machine takes, so the press waits until everyone is actually sat there before it
starts anything, and the person who pressed it gets a "waiting for so-and-so"
note while it does. **Stop** goes out to everyone the same way.

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

- The whole thing is 23 text files, about 200kb. Open `Install.bat` and
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

If nothing here covers it, send me the logs rather than a description. Double
click **`Zip Diagnostics.bat`** and it puts a zip with everything useful --
the installer's own logs plus the game's -- on your Desktop, ready to attach to
a [GitHub issue](https://github.com/TypeOneAppolo/tcv-multiplayer-mod/issues).
If the installer itself fails, it now does this for you automatically and
tells you where the zip landed. **Where are the logs**, at the bottom of this
section, has the details for doing it by hand instead.

**"can't open file ... install_mod.py: [Errno 2] No such file or directory"**,
and the path it names has something like `Rar$DIa1234.5678.rartemp` or
`Temp\7zO8B...` in it. You ran `Install.bat` from inside the zip or rar without
unpacking it first. Double clicking a file inside an archive makes your archive
program copy that one file out to a temp folder and run it there on its own, so
`install_mod.py` and the `mod` folder never came with it.

Right click the download, **Extract All** (or **Extract Here** in WinRAR), put it
somewhere normal like your Desktop, and run `Install.bat` out of the folder that
makes. The folder should have `Install.bat`, `install_mod.py` and a `mod` folder
sat in it together.

**It can't find my game.** Drag your game exe onto `Install.bat`, or paste the
full path when it asks. It only auto checks itch, downloads and desktop.

**The installer stops with a "hunk does not match" error.** Your game isn't one
of the versions the patches are written against. It handles Windows 0.5.1 and
0.5.2 (dev-2, standard and compatibility builds), and it tells you which one it
thinks you gave it.

**Antivirus flags the download.** See [is this a virus](#is-this-a-virus).

**Windows says the modded exe it built is unsafe.** That one's separate. It's an
unsigned exe that got built on your machine a minute ago, so nothing vouches for
it yet. Same thing happens to anybody building a Godot game.

**"the export produced no file".** Godot built it and something deleted it out
from under the installer, and that something is nearly always Defender. A fresh
unsigned Godot exe is one of its favourite false positives, and it grabs the file
the instant the build gets renamed to `.exe`, so Godot never sees anything go
wrong. The installer now says so, prints the detection out of Defender's own log
when it can find it, and waits while you sort it. Open PowerShell as
administrator and allow the folder you're building in:

```powershell
Add-MpPreference -ExclusionPath "C:\path\to\the\folder"
```

Then press Enter back in the installer and it builds again, which only takes a
minute the second time. Take the exclusion off afterwards with
`Remove-MpPreference -ExclusionPath` if you'd rather not leave it there. If
Defender already quarantined a copy, release it under Virus & threat protection
→ Protection history.

**F9 does nothing.** Look for the **ONLINE** button in the top right of the main
menu and click that instead. If the button isn't there, you're on your original
exe rather than the modded one — check which file you actually launched, and
check your shortcut isn't still pointing at the old one.

If the button *is* there but F9 isn't doing anything, it's your keyboard, not the
mod. On a lot of laptops the top row is media keys unless you hold **Fn**, and
OBS, Medal and GeForce Experience all like to grab F9 for start/stop recording.
The button doesn't care about any of that.

**My recording plays back silent, but the waveform drew fine.** Open Settings →
Microphone and re-pick your mic from the dropdown, even if it already looks like
the right one. The game remembers the mic by name, and if that device has been
unplugged or renamed since you chose it the saved name goes stale — re-picking it
writes a live one back. Fixed in 1.1.5 so the mod checks the name before it uses
it, but re-picking is still worth doing if you're on an older build.

**Nobody can join me.** First check they're typing the right address. When you
hit **Host** the lobby now lists every address this machine has and marks the one
to hand out — if Hamachi or Radmin is running, it's that one, and it is *not* the
IP a what-is-my-ip page shows you. Most failed joins are people forwarding ports
that were never the problem.

If you're not using a LAN tool, port 7654 UDP needs forwarding to your pc and the
game needs allowing through your firewall. Try one of the LAN tools above first,
it's much less hassle and it proves whether the rest of it works.

**Match won't start, says clips are missing.** Someone hasn't got the voice packs
the host picked. Copy `packs_voice` over again and make sure it went to the right
folder.

**Somebody got kicked for a different mod version.** They're on an older build of
the mod. Everyone runs the installer again off the same version of this repo.

**"The host hasn't sent the lobby after 12 seconds."** You're on different builds
of the mod, and up to v1.1.3 that was the message you got for it no matter what.
Everyone rebuilds off the same download, all of you, at the same time. Updating
one person doesn't help and is usually what causes it.

The version check was supposed to catch this and say so. It couldn't. Godot
doesn't send the name of a network call, it sorts them by name and sends the
position, so call fifteen means whatever happens to be fifteenth in that build.
v1.1.3 added one call that sorted tenth and pushed everything below it down a
place, so a v1.1.2 joiner's "let me in" arrived as a completely different call
with the wrong number of arguments and got dropped on the floor. The check that
would have caught the version difference was inside the message that never
arrived. The host genuinely never heard anyone knock, so it sat there, and the
joiner sat there being told the host hadn't sent the lobby.

Fixed in v1.1.4, and the fix is mostly about never doing this again: the join
handshake is now pinned to the front of that sorted list where nothing can shift
it, and it carries its arguments in one bag so their number can't change either.
Two builds can now always get as far as telling each other what they're running,
whatever else moves between versions. If they differ you get told which of you is
behind, on both screens. A v1.1.4 host also gives up on a joiner that never
completes the handshake and says so on the host's own screen, which is the only
thing that can help when the other end is too old to be told anything.

v1.1.4 still can't talk to v1.1.3 or earlier, and there's no fixing that from
this end. It just fails with the right message now instead of the wrong one.

v1.1.6 closes the last hole in that, on the host's screen. Both ends waited the
same ten seconds, so whoever gave up first took the connection down and the
other's explanation never fired -- and about half the time that was the host,
who saw somebody appear and vanish with nothing said. Now they get told either
way, and every one of these messages names the build it came from.

v1.1.7 is on protocol 6 and cannot play with v1.1.6 or earlier. Syncing the dub
watch needed two new calls, which moves every call number after them. It fails
with the right message on both screens, but everybody does have to rebuild.
The version is on the exe name now, which is there to make that argument shorter.

v1.1.8 is on protocol 7 and cannot play with v1.1.7 or earlier. Recordings are
acknowledged as they arrive now, which took another call, and they go over the
wire compressed, so the audio itself is in a different shape too. Same story:
right message on both screens, everybody rebuilds.

**We were playing fine and then he just got kicked. No error, no crash, he was
back at the menu.** That was a bug, fixed in v1.1.8, and it's the same 30 second
ENet timeout as the two above with a different cause. A recording is about a
megabyte of raw audio per clip, and the mod used to hand the whole lot to the
network as fast as the game could loop -- roughly 1.4 MB a second offered,
whatever the link between you could actually carry. On a LAN that's fine. Over
Hamachi or Radmin it is nowhere near, and ENet doesn't push back: it queues
everything it's given, keeps resending what doesn't get through, and after about
thirty seconds of getting nowhere it declares the peer dead and drops it. Nobody
gets told anything, because as far as either end is concerned the other one
simply stopped existing.

The sender now waits to be told the audio is arriving. Every chunk is
acknowledged and it never gets more than 64KB ahead of the slowest listener, so
the network is only ever holding an amount any working link can shift. The
recording is compressed first as well, which is lossless and usually takes a
third or more off it. Both ends show a percentage while a take is in flight
instead of a caption that never changes.

Being dropped mid show also puts you back in the **online lobby** with a written
reason now, rather than the main menu with nothing said.

If it still happens: check Hamachi or Radmin shows a solid green dot next to each
other's names on both machines. A blue or flashing one means it couldn't connect
you directly and is relaying you through its own server, which is slow enough
that this is worth fixing before anything else.

**He was on clip 5 and I was still stuck on clip 1.** Same bug, same fix. Your
end was waiting on a recording that never arrived, while his end never waited for
anything and carried straight on. Now the person recording doesn't move to the
next clip until everyone has the last one, and you can see the take arriving
while it does.

**Someone takes ages over one clip and gets skipped.** Fixed in v1.1.8. There was
one flat 60 second limit, and it couldn't tell "they're still recording" apart
from "the take stopped arriving". Recording now has as long as it takes; a
transfer that genuinely goes quiet is given 45 seconds and then skipped.

**The joiner sees an empty lobby, no host name, a dead Ready box, and gets
dropped after about half a minute.** That was a bug, fixed. The lobby used to
send everyone the full file listing of every voice pack they owned, which ran to
hundreds of kilobytes, and over a VPN link it never finished arriving. ENet gives
up on a peer after exactly 30 seconds of that, which is where the timing came
from. It now sends a clip count and a checksum per pack instead, a couple of
kilobytes. Everyone needs to run the installer again to pick this up. That last
part isn't optional: older builds were meant to get kicked with a message saying
so, and it turned out they couldn't be told anything at all. See "the host hasn't
sent the lobby" below.

**The host presses start and goes into the match, but the joiner sits on the
online match screen and gets dropped about half a minute later.** That was a bug,
fixed after v1.1.1. When the host started, the joiner loaded the whole pack in
one go on its main thread, so it stopped answering the host for as long as that
took. ENet gives up on a peer that has gone quiet for 30 seconds, which is where
the timing came from, and the frozen window carried on showing the lobby the
whole time, which is why it looked like nothing had happened. The joiner now
loads a clip at a time and keeps answering while it does, tells you it's loading,
and neither end gives up on the other before 90 seconds. Rebuild with the
installer to pick this up. A rebuilt joiner is fixed even if the host is still on
an older build, and vice versa, so you don't have to do it all at once.

**The lobby says our voice packs aren't identical.** It compares a checksum of
the clip file names inside each pack, so it means the clips genuinely differ. It
tells you the clip count each of you has for that pack, which is normally enough
to spot which. Usual causes are one of you unzipping a pack one level deeper than
the other, or a download that didn't finish. It's only a warning, you can start
anyway, and it only matters if the host picks clips out of that pack.

**It used to say that when our packs were fine.** Fixed after v1.1.2. Packs were
matched up by their folder name, so the same pack under `SML - Mushroom Pizza` on
one machine and `sml_-_mushroom_pizza` on another looked like two packs neither of
you had. Worse, the joiner then got thrown back to the menu when the host started,
over clips it was holding the whole time. Packs are matched on what's inside them
now, so name the folders whatever you like. Backing tracks and the dub recordings
the game writes itself no longer count towards the clip totals either, they were
never performed.

**Someone crashed or alt f4'd mid match.** Everyone else carries on after about a
minute. It won't hang forever waiting for them.

**Where are the logs.** `%APPDATA%\YeahMaybe\ChoicerVoicer\logs\`. Paste that
into the address bar of any Explorer window and it'll take you straight there.
Easier: double click **`Zip Diagnostics.bat`** in the mod folder and it grabs
that whole folder for you, along with the installer's own logs, and puts a zip
on your Desktop.

**Something's wrong and none of the above covers it.** Send me the logs, not a
description. Double click `Zip Diagnostics.bat` — or run
`install_mod.py --zip-logs` if you're doing this from a command line — and it
writes `tcv-diagnostics-<date>-<time>.zip` to your Desktop with the game's
logs, the installer's own logs, and a note on what's what. Get **both** ends
of a multiplayer problem this way — the *host's* zip and the *joiner's*, from
the same attempt — and put them on a
[GitHub issue](https://github.com/TypeOneAppolo/tcv-multiplayer-mod/issues) or
the [GameBanana page](https://gamebanana.com/mods/702231). Everything the mod
does is in there with `[NET]` in front of it, and one pair of logs is usually
enough to say exactly what went wrong. A description on its own almost never is:
"we couldn't join" looks identical from the outside whether it's a firewall, a
mistyped address, or the two of you being on different builds, and the logs tell
those apart in seconds.

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
- The host works out who dubs which clip once and sends the whole list when the
  dub starts. Everyone could work it out themselves from the same picks, but then
  a late change would quietly give two people different answers for one clip.
- Watching the finished dub is a request to the host, not a local action. The dub
  itself runs in lockstep so everyone reaches the last clip together, but the
  results screen behind it scores every clip on a thread and takes as long as the
  machine takes. Pressing Watch used to start the presser's video a second or
  more ahead of everyone else's, and on the ones still building that screen it
  then got painted straight over. Now every peer says when it's ready, the host
  holds the press until they all have, and one broadcast starts the lot. A watch
  that still lands early is kept and applied on arrival rather than dropped.
- The join handshake sits at the front of the sorted list of network calls and
  takes one dictionary, so its number and its shape both stay put no matter what
  else gets added later. Godot addresses calls by position in that list, so
  anything else would mean two builds losing the ability to tell each other what
  they are, which is the one conversation that has to work when they differ.
- Voice packs are compared by a clip count and a checksum per pack. Sending the
  file names was hundreds of kilobytes on a normal install, and a reliable packet
  that can't get across costs you the peer 30 seconds later. The pack summaries
  also travel separately from the roster, which gets resent every time anybody
  ticks Ready.
- Recordings are compressed, chunked, and acknowledged chunk by chunk, and the
  sender never gets more than 64KB ahead of the slowest listener. It's the same
  30 second rule again from the other direction: ENet queues whatever you hand it
  and gives up on the peer when it can't shift it, so the fix is to stop handing
  it more than the link can carry. It costs nothing on a LAN, where the
  acknowledgements come back inside a frame, and it's the difference between
  working and not over a relayed VPN. A listener that stops acknowledging
  altogether is dropped from the wait after 45 seconds rather than being allowed
  to hold the person recording up.
- Waiting on somebody else's take uses two clocks, not one. Nothing heard yet
  means they're still recording, which can take as long as they like; a transfer
  that started and went quiet means the link died, and that gets 45 seconds. One
  combined limit couldn't tell those apart and skipped people for being slow.

What's in `mod/`:

```
mod/net/net_manager.gd            all the netcode, one autoload
mod/net/lobby.gd                  the lobby screen, built in code
mod/net/dub_character_picker.gd   the casting screen, built in code
mod/net/_selftest.gd              compiles every script in the project
mod/net/_nettest.gd               headless host/client smoke test
mod/patches/common/*.patch        edits that apply to every version
mod/patches/v0_5_1/*.patch        the files that differ on 0.5.1
mod/patches/v0_5_2/*.patch        the files that differ on 0.5.2
mod/export_presets.cfg            the windows export preset
```

Three new files and about 450 changed lines across 7 of the game's scripts. The
installer reads `config/version` out of the decompiled project and picks the
right patch set, so supporting a new build usually means one extra folder. It
also fixes a gdRE bug where it writes node paths as `$A / B`, which every
decompiled build needs sorting whether you're modding it or not.

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

`devtest/old_peer/` is a project of its own, and needs no copy of the game. It
connects to a host, says nothing at all, and leaves — which is exactly what a
build too old to speak the handshake looks like from the host's side. Open a
lobby, host, then point it at yourself:

```
godot --headless --path devtest/old_peer -- 127.0.0.1 7654 3
```

The last number is how long it hangs around. Under 10 seconds it leaves before
the host's watchdog and over 10 it outstays it; the host should say the same
thing either way, and nobody should ever appear in the contestant list.

If you edit a game script and want to regenerate the patches, diff your project
against a clean decompile with the node path fix applied.

## rough edges

- The lobby button is drawn over the menu by the mod rather than being a real
  menu entry, so it doesn't match the game's own styling.
- Windows 0.5.1 and 0.5.2 dev-2. Anything else fails with a clear error when it
  goes to patch it.
- Everyone needs the same build. The mod checks and kicks you out with a message
  if you don't, but it can't mix a 0.5.1 host with a 0.5.2 client.
- Twitch modes are singleplayer, haven't touched them.
- Pack differences only get checked against the clips actually picked.

## credits

The Choicer Voicer is by **YeahMaybe**. This is just an unofficial fan mod,
nothing to do with them and not endorsed by them. All the game's code and assets
stay their copyright and none of it is in here.

My code (`mod/net/`, `install_mod.py`) is MIT, see [LICENSE](LICENSE). Built with
[Godot](https://godotengine.org) and [gdRE](https://github.com/GDRETools/gdsdecomp).
