#!/usr/bin/env bash

# Local test harness for tools/deps_cache_manifest.py.
# Run with: bash tools/test_deps_cache_manifest.sh
# It times a 1,000-file fixture and verifies that validation rejects additions,
# deletions, content/size/metadata changes, symlink changes, and unsupported files.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest_tool="$repo_root/tools/deps_cache_manifest.py"
workspace=$(mktemp -d)
template="$workspace/template"
timing_template="$workspace/timing-template"

cleanup() {
  rm -rf "$workspace"
}
trap cleanup EXIT

now_ns() {
  date +%s%N
}

elapsed_ms() {
  echo $((($2 - $1) / 1000000))
}

make_case() {
  case_dir="$workspace/case"
  rm -rf "$case_dir"
  cp -a "$template" "$case_dir"
  python3 "$manifest_tool" generate --root "$case_dir" --manifest "$case_dir/manifest" cache
  python3 "$manifest_tool" validate --root "$case_dir" --manifest "$case_dir/manifest" cache
}

expect_rejected() {
  local description="$1"
  local command="$2"
  make_case
  bash -c "$command" -- "$case_dir"
  if python3 "$manifest_tool" validate --root "$case_dir" --manifest "$case_dir/manifest" cache >/dev/null 2>&1; then
    echo "expected validation failure: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

mkdir -p "$template/cache/nested" "$timing_template/cache/nested"
printf 'cache fixture 0001\n' > "$template/cache/nested/file-0001"
printf 'cache fixture 0002\n' > "$template/cache/nested/file-0002"
ln -s nested/file-0001 "$template/cache/link"

for number in $(seq 1 1000); do
  printf 'cache fixture %04d\n' "$number" > "$timing_template/cache/nested/file-$number"
done
ln -s nested/file-0001 "$timing_template/cache/link"

case_dir="$workspace/timed-case"
cp -a "$timing_template" "$case_dir"
started=$(now_ns)
python3 "$manifest_tool" generate --root "$case_dir" --manifest "$case_dir/manifest" cache
manifest_generate_ms=$(elapsed_ms "$started" "$(now_ns)")
started=$(now_ns)
python3 "$manifest_tool" validate --root "$case_dir" --manifest "$case_dir/manifest" cache
manifest_validate_ms=$(elapsed_ms "$started" "$(now_ns)")
echo "Timing for 1,000 regular files, 2 directories, and 1 symlink:"
echo "  generate: ${manifest_generate_ms} ms"
echo "  validate: ${manifest_validate_ms} ms"

expect_rejected "same-size regular-file content change" \
  'printf "other fixture 0001\n" > "$1/cache/nested/file-0001"'
expect_rejected "regular-file size change" \
  'printf "larger content\n" >> "$1/cache/nested/file-0001"'
expect_rejected "regular-file deletion" \
  'rm "$1/cache/nested/file-0001"'
expect_rejected "selected cache directory deletion" \
  'rm -rf "$1/cache"'
expect_rejected "new regular file" \
  'printf "new\n" > "$1/cache/nested/new-file"'
expect_rejected "regular-file permission change" \
  'chmod 600 "$1/cache/nested/file-0001"'
expect_rejected "regular-file mtime change" \
  'touch -d @1000000000 "$1/cache/nested/file-0001"'
expect_rejected "new directory" \
  'mkdir "$1/cache/new-directory"'
expect_rejected "directory permission change" \
  'chmod 700 "$1/cache/nested"'
expect_rejected "directory mtime change" \
  'touch -d @1000000000 "$1/cache/nested"'
expect_rejected "symlink target change" \
  'rm "$1/cache/link" && ln -s nested/file-0002 "$1/cache/link"'
expect_rejected "symlink deletion" \
  'rm "$1/cache/link"'
expect_rejected "symlink mtime change" \
  'touch -h -d @1000000000 "$1/cache/link"'
expect_rejected "unsupported filesystem entry" \
  'mkfifo "$1/cache/fifo"'

echo "All manifest mutation checks passed."
