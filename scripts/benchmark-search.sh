#!/usr/bin/env bash
# The real search algorithms, with shared synthetic storage and identical compiler flags. No app services or user files.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
search_benchmark_mode="${1:-release}"
case "$search_benchmark_mode" in
  release) search_benchmark_optimization=-O ;;
  debug) search_benchmark_optimization=-Onone ;;
  *) echo 'Usage: scripts/benchmark-search.sh [release|debug] [10000...3000000 entries]' >&2; exit 2 ;;
esac
search_benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-search-benchmark.XXXXXX")
trap 'rm -rf "$search_benchmark_dir"' EXIT
# Compile both algorithms with the same current storage and arithmetic, removing only its package import.
sed '/^import StrataSupport$/d' Sources/Strata/Index/IndexStore.swift > "$search_benchmark_dir/IndexStore.swift"
git show v0.7.5:Sources/Strata/Index/IndexSearch.swift > "$search_benchmark_dir/IndexSearchBaseline.swift"
for search_benchmark_variant in baseline current; do
  if [[ "$search_benchmark_variant" == baseline ]]; then
    search_benchmark_source="$search_benchmark_dir/IndexSearchBaseline.swift"
  else
    search_benchmark_source=Sources/Strata/Index/IndexSearch.swift
  fi
  xcrun swiftc "$search_benchmark_optimization" -D DEBUG -swift-version 6 -parse-as-library -package-name Strata \
    -target arm64-apple-macos26.0 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -Xllvm -sil-disable-pass=optimize-hop-to-executor -module-cache-path "$search_benchmark_dir/modules" \
    "$search_benchmark_dir/IndexStore.swift" "$search_benchmark_source" Sources/Strata/Index/SearchTerms.swift \
    Sources/Strata/Support/Format.swift Tests/Benchmarks/SearchBenchmark.swift -o "$search_benchmark_dir/$search_benchmark_variant"
done
for search_benchmark_variant in baseline current; do
  echo "algorithm=$search_benchmark_variant configuration=$search_benchmark_mode"
  nice -n 10 "$search_benchmark_dir/$search_benchmark_variant" "${2:-1000000}"
done
