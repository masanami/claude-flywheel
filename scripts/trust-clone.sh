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
# 【重要】Claude Code のセッションを閉じてから実行すること。稼働中のセッションは
# ~/.claude.json を随時書き戻すため、本スクリプトの変更が上書きされて消える（trust した
# のに効かない）か、逆にセッション側の直近の変更を巻き戻す恐れがある。書き込み前に
# ~/.claude.json.bak.<timestamp> へバックアップを取り、読み込み後にファイルが変化して
# いたら中断する。
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

# name はクローン先ディレクトリ名。パス区切り / .. / . を含むと CLONE_DIR 自体や外側を
# 指してしまい、意図しないパス（例: name="." で全クローンの親ディレクトリごと）を誤って
# trust 承認してしまいかねないため弾く。
case "$name" in
  . | */* | *..*)
    echo "trust-clone: 不正な name（/ や .. や . は使えません）: $name" >&2
    exit 2
    ;;
esac

dest="$CLONE_DIR/$name"

if [ ! -d "$dest" ]; then
  echo "trust-clone: 対象ディレクトリが見つかりません: $dest" >&2
  exit 1
fi

# trust 対象は git クローンの実体に限定する（repo ですらないディレクトリの誤承認を防ぐ）。
if [ ! -d "$dest/.git" ]; then
  echo "trust-clone: $dest は git クローンではありません（.git がありません）。trust 対象にできません。" >&2
  exit 1
fi

echo "注意: Claude Code のセッションを閉じてから実行してください（稼働中セッションの ~/.claude.json 書き戻しと競合します）。" >&2

abs_path="$(cd "$dest" && pwd -P)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "trust-clone: python3 が見つかりません。~/.claude.json の projects[\"$abs_path\"].hasTrustDialogAccepted を手動で true に設定してください。" >&2
  exit 1
fi

CLONE_PATH="$abs_path" python3 - <<'PY'
import json
import os
import stat
import sys

path = os.environ["CLONE_PATH"]
claude_json = os.path.expanduser("~/.claude.json")

orig_stat = None
try:
    orig_stat = os.stat(claude_json)
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

# 既存ファイルのパーミッションを引き継ぐ（無ければ 600 ＝ 所有者のみ読み書き可、を既定にする）。
orig_mode = stat.S_IMODE(orig_stat.st_mode) if orig_stat else 0o600

# 巻き戻し事故に備えて置換前にバックアップを取る（lost update 発生時の復旧手段）。
if orig_stat:
    import shutil
    import time

    backup = f"{claude_json}.bak.{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(claude_json, backup)
    print(f"backup: {backup}")

# 読み込み後にファイルが変化していたら中断する（稼働中の Claude Code セッションの
# 書き戻しとの競合＝lost update を検出。セッションを閉じてから再実行する）。
try:
    now_stat = os.stat(claude_json)
    if orig_stat is None or (now_stat.st_mtime_ns, now_stat.st_size) != (orig_stat.st_mtime_ns, orig_stat.st_size):
        print(
            f"trust-clone: {claude_json} が読み込み後に変更されました（Claude Code セッションが稼働中の可能性）。"
            "セッションを閉じてから再実行してください。",
            file=sys.stderr,
        )
        sys.exit(1)
except FileNotFoundError:
    if orig_stat is not None:
        # 読み込み時に存在したファイルが後続プロセスに削除された＝競合。古いスナップショット
        # から os.replace で復活させると lost update になるため中断する。
        print(
            f"trust-clone: {claude_json} が読み込み後に削除されました（競合の可能性）。"
            "セッションを閉じてから再実行してください。",
            file=sys.stderr,
        )
        sys.exit(1)
    pass  # 元から無い場合はそのまま新規作成に進む

# tmp は作成時点からパーミッションを制限し（umask 依存で一時的に他ユーザ可読になるのを防ぐ）、
# O_EXCL で同時実行の tmp 衝突も検出する。
tmp = claude_json + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, orig_mode)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, claude_json)  # 同一ファイルシステム内のアトミックな置き換え（書き込み中断時の破損を防ぐ）
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise

print(f"trusted: {path}")
PY
