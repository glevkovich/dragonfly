#!/usr/bin/env bash
#
# Summarize UBSan findings from a test run into GitHub-flavored markdown, written
# to stdout. The workflow appends it to the job summary:
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
# Official list of every UBSan check name (unsigned-integer-overflow, implicit-
# conversion, vptr, ...) with a one-line definition of each.
UBSAN_CHECKS_DOC="https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html#available-checks"

# grep -rH keeps the source filename on every line so each finding can be
# attributed to an example test. Logs live at <suite>/<case>/ubsan.<pid> (one
# folder per test); we recurse and match only the ubsan.* files.
# (Full symbolized stacks stay in the uploaded artifact; here we keep headlines.)
raw="$(grep -rH -i "runtime error:" --include='ubsan.*' "${logs_dir}" 2>/dev/null || true)"

# Classify each finding into UB (real bugs) vs SUSP (defined-but-flagged by the
# extra integer / implicit-conversion checks). The message carries the operand
# TYPE, so unsigned wrap/shift/negation (defined) is told apart from its signed
# counterpart (UB). "division by zero" stays in UB (integer div-by-zero is UB).
# Output: BUCKET<TAB>KIND<TAB>file:line:col<TAB>example-test
classify() {
  awk '
    # Only real findings carry "runtime error:". Skipping everything else keeps
    # empty / blank input from being miscounted as a bogus "other" finding.
    !/runtime error:/ { next }
    {
      # grep -rH prefixed "<path>/<suite>/<case>/ubsan.<pid>:" -- split it off the
      # finding text at the first colon (log paths contain no colon).
      ci = index($0, ":");
      fname = substr($0, 1, ci - 1);
      rest  = substr($0, ci + 1);
      # The last two path components are the suite (file) and case (name + params)
      # -- that is the example test we attribute this location to.
      nseg = split(fname, seg, "/");
      test = (nseg >= 3) ? seg[nseg-2] "/" seg[nseg-1] : seg[nseg];

      loc=rest; sub(/ runtime error:.*/, "", loc); sub(/^[ \t]+/, "", loc);
      low=tolower(rest); b="UB"; k="other";
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
      print b "\t" k "\t" loc "\t" test;
    }'
}

tagged="$(printf '%s\n' "${raw}" | classify)"

count_bucket() { printf '%s\n' "${tagged}" | awk -F'\t' -v b="$1" '$1==b' | grep -c . || true; }
emit_types()   { printf '%s\n' "${tagged}" | awk -F'\t' -v b="$1" '$1==b {print $2}' \
                   | sort | uniq -c | sort -rn | awk '{printf "+ %s\n", $0}'; }
# One row per location: count, kind, file:line, and ONE example test that hit it
# (other tests may hit the same line -- the INFO note shows how to list them all).
emit_locs()    { printf '%s\n' "${tagged}" \
                   | awk -F'\t' -v b="$1" '
                       $1==b { c[$3]++; kind[$3]=$2; if (!($3 in ex)) ex[$3]=$4 }
                       END { for (l in c) printf "%d\t%s\t%s\t%s\n", c[l], kind[l], l, ex[l] }' \
                   | sort -rn | head -300 \
                   | awk -F'\t' '{ printf "%7d  %-18s %s  (e.g. %s)\n", $1, $2, $3, $4 }'; }

ub_total="$(count_bucket UB)"
susp_total="$(count_bucket SUSP)"
total=$(( ub_total + susp_total ))

# --- Sections first (UB, then suspicious), totals as a footer ---------------
emit_section() {
  local bucket="$1" total_n="$2"
  if [[ "${bucket}" == "UB" ]]; then
    echo "## Undefined behaviors — ${total_n} occurrence(s) · ${arch}"
    echo ""
    echo "> [!CAUTION]"
    echo "> These are **real C++ undefined behavior**: the program violates the C++ standard, so the standard imposes **no requirements** on the result — the compiler may miscompile, crash, or silently corrupt data. These should be fixed."
    echo "> Nuance: \`divide-by-zero\` on *floating point* (e.g. \`100.0/0\`) is UB by the standard but yields \`inf\` on IEEE-754 hardware, so it does **not** crash in practice; *integer* division by zero is a genuine crash (SIGFPE)."
  else
    echo "## Suspicious / defined-but-flagged — ${total_n} occurrence(s) · ${arch}"
    echo ""
    echo "> [!WARNING]"
    echo "> Well-defined behavior surfaced by the extra integer & implicit-conversion checks (unsigned wrap/shift/negation, narrowing conversions). Not C++ standard violations, but worth a look for unintended truncation / sign bugs."
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
  echo "<details><summary>locations (count &middot; type &middot; file:line &middot; example test)</summary>"
  echo ""
  echo '```'
  emit_locs "${bucket}"
  echo '```'
  echo ""
  echo "</details>"
  echo ""
}

# Blue INFO banner at the very top: how to read the report + how to reach the
# artifact, and WHY the tests still pass despite these findings.
emit_intro() {
  echo "> [!NOTE]"
  echo "> **How to read this report.** Each row below is one UBSan diagnostic (\`file:line:col\`), deduplicated and counted. **These findings do NOT fail the job and the tests still pass** — UBSan here is *recoverable*: it prints the diagnostic and lets the program keep running. Production binaries are built **without** UBSan, so they carry no such instrumentation (and standard-but-defined cases like float divide-by-zero don't crash there)."
  echo "> "
  echo "> The summary tells you **what / where**; the uploaded \`ubsan-logs-${arch}\` artifact tells you **who / why** — the exact test and the full call stack. Each location lists **one example test** (\`suite/case\`); other tests may hit the same line too."
  echo "> "
  echo "> References: [what is C++ undefined behavior](${UB_LINK}) · [what each UBSan check means — unsigned-integer-overflow, implicit-conversion, ...](${UBSAN_CHECKS_DOC})"
  echo ""
  echo "Triage: read the summary → pick a \`file:line\` → unzip the \`ubsan-logs-${arch}\` artifact and, from its root, run:"
  echo ""
  echo '```bash'
  echo "# 1) which tests hit this location (each match is <suite>/<case>/ubsan.<pid>):"
  echo "grep -rl 'src/core/dense_set.cc:494' ."
  echo "# 2) jump to the full symbolized stack in one of those files:"
  echo "grep -n -A40 'src/core/dense_set.cc:494' <suite>/<case>/ubsan.*"
  echo "# ...or let the bundled helper do both (it takes any grep pattern):"
  echo "./ubsan_trace.sh 'src/core/dense_set.cc:494'"
  echo '```'
  echo ""
}

emit_intro
emit_section UB "${ub_total}"
emit_section SUSP "${susp_total}"

# --- Totals footer ----------------------------------------------------------
echo "---"
echo ""
echo "**${total}** finding occurrence(s): **${ub_total}** undefined behavior, **${susp_total}** suspicious / defined-but-flagged. Locations are deduplicated by file:line. **For the full symbolized stack traces, download the \`ubsan-logs-${arch}\` artifact** attached to this run."
echo ""
