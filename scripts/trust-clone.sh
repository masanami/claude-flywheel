#!/usr/bin/env bash
#
# trust-clone.sh — 作業用クローンを Claude Code の trust 承認済みにする。
#
# 新規クローンは Claude Code の trust 未承認から始まり、`.claude/settings.json` の
# permissions.allow が無効化される（sync-repos.sh が読み取り専用で検出・警告する既知の
# 落とし穴）。本スクリプトは対象クローンの絶対パス（realpath）を ~/.claude.json の
# projects["<絶対パス>"].hasTrustDialogAccepted に true として書き込み、trust 承認済みに
# する（内部は python3 で JSON を読み込み、無ければ {} から開始し、.tmp に書いて
# os.replace でアトミックに置換する）。
#
# 【重要】本スクリプトはエージェント自身が実行してはならない（Self-Modification として
# ブロックされる対象。~/.claude.json への書き込みは人間の一度きりの手動作業）。
#
# 使い方:
#   scripts/trust-clone.sh [-d <clone-dir>] <name>
#
#   -d  クローン先ディレクトリ（既定: .flywheel/repos）
#   <name>  repos.tsv に定義したクローン名（<clone-dir>/<name> に実体がある想定）
#
# 例:
#   scripts/trust-clone.sh billing-api
#   scripts/trust-clone.sh -d .flywheel/repos billing-api

set -euo pipefail

CLONE_DIR=".flywheel/repos"

while getopts "d:h" opt; do
  case "$opt" in
    d) CLONE_DIR="$OPTARG" ;;
    h) sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [-d clone-dir] <name>" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

name="${1:-}"

if [ -z "$name" ]; then
  echo "trust-clone: <name> が必要です（例: trust-clone.sh billing-api）" >&2
  echo "usage: $0 [-d clone-dir] <name>" >&2
  exit 2
fi

# name はクローン先ディレクトリ名。パス区切り / .. を含むと CLONE_DIR の外を指してしまい、
# 意図しないパスを誤って trust 承認してしまいかねないため弾く（sync-repos.sh と同じ検証）。
case "$name" in
  */* | *..*)
    echo "trust-clone: 不正な name（/ や .. は使えません）: $name" >&2
    exit 2
    ;;
esac

dest="$CLONE_DIR/$name"

if [ ! -d "$dest" ]; then
  echo "trust-clone: 対象ディレクトリが見つかりません: $dest" >&2
  exit 1
fi

abs_path="$(cd "$dest" && pwd -P)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "trust-clone: python3 が見つかりません。~/.claude.json の projects[\"$abs_path\"].hasTrustDialogAccepted を手動で true に設定してください。" >&2
  exit 1
fi

CLONE_PATH="$abs_path" python3 - <<'PY'
import json
import os
import sys

path = os.environ["CLONE_PATH"]
claude_json = os.path.expanduser("~/.claude.json")

try:
    with open(claude_json, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as exc:
    print(f"trust-clone: {claude_json} の解析に失敗しました: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(f"trust-clone: {claude_json} の形式が想定外です（トップレベルがオブジェクトではありません）", file=sys.stderr)
    sys.exit(1)

data.setdefault("projects", {}).setdefault(path, {})["hasTrustDialogAccepted"] = True

tmp = claude_json + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, claude_json)  # 同一ファイルシステム内のアトミックな置き換え（書き込み中断時の破損を防ぐ）

print(f"trusted: {path}")
PY
