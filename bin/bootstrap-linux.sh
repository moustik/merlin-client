#!/usr/bin/env bash
# Linux only: installs the system packages merlin needs, before `bundle install`.
# Safe to run again.
#
#   bin/bootstrap-linux.sh           install what is missing (asks for sudo)
#   bin/bootstrap-linux.sh --check   only report what is missing
#   bin/bootstrap-linux.sh --yes     don't ask the package manager for confirmation
#
# Packages: Ruby >= 3.2 with bundler, a C compiler (the json and prism gems
# build native code), ffmpeg (transcoding), ImageMagick 7 and a font (folder
# covers), NetworkManager (Wi-Fi switching) and nftables (the traffic filter).
# Also points bundler at vendor/bundle, since the system gem dir isn't writable.
set -euo pipefail

cd "$(dirname "$0")/.."

check_only=false
assume_yes=false
for arg in "$@"; do
  case "$arg" in
    --check) check_only=true ;;
    --yes|-y) assume_yes=true ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Linux ] || { echo "This script is for Linux. On macOS: brew install ffmpeg imagemagick" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }

ruby_ok() { have ruby && ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2") ? 0 : 1)'; }
font_ok() { have fc-list && [ -n "$(fc-list 2>/dev/null | head -1)" ]; }
nft_ok() { [ -x /usr/bin/nft ] || [ -x /usr/sbin/nft ]; }

pm=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*) pm=pacman ;;
    *" debian "*|*" ubuntu "*) pm=apt ;;
    *" fedora "*|*" rhel "*) pm=dnf ;;
  esac
fi

# pkg <need>: the package(s) providing it on this distribution
pkg() {
  case "$pm:$1" in
    pacman:ruby) echo ruby ;;      pacman:bundle) echo ruby-bundler ;; pacman:cc) echo base-devel ;;
    pacman:ffmpeg) echo ffmpeg ;;  pacman:magick) echo imagemagick ;;  pacman:font) echo ttf-dejavu ;;
    pacman:nmcli) echo networkmanager ;; pacman:nft) echo nftables ;;
    apt:ruby) echo ruby-full ;;    apt:bundle) echo ruby-bundler ;;    apt:cc) echo build-essential ;;
    apt:ffmpeg) echo ffmpeg ;;     apt:magick) echo imagemagick ;;     apt:font) echo fonts-dejavu-core ;;
    apt:nmcli) echo network-manager ;; apt:nft) echo nftables ;;
    dnf:ruby) echo ruby-devel ;;   dnf:bundle) echo rubygem-bundler ;; dnf:cc) echo "gcc make redhat-rpm-config" ;;
    dnf:ffmpeg) echo ffmpeg-free ;; dnf:magick) echo ImageMagick ;;    dnf:font) echo dejavu-sans-fonts ;;
    dnf:nmcli) echo NetworkManager ;; dnf:nft) echo nftables ;;
  esac
}

echo "Checking requirements${pm:+ ($pm)}..."
missing=()
need() { # need <name> <test command...>
  local name=$1; shift
  if "$@"; then note "ok       $name"; else note "missing  $name"; missing+=("$name"); fi
}
need ruby   ruby_ok
need bundle have bundle
need cc     have cc
need ffmpeg have ffprobe
need magick have magick
need font   font_ok
need nmcli  have nmcli
need nft    nft_ok

if [ ${#missing[@]} -gt 0 ]; then
  packages=()
  for m in "${missing[@]}"; do
    p=$(pkg "$m")
    [ -n "$p" ] && packages+=($p)
  done
  if [ -z "$pm" ]; then
    warn "unknown distribution: install these yourself: ${missing[*]}"
    $check_only || exit 1
  else
    case "$pm" in
      pacman) cmd=(sudo pacman -S --needed); $assume_yes && cmd+=(--noconfirm) ;;
      apt)    cmd=(sudo apt-get install); $assume_yes && cmd+=(-y) ;;
      dnf)    cmd=(sudo dnf install); $assume_yes && cmd+=(-y) ;;
    esac
    if $check_only; then
      note "to install: ${cmd[*]} ${packages[*]}"
    else
      echo "Installing: ${packages[*]}"
      [ "$pm" = pacman ] && note "(if pacman can't find a package, run 'sudo pacman -Syu' first)"
      "${cmd[@]}" "${packages[@]}"
    fi
  fi
fi

# Debian/Ubuntu still ship ImageMagick 6, which has no `magick` command:
# folder covers then fall back to a plain color.
if [ "$pm" = apt ] && ! have magick && have convert; then
  warn "ImageMagick 6 has no 'magick' command: folders will get plain covers (install ImageMagick 7 for titled ones)"
fi

# Not done by this script: enabling NetworkManager could take over a network
# that something else (iwd, systemd-networkd...) manages.
if have nmcli; then
  if ! nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
    warn "NetworkManager isn't running. If nothing else manages Wi-Fi here:"
    note "  sudo systemctl enable --now NetworkManager"
  elif ! nmcli -t -f TYPE device 2>/dev/null | grep -qx wifi; then
    warn "NetworkManager sees no Wi-Fi device: syncing needs one"
  fi
  # polkit says "yes" to the user of an active local (desktop) session, "auth"
  # over SSH or from a service, and with no agent to ask, nmcli then fails.
  perms=$(nmcli -t general permissions 2>/dev/null || true)
  if printf '%s\n' "$perms" | grep -q '^org.freedesktop.NetworkManager.settings.modify.own:' &&
     ! printf '%s\n' "$perms" | grep -qx 'org.freedesktop.NetworkManager.settings.modify.own:yes'; then
    warn "NetworkManager won't let this session change Wi-Fi settings (polkit): run merlin from your desktop session"
  fi
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*|*utf-8*) ;;
  *) warn "your locale isn't UTF-8: run merlin with LANG=C.UTF-8 (or set it in your shell profile)" ;;
esac

$check_only && exit 0

bundle config set --local path vendor/bundle
echo
echo "System ready. Next:  bundle install   then   bin/merlin"
