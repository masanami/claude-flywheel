#!/usr/bin/env bash
#
# sync-repos.sh — 関連リポジトリ（作業用クローン）を repos.tsv に従って同期する。
#
# マニフェスト（repos.tsv, Git 追跡）と クローン実体（.flywheel/repos/, .gitignore）を分離し、
# 純シェルで冪等に clone / fetch する（yq 等の依存なし）。
#
# クローンは「作業用」（編集・ブランチ・コミット可）に一本化している。そのため
# ローカルのブランチ作業を壊さないよう、同期はあくまで安全側に倒す:
#   - 未 clone     → 既定ブランチを clone する。
#   - clone 済み   → まず fetch でリモート追跡を更新し、ワーキングツリーが clean かつ
#                    既定ブランチ上のときだけ ff-only で前進させる。
#                    dirty / 別ブランチのときは更新せずスキップして警告（作業を保持）。
# 既存クローンを git pull で上書きすることはしない。
#
# 使い方:
#   scripts/sync-repos.sh [-f <repos.tsv>] [-d <clone-dir>] [-n]
#
#   -f  マニフェストのパス（既定: ./repos.tsv）
#   -d  クローン先ディレクトリ（既定: ./.flywheel/repos）
#   -n  dry-run（clone/fetch せず、実行予定だけ表示）
#
# repos.tsv のフォーマット（素朴な行指向・空白/タブ区切り・# はコメント）:
#   # name        url                                  branch(任意, 既定 main)
#   billing-api   https://github.com/org/billing-api   main
#
# 注意:
#   - 秘密情報（認証）はマニフェストに書かない。git 認証は実行者の環境（SSH/credential helper）を使う。
#   - クローン実体は .gitignore 対象。エージェントrepo にコミットしない。
#   - 実行末尾で ~/.claude.json を読み取り、クローン先が Claude Code の trust 未承認
#     （projects["<絶対パス>"].hasTrustDialogAccepted != true）かどうかを検出し警告する
#     （run-cycle の headless 委譲が権限ブロックされる既知の落とし穴）。読み取り専用の検出のみ
#     で、~/.claude.json への書き込みは一切行わない（対応は人間の一度きりの手動作業）。

set -euo pipefail

MANIFEST="repos.tsv"
CLONE_DIR=".flywheel/repos"
DRY_RUN=0

while getopts "f:d:nh" opt; do
  case "$opt" in
    f) MANIFEST="$OPTARG" ;;
    d) CLONE_DIR="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    h) sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [-f repos.tsv] [-d clone-dir] [-n]" >&2; exit 2 ;;
  esac
done

if [ ! -f "$MANIFEST" ]; then
  echo "sync-repos: マニフェストが見つかりません: $MANIFEST" >&2
  exit 1
fi

mkdir -p "$CLONE_DIR"

synced=0
skipped=0
failed=0
# クローン先（trust 未承認チェック対象）を集める。行数分だけ増える素朴なリスト（改行区切り）。
all_dests=""

# --- trust 未承認クローンの検出（読み取り専用。~/.claude.json への書き込みは行わない） ---
#
# Claude Code は projects["<絶対パス>"].hasTrustDialogAccepted が true の場所でしか
# .claude/settings.json の permissions.allow を有効化しない。sync-repos が新規 clone
# した直後のクローンは常に未承認のため、run-cycle の headless 委譲がブロックされる
# （#27）。ここでは検出と警告のみ行い、修正（trust 承認）は人間の一度きりの手動作業に
# 委ねる（自己書き込みは禁止）。
#
# python3 があれば json モジュールで厳密に判定し、無ければ grep/sed によるヒューリス
# ティックへ degrade する。~/.claude.json が無い/読めない/解析不能な場合は「安全側」
# として検出そのものを静かにスキップする（set -e を壊さないよう、失敗しうるコマンド
# は必ず条件文の中で評価する）。

# 与えたパスが ~/.claude.json 上で trust 未承認かどうかを、grep/sed のヒューリスティッ
# クで判定する（python3 が使えない環境向けの degrade 経路）。
# 戻り値: 0=trust 承認済み, 1=未承認 or 判定不能（安全側で「未承認」扱い）
_trust_check_grep_fallback() {
  file="$1"
  path="$2"
  keyline=""
  if keyline="$(grep -nF "\"$path\"" "$file" 2>/dev/null | head -n1 | cut -d: -f1)"; then
    :
  fi
  if [ -z "${keyline:-}" ]; then
    return 1
  fi
  # このプロジェクトのオブジェクト範囲を、次に現れる「絶対パスキー」の行（＝次エントリの
  # 開始）の手前までに区切る。区切らずに固定行数だけ読むと、後続エントリの
  # hasTrustDialogAccepted:true を誤って自分のものとして拾ってしまう（false positive）。
  # このヒューリスティックは pretty-print（複数行）の JSON を前提とする。1行に圧縮された
  # JSON では境界を区切れず判定を誤りうるため、その場合は呼び出し側（report_untrusted_clones）
  # で丸ごとスキップする。
  total_lines="$(wc -l <"$file" 2>/dev/null || echo 0)"
  nextkeyline=""
  if nextkeyline="$(tail -n "+$((keyline + 1))" "$file" 2>/dev/null | grep -nE '^[[:space:]]*"/' | head -n1 | cut -d: -f1)"; then
    :
  fi
  if [ -n "${nextkeyline:-}" ]; then
    end=$((keyline + nextkeyline - 1))
  else
    # 末尾エントリ: 末尾改行が無いファイルだと wc -l が実際の行数を過小に数えることが
    # あるため、安全側に少し余裕を持たせる（sed は範囲外の行番号を指定しても単に無視する）。
    end=$((total_lines + 5))
  fi
  if [ -z "${end:-}" ] || [ "$end" -lt "$keyline" ]; then
    end="$keyline"
  fi
  window=""
  if window="$(sed -n "${keyline},${end}p" "$file" 2>/dev/null)"; then
    :
  fi
  if printf '%s\n' "$window" | grep -Eq '"hasTrustDialogAccepted"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
    return 0
  fi
  return 1
}

# 蓄積した clone dir のうち、実在するものだけを対象に trust 未承認を検出して警告する。
# 完全に読み取り専用。~/.claude.json への書き込みは一切行わない。
report_untrusted_clones() {
  claude_json="${HOME:-}/.claude.json"

  if [ -z "${HOME:-}" ] || [ ! -f "$claude_json" ] || [ ! -r "$claude_json" ]; then
    echo "sync-repos: ~/.claude.json が無い/読めないため trust チェックをスキップします" >&2
    return 0
  fi

  # 存在するクローンの絶対パスを集める（未 clone・失敗分は対象外）。
  abs_paths=""
  existing_dests="$(printf '%s' "$all_dests" | sed '/^$/d')"
  if [ -n "$existing_dests" ]; then
    while IFS= read -r d; do
      [ -d "$d/.git" ] || continue
      abs=""
      if abs="$(cd "$d" && pwd -P)"; then
        abs_paths="${abs_paths}${abs}
"
      fi
    done <<EOF
$existing_dests
EOF
  fi

  [ -n "$abs_paths" ] || return 0

  untrusted=""
  used_python=0
  if command -v python3 >/dev/null 2>&1; then
    used_python=1
    py_prog='
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(3)
projects = data.get("projects", {}) if isinstance(data, dict) else {}
for line in sys.stdin:
    p = line.rstrip("\n")
    if not p:
        continue
    info = projects.get(p)
    trusted = isinstance(info, dict) and info.get("hasTrustDialogAccepted") is True
    if not trusted:
        print(p)
'
    if untrusted="$(printf '%s' "$abs_paths" | python3 -c "$py_prog" "$claude_json" 2>/dev/null)"; then
      :
    else
      status=$?
      if [ "$status" -eq 3 ]; then
        # ~/.claude.json の解析に失敗（壊れている等）。安全側で検出をスキップ。
        echo "sync-repos: ~/.claude.json の解析に失敗したため trust チェックをスキップします（想定外の形式）" >&2
        return 0
      fi
      # python3 実行自体に失敗 → ヒューリスティックへ degrade
      used_python=0
      untrusted=""
    fi
  fi

  if [ "$used_python" -eq 0 ]; then
    # grep/sed ヒューリスティックは pretty-print（複数行）の JSON を前提とする。1行に
    # 圧縮された JSON だとエントリの境界を区切れず、他エントリの true を誤って拾って
    # 「trust 承認済み」と誤判定しうる（安全側と逆方向の false negative）。python3 が
    # 無い環境でこの形式に遭遇した場合は、誤判定より「静かにスキップ」を優先する。
    json_lines="$(wc -l <"$claude_json" 2>/dev/null || echo 0)"
    if [ "$json_lines" -le 1 ]; then
      echo "sync-repos: ~/.claude.json が 1 行に圧縮された形式のようで、python3 なしのヒューリスティックでは安全に判定できないため trust チェックをスキップします" >&2
      return 0
    fi
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      if ! _trust_check_grep_fallback "$claude_json" "$p"; then
        untrusted="${untrusted}${p}
"
      fi
    done <<EOF
$abs_paths
EOF
  fi

  untrusted="$(printf '%s' "$untrusted" | sed '/^$/d')"
  [ -n "$untrusted" ] || return 0

  echo "sync-repos: 以下のクローンは Claude Code の trust 未承認です（.claude/settings.json の permissions.allow が無効化され、headless 委譲がブロックされます）:" >&2
  printf '%s\n' "$untrusted" | while IFS= read -r p; do
    echo "  - $p" >&2
  done
  echo "sync-repos: 対応（人間の一度きりの手動作業。本スクリプトは ~/.claude.json を書き込みません）: \`scripts/trust-clone.sh <name>\`（<name> は上記パスのディレクトリ名）を実行して trust 承認してください。本スクリプトもエージェント自身が実行してはいけません（人間が一度だけ手動で実行）。対話的に \`claude\` を起動して trust ダイアログを承認しても構いません。" >&2
}

# 行指向で読む。# コメント行・空行はスキップ。列は空白/タブ区切り。
while IFS= read -r line || [ -n "$line" ]; do
  # コメント除去（行頭 # と 行中の # 以降）と前後空白の整理
  line="${line%%#*}"
  # 前後の空白をトリム
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue

  # 列を分割（空白/タブ区切り）。read は単語分割するが glob 展開はしないため、
  # url/branch に * ? [ 等が含まれてもファイル名に化けない。余分な列は _ に捨てる。
  read -r name url branch _ <<< "$line" || true
  branch="${branch:-main}"

  if [ -z "$name" ] || [ -z "$url" ]; then
    echo "sync-repos: 不正な行（name/url が必要）: $line" >&2
    failed=$((failed + 1))
    continue
  fi

  # name はクローン先ディレクトリ名（さらに memory map の参照キー）になる。
  # パス区切り / .. を含むと CLONE_DIR の外へ脱出しうるため弾く。
  case "$name" in
    */* | *..*)
      echo "sync-repos: 不正な name（/ や .. は使えません）: $name" >&2
      failed=$((failed + 1))
      continue
      ;;
  esac

  dest="$CLONE_DIR/$name"
  all_dests="${all_dests}${dest}
"

  if [ -d "$dest/.git" ]; then
    # 作業用クローン: ローカルのブランチ・編集・コミットを保持したまま安全に同期する。
    echo "sync-repos: fetch $name ($branch)"
    if [ "$DRY_RUN" -eq 0 ]; then
      if ! git -C "$dest" fetch --quiet origin "$branch" </dev/null; then
        echo "sync-repos: fetch 失敗: $name" >&2
        failed=$((failed + 1))
        continue
      fi
      cur="$(git -C "$dest" rev-parse --abbrev-ref HEAD </dev/null 2>/dev/null || echo '?')"
      dirty="$(git -C "$dest" status --porcelain </dev/null)"
      if [ -n "$dirty" ]; then
        echo "sync-repos: 変更あり（dirty）につき更新をスキップ: $name (branch=$cur)" >&2
        skipped=$((skipped + 1))
      elif [ "$cur" != "$branch" ]; then
        echo "sync-repos: 別ブランチ（${cur}）につき更新をスキップ: $name" >&2
        skipped=$((skipped + 1))
      elif git -C "$dest" -c advice.diverging=false merge --ff-only --quiet "origin/$branch" </dev/null; then
        synced=$((synced + 1))
      else
        echo "sync-repos: ff-only で前進できず更新をスキップ: ${name}（ローカル作業を保持）" >&2
        skipped=$((skipped + 1))
      fi
    fi
  else
    echo "sync-repos: clone $name ($branch) <- $url"
    if [ "$DRY_RUN" -eq 0 ]; then
      if git clone --quiet --branch "$branch" "$url" "$dest" </dev/null; then
        synced=$((synced + 1))
      else
        echo "sync-repos: clone 失敗: $name" >&2
        failed=$((failed + 1))
      fi
    fi
  fi
done < "$MANIFEST"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "sync-repos: dry-run 完了（上記が実行予定。clone/fetch は行っていません）"
else
  echo "sync-repos: 完了（更新 $synced 件 / スキップ $skipped 件 / 失敗 $failed 件）"
fi

report_untrusted_clones || true

[ "$failed" -eq 0 ]
