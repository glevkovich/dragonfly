#!/usr/bin/env bash
#
# UBSan artifact triage helper. Run it from the root of an unzipped
# `ubsan-logs-<arch>` artifact (or pass the folder as the 2nd argument).
#
#   ./ubsan_trace.sh <grep-pattern> [logs-dir]
#
# Examples:
#   ./ubsan_trace.sh 'src/core/dense_set.cc:494'      # a file:line from the summary
#   ./ubsan_trace.sh 'member call on address'         # any substring works
#   ./ubsan_trace.sh 'histogram.cc:318' ~/Downloads/ubsan-logs-x86_64
#
# UBSan logs are laid out one folder per test: <suite>/<case>/ubsan.<pid>.
# This lists every test (suite/case) whose log matched the pattern, then prints
# the first full symbolized stack for it. The pattern is matched literally (-F).
set -euo pipefail

pat="${1:?usage: ubsan_trace.sh <grep-pattern> [logs-dir]}"
dir="${2:-.}"

echo "== tests that hit: ${pat} =="
mapfile -t hits < <(grep -rlF --include='ubsan.*' -- "${pat}" "${dir}" 2>/dev/null || true)
if [[ "${#hits[@]}" -eq 0 ]]; then
  echo "(no matches under ${dir})"
  exit 0
fi
# <suite>/<case> is the parent folder of each matching ubsan.<pid> file.
for f in "${hits[@]}"; do dirname "${f}"; done | sort -u | sed "s|^${dir%/}/||"

echo ""
echo "== first full stack (${hits[0]}) =="
# Print from the matching "runtime error:" line through its SUMMARY line.
awk -v p="${pat}" 'index($0, p) { f = 1 } f { print } f && /^SUMMARY/ { exit }' "${hits[0]}"
