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
[ "$failed" -eq 0 ]
