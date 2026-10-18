# Linux port plan

Goal: `merlin sync` and the TUI work on a Linux laptop with NetworkManager,
with the same guarantee as on macOS: during the transfer, nothing but the
transfer reaches the speaker. Based on commit `7126eab`. See
[FINDINGS.md](FINDINGS.md) for the background.

## Status (2026-10-18)

Steps 1–5 are done, with tests (`bundle exec rake test`: 122 runs, 0 failures).
Steps 7 (real speaker) and 8 (README) are still open. Changes from the plan below:

- **Step 1:** the system gem dir isn't writable, so gems go in `vendor/bundle`
  (`bundle config set --local path vendor/bundle`). Two tests failed only because
  their fake `pfctl` used `echo "$*"`, and bash's `echo` swallows `-E`. Fixed with `printf`.
- **Step 3:** removed the IPv6 drop rule. The filter is switched on while still at
  home, so it would cut home IPv6 on that interface for the whole wait. The
  speaker profile already disables IPv6.
- **Step 3, found by the new tests:** `Isolation#active?` meant "has a pf
  token", and nftables has none. On Linux `Sync#unisolate!` would never have
  removed the filter. It now uses an explicit `@active` flag (pf behaviour unchanged).
- **Step 5:** `Sync#finish` now saves the report to `pending_report.json`
  *before* the cleanup, and runs each cleanup step on its own (callback,
  filter, reconnect), so a crash or a second Ctrl-C can no longer leave the
  synchro PENDING. The filter is removed even if the callback fails.
  `Wifi#restore` still reconnects when forgetting the speaker network fails.
  `--dry-run` now closes its synchro with `800_FAILED_ON_USER_ABORT`, the
  code the app reports when a transfer is cancelled; a prepare failure keeps its own code.
  That is a behaviour change visible on Merlin's side.
- **New files:** `lib/merlin/linux_network.rb`, `lib/merlin/nft_isolation.rb`, and
  `test/{linux_network,nft_isolation,config}_test.rb`.

## Where macOS is wired in

Everything OS-specific sits behind two seams, both chosen in `Config`:

| Seam | macOS class | Chosen at | Used by |
|---|---|---|---|
| Wi‑Fi switching | `MacNetwork` (+ `WifiHelper` Swift app) | `config.rb:25` | `Wifi`, `bin/merlin:126`, `tui.rb:132` |
| Traffic isolation | `Isolation` (pf via a sudo helper) | `config.rb:34` | `Sync#isolate!`, `bin/merlin:139`, `tui.rb:248` |

`Wifi` only calls six methods on its network object: `current_ssid`,
`visible_ssids`, `ip`, `join(ssid, password = nil)`, `forget(ssid)` and
`power_cycle`. `location_authorized?` is optional, because `WifiPermission.check`
skips it when the method isn't there. `Sync`, `Speaker`, `Protocol` and
`Backend` have no OS code, and `Wifi`/`Sync` are already tested against
`test/fake_network.rb`.

So the port is two new classes, plus a platform switch in `Config`.

## Design choice: fix the root cause with a NetworkManager profile

The README's diagnosis is that the speaker becomes the machine's **gateway
and DNS**, and every app's reconnects and probes then crash it. macOS
can't easily prevent that, so the code filters the traffic with pf. On Linux the
speaker connection can be created so that it never becomes the gateway or the DNS server,
which matches what the Android app does with `bindProcessToNetwork`:

```
ipv4.never-default yes      # no default route via the speaker
ipv4.ignore-auto-dns yes    # never use the speaker as DNS
ipv6.method disabled        # no RS/ND/DHCPv6 chatter
connection.mdns no          # no mDNS/LLMNR announcements on that link
connection.llmnr no
connection.autoconnect no   # never join it outside a sync
```

Apps then get "network unreachable" locally instead of sending traffic to
the speaker, and no root access is needed. Some traffic still goes out on the speaker's
subnet, such as broadcasts (NetBIOS, SSDP) and anything bound to `wlan0`. An nftables
filter that mirrors the pf rules exactly therefore stays available as a second,
optional layer. It runs by default if the first real test still shows reboots.

## Steps

### 1. Baseline on Linux

- `bundle install` (x86_64 gets a prebuilt `ratatui_ruby`), then `bundle exec rake test`.
  The tests that use fakes should pass as they are. Record any that don't.
- Install `ffmpeg`/`ffprobe`, and ImageMagick 7 (`magick`) for folder covers.

### 2. `LinuxNetwork` (`lib/merlin/linux_network.rb`)

The class is driven by `nmcli`, and every call goes through one `run!` that raises `Merlin::Error`.
This includes `Errno::ENOENT`, which today escapes as a raw `SystemCallError`.

| Method | Implementation |
|---|---|
| `interface` | First `wifi` device from `nmcli -t -f DEVICE,TYPE device` (overridable, like `MacNetwork`) |
| `current_ssid` | `nmcli -t -f ACTIVE,SSID device wifi list --rescan no`, line starting `yes:` (unescape `\:`) |
| `visible_ssids` | `nmcli -t -f SSID device wifi list --rescan auto` (NM rate-limits rescans; `auto` is fine at a 3 s poll) |
| `ip` | `nmcli -g IP4.ADDRESS device show <iface>`, drop the `/24` |
| `join(ssid, password)` with a password (speaker) | Create or update the `merlin-speaker` profile with the settings above, then `nmcli connection up merlin-speaker passwd-file <tmp>`. The PSK goes in a 0600 temp file, **never in argv**, which other users can read through `ps`. |
| `join(ssid)` (home) | Find the saved profile whose `802-11-wireless.ssid` matches, then `nmcli connection up uuid <uuid>`. Profile names often differ from the SSID. |
| `forget(ssid)` | `nmcli connection delete merlin-speaker` (ignore "not found") |
| `power_cycle` | `nmcli device disconnect <iface>`, then `nmcli device connect <iface>`, so NM autoconnects its preferred profile |

Create the profile with `connection.permissions user:$USER` so it is a
user-owned connection. Polkit usually lets the active session user change
those without a password; system-wide profiles may prompt. **Verify** on the
target distro.

### 3. `NftIsolation` (optional second layer)

- Refactor `Isolation` lightly: the sudo helper process (`authorize!`, `call`,
  `shutdown_helper`, state file) stays shared, and only the helper script and
  rules become per-platform (`self.class::HELPER` instead of `HELPER`). The
  pf class keeps its current behaviour and tests.
- Linux helper: `on` loads the rules with `nft -f -`, and `off` runs `nft delete table inet merlin`.
  There is no token. The leftover file still records that rules may be left behind.

```
table inet merlin {
  chain out {
    type filter hook output priority 0;
    oifname "<iface>" ip daddr 192.168.4.1 tcp dport 50000 accept
    oifname "<iface>" udp sport 68 udp dport 67 accept
    oifname "<iface>" ip saddr 192.168.4.0/24 drop
  }
}
```

This works the same way as the pf rules: it only matches the speaker's interface and subnet, so it does nothing at
home. `merlin unisolate` cleans it up.

### 4. Platform switch in `Config`

```ruby
def linux? = RbConfig::CONFIG["host_os"].include?("linux")
def network = linux? ? LinuxNetwork.new : MacNetwork.new(helper: WifiHelper.new(dir: home))
def isolation(...) = linux? ? NftIsolation.new(...) : Isolation.new(...)
```

- Add `require_relative "merlin/linux_network"` in `lib/merlin.rb`.
- Isolation on Linux: keep `--no-isolate`, and decide the default after step 7.
  Use the profile alone if it holds, or profile plus nftables if not.
- Make the "this Mac" / "macOS" user-facing strings neutral (`bin/merlin`,
  `tui/sync_session.rb`, `wifi.rb`).

### 5. Fix the cleanup path while there

These are bugs found during the review that show up as soon as a network call raises:

- In `Wifi#restore`, `forget` runs outside the inner `begin`, so any failure
  skips the reconnect (`wifi.rb:84`).
- In `Sync#run`, if `@wifi.restore` raises something other than `Merlin::Error`,
  the `ensure` block dies before `send_report`/`save_pending_report`, and the
  synchro stays PENDING. Wrap restore so the report is always sent or saved
  (`sync.rb:57-87`).
- In `--dry-run`, `create_synchro` leaves a PENDING synchro (`sync.rb:55`). Look for
  a way to close or cancel it, or at least document it.

### 6. Tests (no hardware needed)

- `test/linux_network_test.rb`: a fake `nmcli` script that logs its argv and
  returns canned output, the same pattern as the fake `pfctl` in
  `isolation_test.rb`. Assert the profile flags, that the PSK never shows up in argv,
  `\:` unescaping, and the profile lookup by SSID.
- `test/nft_isolation_test.rb`: the same idea with a fake `nft`.
- A config test: the platform switch picks the Linux classes.
- The existing `wifi_test`/`sync_test` cover the flow through `FakeNetwork`.

### 7. Real-speaker validation (needs a Linux laptop with Wi‑Fi)

This dev box has no Wi‑Fi (only `eth0`), and NetworkManager isn't running on it,
so this step has to run elsewhere.

1. `merlin sync --no-isolate` with the profile only. Watch `journalctl -fu NetworkManager` and
   the speaker log, and check that the speaker does **not** reboot about 15 s after joining.
2. While on the speaker network, confirm with `ip route` (no default via 192.168.4.1) and
   `resolvectl status` (no 192.168.4.1 DNS).
3. Run `tcpdump -i <iface> not port 50000` during the transfer, to see what still reaches the speaker.
4. If it reboots: enable `NftIsolation` and repeat. If it still reboots, also try
   turning off NM's connectivity check (`[connectivity] interval=0`).
5. Check that the home Wi‑Fi comes back, and that the report reaches Merlin.

### 8. Docs

Add a README section for Linux covering requirements (NetworkManager, `nmcli`, Ruby ≥ 3.2,
ffmpeg, optionally `nft` + sudo), the profile approach, and what was validated.

## Out of scope / later

- iwd-only or wpa_supplicant-only systems: write a second network class behind
  the same six methods if needed.
- aarch64 Linux: `ratatui_ruby` builds from source (no prebuilt gem).
- Upstreaming: the repo has no licence yet, so ask the author before sending a PR.

## Open questions

- Does a Linux client crash the speaker at all once it isn't the gateway or DNS?
- Does polkit on the target distro allow user-owned Wi‑Fi profiles without a prompt?
- Does the speaker password rotate between syncs? It matters if the profile
  is reused rather than recreated each time.
