# Findings: merlin-client

Notes from a code read of this repo at commit `7126eab`. None of this was run
against a real speaker or Merlin's API; "works end to end" is the author's claim.

## Context: getting your own content onto a Merlin speaker

| Route | Opens the case? | Notes |
|---|---|---|
| **merlin-client (Wi‑Fi)** | No | Imports any audio into any menu folder. Needs a Merlin account + registered speaker. macOS only today. |
| Official app recordings/imports | No | Max 10 tracks × 10 min. Safe, but a ceiling, not a library. |
| Bluetooth | — | Not supported. |
| USB | — | Charging only (micro‑USB gen 1, USB‑C gen 2). Worth a 30 s `lsusb` / `dmesg -w` check. |
| Radio → own Icecast server | No | Untested idea: if the stream URL lives in the playlist, a radio entry could point at your own server. Check `~/.config/merlin/cache/last_synchro.json` after adding a radio. |
| micro‑SD extension cable / SDWire | Once | SD card is on the main board behind the 4 back screws. Then edit it with merlinator / Merlin-jailbreak. Voids the warranty. |

`192.168.4.1` is Espressif's default SoftAP address, which suggests (not confirmed) an ESP32 inside.

## What merlin-client does

A Ruby replacement for the Merlin Android app v1.20.5 (reverse-engineered from
the APK; `backend.rb` sends its User-Agent). One `merlin sync`:

1. Logs in to the Hello Merlin account (tokens stored, password never stored).
2. Asks the cloud for a sync plan (`create_synchro`): files to download, menu
   tree JSON, speaker Wi‑Fi SSID/password, and a second "pending" Wi‑Fi pair.
3. Downloads audio and covers; inserts local files into the menu tree
   (ffmpeg → MP3 44.1 kHz, 64 kb/s mono or 128 kb/s stereo, 128×128 covers).
4. Waits for the Wifi/Transfert button, then joins `MERLIN_xxxxxx` automatically.
   A temporary `pf` rule (sudo) keeps the Mac's other traffic off the speaker,
   which otherwise reboots (per README).
5. Talks the speaker protocol over TCP `192.168.4.1:50000` (`sync.rb`): covers,
   audio (skipped if SHA‑256 matches), playlist, then rebuild-library.
6. Sets clock and usage hours, pushes the pending Wi‑Fi pair, rejoins home
   Wi‑Fi, reports the result to Merlin.

Also: catalog browsing with a basket, raw speaker commands (info, upload, get,
listening stats), and a full-screen TUI.

### Wi‑Fi password: not cracked, handed out by Merlin's cloud

| Pair | Source | Use |
|---|---|---|
| `ssid` / `password` | Sync plan from Merlin cloud | Join the speaker's AP (`sync.rb:68` → `wifi.rb:116` → `networksetup -setairportnetwork`) |
| `pendingSsid` / `pendingPassword` | Same plan | Written to the speaker via `set_wifi` at the end |

- The pending pair looks like the user's **home** Wi‑Fi (radio feature): the
  test fixture uses `HomeNet-42` and `http_log.rb` calls it the home network.
  Inference, not a live observation. If correct, Merlin's servers store your
  home Wi‑Fi password.
- No account with the speaker registered means no password and no base playlist,
  so there is no offline route.
- `sync.rb:50` writes the whole plan, passwords included, in plaintext to
  `~/.config/merlin/cache/last_synchro.json` (parent dir 0700). The HTTP log
  redacts them; this file doesn't. Keep it out of bug reports.
- Unknown whether the speaker password rotates between syncs.

### Risks

- Very young project (11 commits on 2–3 Oct 2026, no licence). A firmware
  update could break it.
- A sync from the phone app rebuilds the menu without your files; they come
  back on the next merlin-client sync.
- The protocol exposes a firmware-update command. Don't touch it.

## Linux support: transfer does not work as-is

No Linux code path exists: "Linux" appears only in the fake Android
User-Agent and an `x86_64-linux` lockfile line.

| Part | On Linux | Why |
|---|---|---|
| Cloud: `login`, `speakers`, `use`, `browse`, `search`, `add`, `remove`, `basket` | Should work | Plain HTTPS (Faraday). Needs Ruby ≥ 3.2 (`Data.define`, `media.rb:22`). |
| Speaker: `info`, `upload`, `exists`, `get`, `apply-playlist`, `set-time`, `set-hours`, `listening` | Should work if you join the speaker Wi‑Fi yourself | Raw TCP, nothing OS-specific. |
| `sync --dry-run` | Mostly | Prints a misleading "Xcode command-line tools" error, then catches it (`wifi_helper.rb:60`). |
| `sync` | No | Needs `networksetup`, `ipconfig`, `pfctl`, and a Swift CoreWLAN/CoreLocation helper (`mac_network.rb`, `isolation.rb:84`). |
| `unisolate`, default TUI | No | Same admin/firewall step (`bin/merlin:122-144`). |

Failure modes if you try anyway:

- `merlin sync`: dies with an uncaught `Errno::ENOENT … networksetup` before
  sudo. Nothing has reached Merlin's servers yet.
- `merlin sync --no-isolate`: **avoid.** Creates the synchro and downloads,
  fails at Wi‑Fi, then the cleanup calls `networksetup` again and throws
  (`wifi.rb:84`). The failure report is neither sent nor saved
  (`sync.rb:57-87`), contradicting the "never stays PENDING" comment.
- `--dry-run` also leaves a PENDING synchro on the server (`sync.rb:55`) and
  writes the plaintext password file.
- Titled folder covers need the `magick` binary (ImageMagick 7); with only
  `convert` you silently get plain-colour covers (`media.rb:93`).

A manual route (dry-run → join speaker Wi‑Fi → `upload` + `apply-playlist`)
works on paper, but the CLI has no command for the closing steps (end of sync,
report to Merlin).

### Porting sketch (estimate, untested)

- **Network:** `Wifi` uses six methods on its network object: `current_ssid`,
  `visible_ssids`, `ip`, `join`, `forget`, `power_cycle`. `Config#network`
  hard-codes `MacNetwork` (`config.rb:25`). An `nmcli` class can cover all six.
- **Isolation:** `Config#isolation` hard-codes the pf firewall (`config.rb:34`).
  Replace with an nftables rule mirroring the three pf lines, and/or a
  NetworkManager profile with `ipv4.never-default` + `ipv4.ignore-auto-dns` so
  the speaker never becomes gateway/DNS (the root cause the README gives).
- **Connectivity probes:** NetworkManager's connectivity check
  (`interval=0` disables it) is the likely counterpart of the macOS
  captive-portal probes. Whether Linux even triggers the reboot is unknown.
- **Install:** x86_64 gets a prebuilt `ratatui_ruby`; aarch64 compiles from
  source. Needs `ffmpeg` / `ffprobe` for imports.
- The repo's fake-speaker tests (`test/fake_speaker.rb`, `test/fake_network.rb`)
  can validate a port without hardware; only a real speaker can confirm the
  reboot behaviour.

## Sources

- merlin-client: https://github.com/quentindemetz/merlin-client
- merlinator: https://github.com/djokeur/merlinator
- Merlin-jailbreak: https://github.com/IArchi/Merlin-jailbreak
- Hello Merlin FAQ / help pages (recordings, Wi‑Fi, radio, USB, changelog): https://www.hello-merlin.com/
- iFixit Merlin teardown; 3mdeb SDWire; Debian `sd-mux-ctrl`
- NetworkManager settings & NetworkManager.conf docs; nftables wiki; Ruby 3.2.0 release notes
