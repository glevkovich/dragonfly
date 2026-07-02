#!/usr/bin/env bash
#
# Summarize UBSan findings from a connection_test.py run into GitHub-flavored
# markdown, written to stdout. The workflow appends it to the job summary:
#
#   bash ubsan_summarize_findings.sh <ubsan-logs-dir> <arch> >> "$GITHUB_STEP_SUMMARY"
#
# Run it locally too -- see tools/sanitizers/ubsan/README.md ("Summarizing
# findings"). Example after a local sanitized run that wrote logs with
# UBSAN_OPTIONS=...:log_path=build-dbg/ubsan-logs/pytest :
#
#   bash tools/sanitizers/ubsan/ubsan_summarize_findings.sh build-dbg/ubsan-logs local | less
#
# Why a script (not inline YAML): the classification + formatting is long and
# fiddly; keeping it here makes ubsan.yml short and lets us test locally.
#
# Color in job summaries: GitHub strips inline CSS, so we colorize via
#   - GitHub "alerts" (blockquote callouts): [!CAUTION] = red, [!WARNING] = amber.
#     (Alerts only color the icon/border/heading; body text stays theme-readable.)
#   - ```diff fences: lines beginning with '+' render green.
#
set -euo pipefail

logs_dir="${1:?usage: ubsan_summarize_findings.sh <logs-dir> <arch>}"
arch="${2:?usage: ubsan_summarize_findings.sh <logs-dir> <arch>}"

UB_LINK="https://en.cppreference.com/w/cpp/language/ub"

# Headline lines only -- full symbolized stacks stay in the uploaded artifact.
raw="$(cat "${logs_dir}"/pytest.* 2>/dev/null | grep -i "runtime error:" || true)"

# Classify each finding into UB (real bugs) vs SUSP (defined-but-flagged by the
# extra integer / implicit-conversion checks). The message carries the operand
# TYPE, so unsigned wrap/shift/negation (defined) is told apart from its signed
# counterpart (UB). "division by zero" stays in UB (integer div-by-zero is UB).
# Output: BUCKET<TAB>KIND<TAB>file:line:col
classify() {
  awk '
    {
      loc=$0; sub(/ runtime error:.*/, "", loc); sub(/^[ \t]+/, "", loc);
      low=tolower($0); b="UB"; k="other";
      if (low ~ /implicit conversion/)                       { b="SUSP"; k="implicit-conversion" }
      else if (low ~ /unsigned integer overflow/)            { b="SUSP"; k="unsigned-overflow" }
      else if (low ~ /negation of/) {
        if (low ~ /type .(unsigned|uint|size_t|size_type|value_type)/) { b="SUSP"; k="unsigned-negation" }
        else { b="UB"; k="signed-negation" } }
      else if (low ~ /left shift of/) {
        if (low ~ /type .(unsigned|uint)/) { b="SUSP"; k="unsigned-shift-base" }
        else { b="UB"; k="signed-shift-base" } }
      else if (low ~ /shift exponent/)                       { b="UB"; k="shift-exponent" }
      else if (low ~ /misaligned address/)                   { b="UB"; k="misaligned-load" }
      else if (low ~ /member call on address|does not point to an object/) { b="UB"; k="vptr" }
      else if (low ~ /out of bounds/)                        { b="UB"; k="out-of-bounds" }
      else if (low ~ /null pointer/)                         { b="UB"; k="null-argument" }
      else if (low ~ /incorrect function type/)              { b="UB"; k="function-type" }
      else if (low ~ /signed integer overflow/)              { b="UB"; k="signed-overflow" }
      else if (low ~ /division by zero/)                     { b="UB"; k="divide-by-zero" }
      print b "\t" k "\t" loc;
    }'
}

tagged="$(printf '%s\n' "${raw}" | classify)"

count_bucket() { printf '%s\n' "${tagged}" | awk -F'\t' -v b="$1" '$1==b' | grep -c . || true; }
emit_types()   { printf '%s\n' "${tagged}" | awk -F'\t' -v b="$1" '$1==b {print $2}' \
                   | sort | uniq -c | sort -rn | awk '{printf "+ %s\n", $0}'; }
emit_locs()    { printf '%s\n' "${tagged}" | awk -F'\t' -v b="$1" '$1==b {print $2"  "$3}' \
                   | sort | uniq -c | sort -rn | head -300; }

ub_total="$(count_bucket UB)"
susp_total="$(count_bucket SUSP)"
total=$(( ub_total + susp_total ))

# --- Header + totals --------------------------------------------------------
echo "## UBSan findings (${arch})"
echo ""
echo "**${total}** finding occurrence(s): **${ub_total}** undefined behavior, **${susp_total}** suspicious / defined-but-flagged."
echo ""
echo "Locations are deduplicated by file:line. **For the full symbolized stack traces, download the \`ubsan-logs-${arch}\` artifact** attached to this run."
echo ""

emit_section() {
  local bucket="$1" total_n="$2"
  if [[ "${bucket}" == "UB" ]]; then
    echo "> [!CAUTION]"
    echo "> **Undefined behaviors — ${total_n} occurrence(s).** These are **real C++ undefined behavior**: the program violates the C++ standard, so the standard imposes **no requirements** on the result — the compiler may miscompile, crash, or silently corrupt data. These should be fixed. Reference: ${UB_LINK}"
  else
    echo "> [!WARNING]"
    echo "> **Suspicious / defined-but-flagged — ${total_n} occurrence(s).** Well-defined behavior surfaced by the extra integer & implicit-conversion checks (unsigned wrap/shift/negation, narrowing conversions). Not C++ standard violations, but worth a look for unintended truncation / sign bugs."
  fi
  echo ""
  if [[ "${total_n}" -eq 0 ]]; then
    echo "_none_"
    echo ""
    return
  fi
  echo "By check type:"
  echo '```diff'
  emit_types "${bucket}"
  echo '```'
  echo ""
  echo "<details><summary>locations (count &middot; type &middot; file:line)</summary>"
  echo ""
  echo '```'
  emit_locs "${bucket}"
  echo '```'
  echo ""
  echo "</details>"
  echo ""
}

emit_section UB "${ub_total}"
emit_section SUSP "${susp_total}"
