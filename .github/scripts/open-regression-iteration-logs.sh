#!/bin/bash

set -e -o pipefail

Usage() {
  cat <<'EOF'
Usage: bash open-regression-iteration-logs.sh ITERATION

Extracts iteration_ITERATION_logs.tar.zst from the current directory into
iteration_ITERATION_logs/. The archive must be downloaded from the logs artifact.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  Usage
  exit 0
fi

if [[ "$#" -ne 1 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  Usage >&2
  exit 2
fi

iteration=$1
archive_path="iteration_${iteration}_logs.tar.zst"
output_dir="iteration_${iteration}_logs"

if [[ ! -f "${archive_path}" ]]; then
  echo "Archive not found: ${archive_path}" >&2
  exit 1
fi

if [[ -e "${output_dir}" ]]; then
  echo "Extraction path already exists: ${output_dir}" >&2
  exit 1
fi

mkdir "${output_dir}"
tar --use-compress-program='zstd -d -T0' -xf "${archive_path}" -C "${output_dir}"
echo "Extracted ${archive_path} to ${output_dir}/"
