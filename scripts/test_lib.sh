#!/usr/bin/env bash
# Shared helpers for test scripts. Source this; do not execute.

set -euo pipefail

if [ -t 1 ]; then
    _C_GREEN=$'\033[32m'; _C_RED=$'\033[31m'; _C_YELLOW=$'\033[33m'; _C_RESET=$'\033[0m'
else
    _C_GREEN=""; _C_RED=""; _C_YELLOW=""; _C_RESET=""
fi

pass() { printf '%sPASS%s: %s\n' "$_C_GREEN" "$_C_RESET" "$1"; }
fail() { printf '%sFAIL%s: %s — %s\n' "$_C_RED" "$_C_RESET" "$1" "$2" >&2; exit 1; }
skip() { printf '%sSKIP%s: %s — %s\n' "$_C_YELLOW" "$_C_RESET" "$1" "$2"; exit 0; }
need() { command -v "$1" >/dev/null 2>&1 || fail "${TEST_NAME:-$0}" "missing dependency: $1"; }

# Repo root = parent of scripts/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
