#!/usr/bin/env bash
#
# sync-repos.sh — 関連リポジトリ（参照用クローン）を repos.tsv に従って同期する。
#
# マニフェスト（repos.tsv, Git 追跡）と クローン実体（.flywheel/repos/, .gitignore）を分離し、
# 純シェルで冪等に clone / pull する（yq 等の依存なし）。参照用クローンは読み取り中心。
#
# 使い方:
#   scripts/sync-repos.sh [-f <repos.tsv>] [-d <clone-dir>] [-n]
#
#   -f  マニフェストのパス（既定: ./repos.tsv）
#   -d  クローン先ディレクトリ（既定: ./.flywheel/repos）
#   -n  dry-run（clone/pull せず、実行予定だけ表示）
#
# repos.tsv のフォーマット（素朴な行指向・空白/タブ区切り・# はコメント）:
#   # name        url                                  branch(任意, 既定 main)
#   billing-api   https://github.com/org/billing-api   main
#
# 注意:
#   - 秘密情報（認証）はマニフェストに書かない。git 認証は実行者の環境（SSH/credential helper）を使う。
#   - クローン実体は .gitignore 対象。エージェントrepo にコミットしない。

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
failed=0

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

  dest="$CLONE_DIR/$name"

  if [ -d "$dest/.git" ]; then
    echo "sync-repos: pull  $name ($branch)"
    if [ "$DRY_RUN" -eq 0 ]; then
      if git -C "$dest" fetch --quiet origin "$branch" </dev/null \
         && git -C "$dest" checkout --quiet "$branch" </dev/null \
         && git -C "$dest" merge --ff-only --quiet "origin/$branch" </dev/null; then
        synced=$((synced + 1))
      else
        echo "sync-repos: pull 失敗: $name" >&2
        failed=$((failed + 1))
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

echo "sync-repos: 完了（同期 $synced 件 / 失敗 $failed 件）"
[ "$failed" -eq 0 ]
