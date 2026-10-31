#!/usr/bin/env bash
# Checks (and with --apt, installs) what record.sh needs.
#   install.sh           report what is missing
#   install.sh --apt     install the missing Debian/Ubuntu packages with sudo apt-get
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
missing_packages=()
missing_other=()

need_command() { # <command> <apt package>
  command -v "$1" >/dev/null 2>&1 || missing_packages+=("$2")
}

need_command ffmpeg ffmpeg
need_command ffprobe ffmpeg
need_command Xvfb xvfb
need_command python3 python3
need_command node nodejs
need_command npm npm
command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 \
  || command -v google-chrome >/dev/null 2>&1 || missing_packages+=(chromium)
# Captured first: grep -q on a pipe would end it early and fail under pipefail.
fonts=$(fc-list 2>/dev/null || true)
[[ $fonts == *'Liberation Sans'* ]] || missing_packages+=(fonts-liberation)

# libass is what burns the captions in.
if command -v ffmpeg >/dev/null 2>&1; then
  filters=$(ffmpeg -hide_banner -filters 2>/dev/null || true)
  [[ $filters == *' subtitles '* ]] || missing_other+=("an ffmpeg built with libass (the 'subtitles' filter)")
fi

if ! (cd "$HERE" && node -e "require('./lib/playwright').loadPlaywright()" >/dev/null 2>&1); then
  missing_other+=("playwright-core: run 'npm install' in tools/video")
fi

if [[ ${#missing_packages[@]} -eq 0 && ${#missing_other[@]} -eq 0 ]]; then
  echo "Everything record.sh needs is installed."
  exit 0
fi

mapfile -t missing_packages < <(printf '%s\n' "${missing_packages[@]}" | sort -u)

if [[ ${#missing_packages[@]} -gt 0 ]]; then
  echo "Missing packages: ${missing_packages[*]}"
  if [[ ${1:-} == --apt ]]; then
    sudo apt-get update
    sudo apt-get install -y "${missing_packages[@]}"
  else
    echo "  sudo apt-get install -y ${missing_packages[*]}    (or run: install.sh --apt)"
  fi
fi
for m in "${missing_other[@]}"; do echo "Missing: $m"; done
[[ ${1:-} == --apt && ${#missing_other[@]} -eq 0 ]] || exit 1
