#!/usr/bin/env python3
"""Rank headers by how often a Ninja target's production TUs open them.

The tool reads CMake's compile_commands.json, selects C++ source files that are both
under --source-root and in `ninja -t inputs <target>`, and replays each compiler
command with -H -fsyntax-only. -H emits every header opened by the compiler;
-fsyntax-only runs preprocessing, parsing, and semantic analysis without creating
an object file, assembling, or linking.

This is intentionally not a replacement for a cold-build benchmark. It measures
which headers are repeatedly opened and omits code generation, assembly, linking,
and PCH creation. Use it to select a small candidate PCH set, then benchmark PCH
on and off with clean build directories.

Example:
  tools/analyze_header_frequency.py \
      --build-dir build-dbg --target dragonfly --source-root src/server \
      --output-dir pch-analysis/gcc-debug-server

The output directory contains ranked TSV reports by raw opens and by distinct
translation-unit coverage, a library-family summary for standard, Boost,
Abseil, Helio, and Dragonfly headers, one raw compiler trace per source,
source-level status, and summary.json. Re-run with --compiler clang++ after
configuring a Clang build directory to compare compiler-specific include trees.
Existing output directories are rejected unless --overwrite is supplied.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
from dataclasses import dataclass


CPP_SUFFIXES = {".cc", ".cpp", ".cxx", ".c++", ".cp"}


@dataclass(frozen=True)
class Compilation:
    source: Path
    directory: Path
    arguments: tuple[str, ...]


@dataclass(frozen=True)
class TraceResult:
    source: Path
    returncode: int
    headers: tuple[str, ...]
    trace_file: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True, help="CMake/Ninja build directory")
    parser.add_argument(
        "--target", required=True, help="Ninja target whose source closure is analyzed"
    )
    parser.add_argument(
        "--source-root",
        type=Path,
        action="append",
        default=[],
        help="Repository-relative source root to include; repeatable (default: src)",
    )
    parser.add_argument(
        "--output-dir", type=Path, required=True, help="Directory for reports and traces"
    )
    parser.add_argument(
        "--jobs", type=int, default=os.cpu_count() or 1, help="Parallel compiler processes"
    )
    parser.add_argument(
        "--compiler",
        help="Replace the compiler executable from compile_commands.json (for diagnostics only)",
    )
    parser.add_argument(
        "--overwrite", action="store_true", help="Allow an existing nonempty output directory"
    )
    return parser.parse_args()


def resolve_from(directory: Path, value: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = directory / candidate
    return candidate.resolve(strict=False)


def read_compilations(database: Path) -> list[Compilation]:
    entries = json.loads(database.read_text())
    compilations = []
    for entry in entries:
        directory = Path(entry["directory"]).resolve()
        source = resolve_from(directory, entry["file"])
        if source.suffix not in CPP_SUFFIXES:
            continue
        arguments = tuple(entry.get("arguments") or shlex.split(entry["command"]))
        compilations.append(Compilation(source, directory, arguments))
    return compilations


def target_inputs(build_dir: Path, target: str) -> set[Path]:
    result = subprocess.run(
        ["ninja", "-C", str(build_dir), "-t", "inputs", target],
        check=True,
        capture_output=True,
        text=True,
    )
    return {Path(line).resolve(strict=False) for line in result.stdout.splitlines() if line}


def is_under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def strip_output_arguments(arguments: tuple[str, ...]) -> list[str]:
    result: list[str] = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in {"-c", "-MD", "-MMD"}:
            index += 1
            continue
        if argument in {"-o", "-MF", "-MT", "-MQ"}:
            index += 2
            continue
        if argument.startswith(("-o", "-MF", "-MT", "-MQ")):
            index += 1
            continue
        result.append(argument)
        index += 1
    return result


def extract_headers(trace: str) -> tuple[str, ...]:
    headers = []
    for line in trace.splitlines():
        stripped = line.lstrip(".")
        if len(stripped) == len(line) or not stripped.startswith(" "):
            continue
        header = stripped.strip()
        if header:
            headers.append(header)
    return tuple(headers)


def trace_compilation(
    compilation: Compilation, output_dir: Path, compiler: str | None
) -> TraceResult:
    arguments = strip_output_arguments(compilation.arguments)
    if compiler:
        arguments[0] = compiler
    arguments.extend(["-H", "-fsyntax-only"])
    result = subprocess.run(arguments, cwd=compilation.directory, capture_output=True, text=True)
    trace = result.stderr
    digest = hashlib.sha256(str(compilation.source).encode()).hexdigest()[:16]
    trace_file = output_dir / "traces" / f"{digest}.stderr"
    trace_file.write_text(trace)
    return TraceResult(compilation.source, result.returncode, extract_headers(trace), trace_file)


def classify_header(header: str, repository: Path) -> str:
    path = Path(header)
    if not path.is_absolute():
        return "unresolved"
    path = path.resolve(strict=False)
    for project_root in (repository / "src", repository / "helio", repository / "genfiles"):
        if is_under(path, project_root):
            return "project"
    return "external"


def library_family(header: str, repository: Path) -> str:
    path = Path(header).resolve(strict=False)
    if is_under(path, repository / "helio"):
        return "helio"
    if is_under(path, repository / "src") or is_under(path, repository / "genfiles"):
        return "dragonfly"
    if "/absl/" in header:
        return "absl"
    if "/boost/" in header:
        return "boost"
    if "/include/c++/" in header:
        return "std"
    if "/usr/include/" in header or "/usr/lib/gcc/" in header:
        return "system"
    return "other"


def write_report(path: Path, counts: collections.Counter[str], column: str) -> None:
    with path.open("w") as report:
        report.write(f"{column}\theader\n")
        for header, count in counts.most_common():
            report.write(f"{count}\t{header}\n")


def write_family_summary(
    path: Path,
    opens: collections.Counter[str],
    coverage: collections.Counter[str],
    repository: Path,
) -> None:
    families: dict[str, list[int]] = {}
    for header, count in opens.items():
        family = library_family(header, repository)
        totals = families.setdefault(family, [0, 0, 0])
        totals[0] += count
        totals[1] += 1
        totals[2] += coverage[header]
    with path.open("w") as report:
        report.write("family\traw_header_opens\tunique_headers\tsummed_tu_coverage\n")
        for family, totals in sorted(families.items(), key=lambda item: (-item[1][0], item[0])):
            report.write(f"{family}\t{totals[0]}\t{totals[1]}\t{totals[2]}\n")


def main() -> int:
    args = parse_args()
    build_dir = args.build_dir.resolve()
    database = build_dir / "compile_commands.json"
    if not database.is_file():
        raise SystemExit(f"Missing compilation database: {database}")
    if args.jobs < 1:
        raise SystemExit("--jobs must be at least 1")
    if args.output_dir.exists() and any(args.output_dir.iterdir()) and not args.overwrite:
        raise SystemExit(f"Output directory is not empty: {args.output_dir}; use --overwrite")

    repository = Path.cwd().resolve()
    source_roots = [
        resolve_from(repository, str(root)) for root in args.source_root or [Path("src")]
    ]
    inputs = target_inputs(build_dir, args.target)
    compilations = [
        compilation
        for compilation in read_compilations(database)
        if compilation.source in inputs
        and any(is_under(compilation.source, root) for root in source_roots)
    ]
    if not compilations:
        roots = ", ".join(str(root) for root in source_roots)
        raise SystemExit(
            f"No C++ compilation commands under {roots} found for target {args.target}"
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "traces").mkdir(exist_ok=True)
    results: list[TraceResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = [
            executor.submit(trace_compilation, compilation, args.output_dir, args.compiler)
            for compilation in compilations
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    results.sort(key=lambda result: str(result.source))
    all_headers: collections.Counter[str] = collections.Counter()
    project_headers: collections.Counter[str] = collections.Counter()
    external_headers: collections.Counter[str] = collections.Counter()
    all_coverage: collections.Counter[str] = collections.Counter()
    project_coverage: collections.Counter[str] = collections.Counter()
    external_coverage: collections.Counter[str] = collections.Counter()
    with (args.output_dir / "sources.tsv").open("w") as report:
        report.write("source\tstatus\theader_opens\ttrace\n")
        for result in results:
            all_headers.update(result.headers)
            for header in set(result.headers):
                classification = classify_header(header, repository)
                all_coverage[header] += 1
                if classification == "project":
                    project_coverage[header] += 1
                else:
                    external_coverage[header] += 1
            for header in result.headers:
                if classify_header(header, repository) == "project":
                    project_headers[header] += 1
                else:
                    external_headers[header] += 1
            status = "ok" if result.returncode == 0 else f"failed:{result.returncode}"
            report.write(f"{result.source}\t{status}\t{len(result.headers)}\t{result.trace_file}\n")

    write_report(args.output_dir / "all-headers.tsv", all_headers, "opens")
    write_report(args.output_dir / "project-headers.tsv", project_headers, "opens")
    write_report(args.output_dir / "external-headers.tsv", external_headers, "opens")
    write_report(args.output_dir / "all-coverage.tsv", all_coverage, "translation_units")
    write_report(args.output_dir / "project-coverage.tsv", project_coverage, "translation_units")
    write_report(args.output_dir / "external-coverage.tsv", external_coverage, "translation_units")
    write_family_summary(
        args.output_dir / "library-summary.tsv", all_headers, all_coverage, repository
    )
    summary = {
        "build_dir": str(build_dir),
        "target": args.target,
        "source_roots": [str(root) for root in source_roots],
        "compiler_override": args.compiler,
        "translation_units": len(results),
        "successful_translation_units": sum(result.returncode == 0 for result in results),
        "failed_translation_units": sum(result.returncode != 0 for result in results),
        "total_header_opens": sum(all_headers.values()),
        "unique_headers": len(all_headers),
    }
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["failed_translation_units"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
