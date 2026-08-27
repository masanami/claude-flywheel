#!/usr/bin/env bash
#
# cycle-commit.sh — run-cycle 手順6 の「検算 → サイクルコミット → 事後補記の追加コミット」。
#
# 使い方:
#   scripts/cycle-commit.sh verify [共通オプション]
#   scripts/cycle-commit.sh commit [共通オプション] [--message <subject>]
#   scripts/cycle-commit.sh amend  [共通オプション]
#   scripts/cycle-commit.sh --list-exits | --list-subcommands
#
#   verify  当周（＋保留分）の成果物をフォーマット契約で検算するだけ。**保留する周**が呼ぶ
#   commit  検算に通ったうえで許可パスのみをステージ・コミットし、コミット内容を再検証する
#   amend   `cycle_end` 直前の事後補記（journal ⑤ への追記）を再検証し、その差分だけを
#           追加コミットする。`journal/index.jsonl` は対象にしない（1 周 1 行スキーマを崩さない）
#
# 共通オプション:
#   --workspace <dir>   エージェント repo のルート（既定: `.`）
#   --cycle <name>      当周のサイクル名（`YYYY-MM-DD-cycle[-N]`。必須）
#   --md <path>         検証する journal `.md`（workspace 相対。繰り返し可。
#                       既定: `journal/<cycle>.md`）。**保留分を束ねる周は
#                       noop-check.rb の `pending_md_file=` を全件渡す**。
#                       **ディレクトリ不可・`.md` 必須・`..` 不可・正本の範囲内**
#                       （形が違えば exit 2。理由は check_md_scope のコメント）
#   --tail <n>          `journal-index` の検証レコード数の**下限**。省略可——未コミットの
#                       レコード数はスクリプトが Git から算出し、渡された値より大きければ
#                       そちらを採る（安全側）。既定 1 へ黙って縮退すると、古い保留分の
#                       index レコードが未検証のままコミットされる
#   --expect-ids <ids>  アーカイブへ移動した課題 ID（カンマ区切り）。指定した周だけ
#                       `challenge-archive.md` を検証する（追記分の ID 一致＝移動漏れの不在まで）
#   --paths-file <p>    許可パスの正本（既定: 本スクリプトからの相対
#                       `../contracts/cycle-commit-paths.txt`。vendoring 用）
#   --validator <p>     バリデータのパス（既定: 同ディレクトリの `validate-artifact.rb`。テスト用）
#   --dry-run           検算だけ行い、ステージ・コミットを一切しない
#
# **許可パスの正本は 1 つ**（本スクリプトの要）:
#   ステージ／コミットの pathspec は `--paths-file` の `[commit]` セクションから導く。
#   これは `noop-check.rb` が「dirty パスの分類」に使うのと**同じファイル・同じ経路**であり、
#   分類と pathspec が別々のリストとして育たない。散文で「両者を同じ正本から導くこと」と
#   約束する代わりに、構造としてそうなっている（Issue #96 の P1 が再発しない形）。
#   正本が読めない・`[commit]` が空なら**コミットしない**（推測でパスを組み立てない＝fail-closed）。
#
# **正本の権威を呼び出し側が上書きできないこと**:
#   `--md` は「どの journal `.md` を検証するか」の指定であって、許可範囲の指定ではない。
#   正本の範囲外（`..`・絶対パス・`[commit]` の外）を渡されたら exit 2 で止める。
#   `amend` の pathspec も「正本の範囲内に限った `--md`」であり、正本そのもの（`CANON_PATHS`）は
#   どのサブコマンドでも書き換えない。
#
# **範囲外を履歴に入れない（3 層）**:
#   1. 正本のエントリに pathspec magic / 絶対パス / `..` があれば**コミットしない**（exit 1）。
#      `--literal-pathspecs` を渡すため magic は git に解釈されないが、それは「黙って何にも
#      マッチしない死んだエントリ」になることを意味する。静かに効かないより明示的に止める
#   2. **ステージ後・コミット前**に、この pathspec で実際にコミットへ入る集合を git に問い合わせ、
#      すべて正本のリテラル範囲内であることを確かめる（exit 1・**コミットは作らない**）
#   3. コミット後に `git diff-tree` で内容を読み直し、出所から証明する（最後の砦）
#   fail-closed の意味は「あとで気づく」ではなく「そもそも作らない」。層 2 が主で、
#   層 1 は原因を分かりやすくするため、層 3 は層 1・2 を素通りした場合の最終検出。
#
# **`git add` を先に行う理由**:
#   `git commit -- <pathspec>` は未追跡ファイルを自動でステージしない。当周新規作成した
#   `journal/YYYY-MM-DD-cycle.md` や即アーカイブによる `challenge-archive.md` への追記が
#   素通りしてサイクルコミットから漏れる。そこで `git add -- <許可パス>` で明示的にステージし、
#   続けて**同じ pathspec を付けた** `git commit -- <pathspec>` を打つ（pathspec 指定時は
#   `--only` 相当が既定となり、許可パス外がステージ済みでもコミットへ混入しない）。
#

# 出力（stdout・`key=value`。呼び出し側は `report=` をサイクルレポートへ転記する）:
#   committed=yes|no          **常に出力**。exit code から推測させない
#   commit_sha=<sha>          committed=yes のとき
#   verify=ok|violation|uncheckable|skipped
#   commit_path=<path>        pathspec に使った許可パス（正本の `[commit]` をそのまま）
#   tail=<n>                  `journal-index` の検証に実際に使ったレコード数（算出結果）
#   skipped_md=<path>         存在せず検証できなかった `--md`（黙って範囲から落とさない）
#   bundled_cycle=<name>      このコミットに入るサイクル名（2 件以上なら本文へ列挙）
#   violation=<行>            verify=violation のとき、バリデータ出力を 1 行ずつ
#   report=<1行>              サイクルレポートへ転記する文言
#
# 終了コード（priority-policy-resolve.sh / noop-check.rb の 3 値規約に倣う）:
#   - 0 = 要求した操作を完了（verify: 違反なし／commit・amend: コミット済み、または
#         変更が無く・dry-run でコミット不要だった）
#   - 1 = **契約違反によりコミットしていない**（fail-closed）。許可パス外の混入検出もここ
#   - 2 = 検査不能（バリデータが exit 2／**起動自体の失敗＝exit 126/127 等**／正本が読めない／
#         **Git 作業ツリーでない・トップでない**／`--md` が正本の範囲外）。
#         **検査不能はコミットを止めない**——`commit` はコミットを実行したうえで exit 2 を返す
#         （「検査不能」を「違反なし」と読み替えないが、ゲートが効かない環境で自走を止めない）。
#         ただし**正本が読めない場合だけはコミットしない**（pathspec を推測できないため）。
#         いずれの場合も `committed=` が実際に何が起きたかを示す。
#   本スクリプト自身の起動に失敗した場合（126/127）は stdout が空になり `report=` を取得
#   できない。呼び出し側は「起動できなかった事実と stderr」を自分でレポートへ書く（手順6）。

set -uo pipefail

SUBCOMMANDS="verify
commit
amend"

# 本スクリプト**自身**が返す終了コードの宣言（正本）。126/127 はシェルが返す値であり
# 本スクリプトの返り値ではないため含めない。
EXITS="0
1
2"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
USAGE="usage: $0 <verify|commit|amend> [--workspace <dir>] --cycle <name> [--md <path>]... [--tail <n>] [--expect-ids <ids>] [--paths-file <p>] [--validator <p>] [--message <subject>] [--dry-run]"

warn() { echo "cycle-commit: $1" >&2; }

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

SUBCMD=""
WORKSPACE="."
CYCLE=""
TAIL="1"
EXPECT_IDS=""
PATHS_FILE="${SELF_DIR}/../contracts/cycle-commit-paths.txt"
VALIDATOR="${SELF_DIR}/validate-artifact.rb"
MESSAGE=""
DRY_RUN=0
MD_LIST=""

case "${1:-}" in
  --list-exits)        printf '%s\n' "${EXITS}"; exit 0 ;;
  --list-subcommands)  printf '%s\n' "${SUBCOMMANDS}"; exit 0 ;;
  -h|--help)           echo "${USAGE}"; exit 0 ;;
  verify|commit|amend) SUBCMD="$1"; shift ;;
  "")                  warn "${USAGE}"; warn "サブコマンドがありません"; exit 2 ;;
  *)                   warn "${USAGE}"; warn "不明なサブコマンド: $1"; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)   [ $# -ge 2 ] || { warn "--workspace の値がありません"; exit 2; }; WORKSPACE="$2"; shift 2 ;;
    --cycle)       [ $# -ge 2 ] || { warn "--cycle の値がありません"; exit 2; }; CYCLE="$2"; shift 2 ;;
    --tail)        [ $# -ge 2 ] || { warn "--tail の値がありません"; exit 2; }; TAIL="$2"; shift 2 ;;
    --expect-ids)  [ $# -ge 2 ] || { warn "--expect-ids の値がありません"; exit 2; }; EXPECT_IDS="$2"; shift 2 ;;
    --paths-file)  [ $# -ge 2 ] || { warn "--paths-file の値がありません"; exit 2; }; PATHS_FILE="$2"; shift 2 ;;
    --validator)   [ $# -ge 2 ] || { warn "--validator の値がありません"; exit 2; }; VALIDATOR="$2"; shift 2 ;;
    --message)     [ $# -ge 2 ] || { warn "--message の値がありません"; exit 2; }; MESSAGE="$2"; shift 2 ;;
    --md)          [ $# -ge 2 ] || { warn "--md の値がありません"; exit 2; }
                   MD_LIST="${MD_LIST}$2
"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    *)             warn "${USAGE}"; warn "不明な引数: $1"; exit 2 ;;
  esac
done

[ -n "${CYCLE}" ]     || { warn "--cycle は必須です"; exit 2; }
[ -d "${WORKSPACE}" ] || { warn "ワークスペースがディレクトリではありません: ${WORKSPACE}"; exit 2; }

# 既定の検証対象 .md（当周分）
if [ -z "${MD_LIST}" ]; then
  MD_LIST="journal/${CYCLE}.md
"
fi

# ---------------------------------------------------------------------------
# 出力バッファ
# ---------------------------------------------------------------------------

COMMITTED="no"
COMMIT_SHA=""
VERIFY="skipped"
VIOLATIONS=""
COMMIT_PATHS=""
CANON_PATHS=""
DERIVED_TAIL=0
SKIPPED_MD=""
BUNDLED=""
REPORT=""

emit_and_exit() {
  echo "committed=${COMMITTED}"
  [ -n "${COMMIT_SHA}" ] && echo "commit_sha=${COMMIT_SHA}"
  echo "verify=${VERIFY}"
  echo "tail=${TAIL}"
  if [ -n "${COMMIT_PATHS}" ]; then
    printf '%s' "${COMMIT_PATHS}" | while IFS= read -r p; do
      [ -n "${p}" ] && echo "commit_path=${p}"
    done
  fi
  if [ -n "${BUNDLED}" ]; then
    printf '%s' "${BUNDLED}" | while IFS= read -r c; do
      [ -n "${c}" ] && echo "bundled_cycle=${c}"
    done
  fi
  if [ -n "${SKIPPED_MD}" ]; then
    printf '%s' "${SKIPPED_MD}" | while IFS= read -r m; do
      [ -n "${m}" ] && echo "skipped_md=${m}"
    done
  fi
  if [ -n "${VIOLATIONS}" ]; then
    printf '%s' "${VIOLATIONS}" | while IFS= read -r v; do
      [ -n "${v}" ] && echo "violation=${v}"
    done
  fi
  echo "report=${REPORT}"
  exit "$1"
}

# ---------------------------------------------------------------------------
# 許可パスの正本（noop-check.rb と同じファイル・同じ経路）
# ---------------------------------------------------------------------------

# has_pathspec_magic <path> — 正本のエントリとして受け付けない形か
# `--literal-pathspecs` を渡すため magic は git に解釈されないが、それは「黙って何にも
# マッチしない死んだエントリ」になることを意味する。静かに効かないより、明示的に止める。
has_pathspec_magic() {
  case "$1" in
    *'*'*|*'?'*|*'['*|*']'*|:*|/*|*'..'*) return 0 ;;
  esac
  return 1
}

load_commit_paths() {
  if [ ! -r "${PATHS_FILE}" ]; then
    return 1
  fi
  section=""
  out=""
  while IFS= read -r raw || [ -n "${raw}" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "${line}" ] && continue
    case "${line}" in
      \#*)          continue ;;
      "[commit]")   section="commit"; continue ;;
      "[exclude]")  section="exclude"; continue ;;
    esac
    [ "${section}" = "commit" ] || continue
    out="${out}${line}
"
  done < "${PATHS_FILE}"
  [ -n "${out}" ] || return 1
  COMMIT_PATHS="${out}"
  CANON_PATHS="${out}"   # 正本の範囲（以後どのサブコマンドでも書き換えない）
  return 0
}

# check_paths_magic — 正本のエントリに pathspec magic / 絶対パス / `..` が無いこと
check_paths_magic() {
  bad=""
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if has_pathspec_magic "${p}"; then bad="${bad}${p}
"; fi
  done <<EOF
${CANON_PATHS}
EOF
  [ -n "${bad}" ] || return 0
  while IFS= read -r b; do
    [ -n "${b}" ] && VIOLATIONS="${VIOLATIONS}paths-file: 許可パスの正本に pathspec magic / 絶対パス / .. を含むエントリがあります（ワークスペース相対のリテラルパスだけを書く）: ${b}
"
  done <<EOF
${bad}
EOF
  return 1
}

# in_canon_scope <path> — 正本の範囲（リテラル前置一致）に含まれるか
in_canon_scope() {
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    case "$1" in
      "${p}"|"${p}"/*) return 0 ;;
    esac
  done <<EOF
${CANON_PATHS}
EOF
  return 1
}

# check_md_scope — `--md` が「正本の範囲内にある journal の `.md` ファイル」であること。
# 呼び出し側の入力が正本の権威に割り込めないようにする（amend が COMMIT_PATHS を
# MD_LIST で置き換える経路が、正本外のファイルをコミットしうる穴だった）。
#
# **範囲だけでなく「引数の形」も縛る理由**: 正本の範囲検査は前置一致なので、
# 正本のエントリ `journal` に対して `--md journal`（ディレクトリそのもの）が
# 完全一致で通る。amend はそれを pathspec に使うため、**journal 配下がまるごと
# コミット対象**になり「amend は `journal/index.jsonl` を対象にしない」という
# 不変条件が壊れる。
#
# 形の制約は**パスの列挙ではない**ので、正本と同期が必要な第 2 のリストにはならない
# （正本に行を足しても、この関数は書き換えなくてよい）:
#   - ディレクトリでないこと（`--md journal` を弾く）
#   - `.md` で終わること（`--md journal/index.jsonl` を弾く）
#   - ワークスペース相対で `..` を含まないこと
#   - 正本の `[commit]` 範囲内にあること
#
# 拡張子で弾くのは**バリデータ任せにできない**ため。`journal/notes.txt` のように
# 内容が journal-md 契約を満たしていればバリデータは通してしまい、
# 「たまたま落ちていただけ」の検査になる。
check_md_scope() {
  bad=""
  while IFS= read -r md; do
    [ -n "${md}" ] || continue
    case "${md}" in
      /*|*'..'*) bad="${bad}${md}
"; continue ;;
    esac
    case "${md}" in
      *.md) ;;
      *) bad="${bad}${md}
"; continue ;;
    esac
    if [ -d "${WORKSPACE}/${md}" ]; then
      bad="${bad}${md}
"; continue
    fi
    in_canon_scope "${md}" || bad="${bad}${md}
"
  done <<EOF
${MD_LIST}
EOF
  [ -n "${bad}" ] || return 0
  while IFS= read -r b; do
    [ -n "${b}" ] && VIOLATIONS="${VIOLATIONS}md-scope: --md は許可パスの正本の範囲内にある .md ファイル（ワークスペース相対・ディレクトリ不可）でなければなりません: ${b}
"
  done <<EOF
${bad}
EOF
  return 1
}

# derive_tail — 未コミットの index レコード数を git から算出する。
# 呼び出し側が pending_index_lines を渡せない周に既定 1 へ黙って縮退すると、
# 古い保留分の index レコードが**未検証のまま**コミットされる（範囲除外型の検算は
# 空虚に真になる）。算出できるものは自分で算出する。
derive_tail() {
  idx="journal/index.jsonl"
  [ -f "${WORKSPACE}/${idx}" ] || { DERIVED_TAIL=0; return 0; }
  cur="$(grep -c . "${WORKSPACE}/${idx}" 2>/dev/null)"
  [ -n "${cur}" ] || cur=0
  if git_plain cat-file -e "HEAD:${idx}" >/dev/null 2>&1; then
    old="$(git_plain show "HEAD:${idx}" 2>/dev/null | grep -c . )"
    [ -n "${old}" ] || old=0
  else
    old=0   # 未追跡／HEAD に無い＝全レコードが未コミット
  fi
  d=$((cur - old))
  [ "${d}" -ge 0 ] || d=0
  DERIVED_TAIL="${d}"
  return 0
}

# ---------------------------------------------------------------------------
# バリデータ呼び出し
# ---------------------------------------------------------------------------

# 検算の集約結果。0=違反なし / 1=違反あり / 2=検査不能（1 件でも違反があれば違反が勝つ）
VERIFY_RC=0

# note_rc <rc> — バリデータ 1 回分の exit を集約する。
#   0/1/2 以外（126/127 等＝起動自体の失敗）は 2（検査不能）と同じに扱う。
note_rc() {
  case "$1" in
    0) ;;
    1) VERIFY_RC=1 ;;
    *) [ "${VERIFY_RC}" -eq 1 ] || VERIFY_RC=2 ;;
  esac
}

# run_validator <type> <file> [extra args...]
run_validator() {
  vtype="$1"; vfile="$2"; shift 2
  vout="$("${VALIDATOR}" "${vtype}" "${vfile}" "$@" 2>&1)"
  vrc=$?
  if [ "${vrc}" -ne 0 ] && [ -n "${vout}" ]; then
    while IFS= read -r vl; do
      [ -n "${vl}" ] && VIOLATIONS="${VIOLATIONS}${vtype}: ${vl}
"
    done <<EOF
${vout}
EOF
  fi
  note_rc "${vrc}"
}

# verify_artifacts <mode> — mode=full（当周の全成果物）/ md-only（事後補記の再検証）
verify_artifacts() {
  mode="$1"

  # journal .md（保留分を束ねる周は複数）。
  # 存在しない .md は拒否しない（--dry-run 周は journal を書き出さないため）が、
  # **黙って検証範囲から落とさない**——範囲除外型の検算は空虚に真になるので、
  # 検証できなかった対象は skipped_md= として可視化する。
  while IFS= read -r md; do
    [ -n "${md}" ] || continue
    if [ ! -f "${WORKSPACE}/${md}" ]; then
      SKIPPED_MD="${SKIPPED_MD}${md}
"
      continue
    fi
    run_validator journal-md "${WORKSPACE}/${md}"
  done <<EOF
${MD_LIST}
EOF

  [ "${mode}" = "full" ] || return 0

  # 台帳（現在状態＝修復が正規運用のため全体検証）
  if [ -f "${WORKSPACE}/challenge-ledger.md" ]; then
    run_validator ledger "${WORKSPACE}/challenge-ledger.md"
  fi

  # アーカイブ（履歴＝過去エントリを修復対象にしないため、移動があった周だけ追記分を検証。
  # --expect-ids で追記エントリの ID 一致＝移動漏れの不在まで証明する）
  if [ -n "${EXPECT_IDS}" ] && [ -f "${WORKSPACE}/challenge-archive.md" ]; then
    run_validator archive "${WORKSPACE}/challenge-archive.md" --expect-ids "${EXPECT_IDS}"
  fi

  # journal/index.jsonl（当周の append 分のみ。保留分を束ねる周は --tail を広げる）
  if [ -f "${WORKSPACE}/journal/index.jsonl" ]; then
    run_validator journal-index "${WORKSPACE}/journal/index.jsonl" \
      --tail "${TAIL}" --expect-cycle "${CYCLE}"
  fi
}

# ---------------------------------------------------------------------------
# Git 操作
# ---------------------------------------------------------------------------

# git_ws <args...>
# 正本のエントリは**常にリテラル**として渡す。pathspec magic（`*` 等）を git に解釈させると、
# 正本のリテラル照合より広い集合が選ばれ、範囲外がコミットに入りうる。
git_ws() { git -C "${WORKSPACE}" --literal-pathspecs "$@"; }
# 検査用（pathspec を伴わない読み取り）。--literal-pathspecs の有無で挙動は変わらないが
# 意図を分けておく。
git_plain() { git -C "${WORKSPACE}" "$@"; }

# stage_allowed — 許可パスのみを明示的にステージする（未追跡も拾う）
stage_allowed() {
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    git_ws add -A -- "${p}" >/dev/null 2>&1
  done <<EOF
${COMMIT_PATHS}
EOF
}

# staged_in_scope — 許可パス内にステージ済みの変更があるか（空コミットを作らないため）
staged_in_scope() {
  n=0
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if [ -n "$(git_ws diff --cached --name-only -- "${p}" 2>/dev/null)" ]; then
      n=1; break
    fi
  done <<EOF
${COMMIT_PATHS}
EOF
  [ "${n}" -eq 1 ]
}

# check_staged_scope — **コミット前に**、この pathspec で実際にコミットへ入る集合を
# git に問い合わせ、すべて正本のリテラル範囲内であることを確かめる。
# コミット後の検証（verify_commit_contents）だけでは、範囲外がいったん履歴に入ってしまう。
# fail-closed の意味は「あとで気づく」ではなく「そもそも作らない」。
check_staged_scope() {
  set --
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    set -- "$@" "${p}"
  done <<EOF
${COMMIT_PATHS}
EOF
  files="$(git_ws diff --cached --name-only -- "$@" 2>/dev/null)"
  [ -n "${files}" ] || return 0
  bad=""
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    in_canon_scope "${f}" || bad="${bad}${f}
"
  done <<EOF
${files}
EOF
  [ -n "${bad}" ] || return 0
  while IFS= read -r b; do
    [ -n "${b}" ] && VIOLATIONS="${VIOLATIONS}staged-scope: コミットに入る集合に許可パス外が含まれています（コミットは行いません）: ${b}
"
  done <<EOF
${bad}
EOF
  return 1
}

# build_message — コミットメッセージを組み立てる。束ねたサイクルが 2 件以上なら本文へ列挙する
build_message() {
  subject="${MESSAGE}"
  [ -n "${subject}" ] || subject="chore(cycle): ${CYCLE}"
  printf '%s\n' "${subject}"
  n_bundled="$(printf '%s' "${BUNDLED}" | grep -c . 2>/dev/null || true)"
  if [ "${n_bundled:-0}" -ge 2 ]; then
    joined=""
    while IFS= read -r bc; do
      [ -n "${bc}" ] || continue
      if [ -z "${joined}" ]; then joined="${bc}"; else joined="${joined}, ${bc}"; fi
    done <<EOF
${BUNDLED}
EOF
    printf '\ncycles: %s\n' "${joined}"
  fi
}

# commit_allowed — 許可パスを明示した pathspec でコミットし、SHA を控える
commit_allowed() {
  set --
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    set -- "$@" "${p}"
  done <<EOF
${COMMIT_PATHS}
EOF
  msgfile="$(mktemp)"
  build_message > "${msgfile}"
  git_ws commit -q -F "${msgfile}" -- "$@" >/dev/null 2>&1
  rc=$?
  rm -f "${msgfile}"
  [ "${rc}" -eq 0 ] || return 1
  COMMIT_SHA="$(git_ws rev-parse HEAD 2>/dev/null)"
  [ -n "${COMMIT_SHA}" ] || return 1
  return 0
}

# verify_commit_contents — コミット内容を読み直し、許可パス外が含まれていないことを証明する。
# 「ステージしていないから入らないはず」で終わらせず、出所（実際のコミット）で確かめる。
verify_commit_contents() {
  files="$(git_ws diff-tree --no-commit-id --name-only -r "${COMMIT_SHA}" 2>/dev/null)"
  [ -n "${files}" ] || return 0
  bad=""
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    ok=0
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      case "${f}" in
        "${p}"|"${p}"/*) ok=1; break ;;
      esac
    done <<EOF
${COMMIT_PATHS}
EOF
    [ "${ok}" -eq 1 ] || bad="${bad}${f}
"
  done <<EOF
${files}
EOF
  if [ -n "${bad}" ]; then
    while IFS= read -r b; do
      [ -n "${b}" ] && VIOLATIONS="${VIOLATIONS}commit-scope: 許可パス外がコミットに含まれています: ${b}
"
    done <<EOF
${bad}
EOF
    return 1
  fi
  return 0
}

# collect_bundled — このコミットに入るサイクル名（--md の basename）を集める
collect_bundled() {
  seen=""
  while IFS= read -r md; do
    [ -n "${md}" ] || continue
    base="${md##*/}"; base="${base%.md}"
    case "
${seen}" in
      *"
${base}
"*) continue ;;
    esac
    seen="${seen}${base}
"
  done <<EOF
${MD_LIST}
EOF
  BUNDLED="$(printf '%s' "${seen}" | grep . | sort)
"
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

collect_bundled

# **Git 作業ツリーであること**を先に確かめる（noop-check.rb と同じ規律）。
# 非 Git だと git add は黙って失敗し git diff は空を返すため、そのまま進むと
# 「変更なし・正常（exit 0）」に化ける——検査不能を正常と読み替えない。
top="$(git_plain rev-parse --show-toplevel 2>/dev/null)"
if [ $? -ne 0 ] || [ -z "${top}" ]; then
  VERIFY="uncheckable"
  REPORT="サイクルコミット: 実施せず（Git 作業ツリーではありません: ${WORKSPACE}）"
  warn "Git 作業ツリーではありません: ${WORKSPACE}"
  emit_and_exit 2
fi
# パスはワークスペース相対で解決するため、トップ以外だと分類がずれる
ws_abs="$(cd "${WORKSPACE}" 2>/dev/null && pwd -P)"
top_abs="$(cd "${top}" 2>/dev/null && pwd -P)"
if [ "${ws_abs}" != "${top_abs}" ]; then
  VERIFY="uncheckable"
  REPORT="サイクルコミット: 実施せず（--workspace が Git 作業ツリーのトップではありません。トップ: ${top_abs}）"
  warn "--workspace が Git 作業ツリーのトップではありません（トップ: ${top_abs}）: ${WORKSPACE}"
  emit_and_exit 2
fi

if ! load_commit_paths; then
  VERIFY="uncheckable"
  REPORT="サイクルコミット: 実施せず（許可パスの正本を読めないか [commit] が空のため。正本: ${PATHS_FILE}）"
  warn "許可パスの正本を読めないか [commit] が空です: ${PATHS_FILE}"
  emit_and_exit 2
fi

# 正本のエントリが pathspec magic / 絶対パス / .. を含まないこと（**コミットしない**）
if ! check_paths_magic; then
  VERIFY="violation"
  REPORT="サイクルコミット: 実施せず（許可パスの正本に pathspec magic 等があり、リテラル範囲より広く解釈されうるため）"
  warn "許可パスの正本に pathspec magic / 絶対パス / .. を含むエントリがあります: ${PATHS_FILE}"
  emit_and_exit 1
fi

# `--md` が正本の範囲内であること（呼び出し側の入力が正本の権威に割り込めないようにする）
if ! check_md_scope; then
  VERIFY="uncheckable"
  REPORT="サイクルコミット: 実施せず（--md が許可パスの正本の範囲外です）"
  warn "--md が許可パスの正本の範囲外です"
  emit_and_exit 2
fi

# 検証レコード数は自分で算出し、渡された値より大きければそちらを採る（安全側）
derive_tail
if [ "${DERIVED_TAIL}" -gt "${TAIL}" ]; then
  TAIL="${DERIVED_TAIL}"
fi

case "${SUBCMD}" in
  verify)   verify_artifacts full ;;
  commit)   verify_artifacts full ;;
  amend)    verify_artifacts md-only ;;
esac

case "${VERIFY_RC}" in
  0) VERIFY="ok" ;;
  1) VERIFY="violation" ;;
  2) VERIFY="uncheckable" ;;
esac

# 違反は fail-closed: コミットしない
if [ "${VERIFY_RC}" -eq 1 ]; then
  REPORT="サイクルコミット: 実施せず（フォーマット契約の違反を検出。違反箇所を修正してから再実行する）"
  emit_and_exit 1
fi

# verify サブコマンドはここまで（保留する周が使う）
if [ "${SUBCMD}" = "verify" ]; then
  if [ "${VERIFY_RC}" -eq 2 ]; then
    REPORT="検算: 検査不能（バリデータを実行できませんでした。理由は stderr）"
    emit_and_exit 2
  fi
  REPORT="検算: 違反なし（コミットは行っていません）"
  emit_and_exit 0
fi

# dry-run はここまで（書き込まない）
if [ "${DRY_RUN}" -eq 1 ]; then
  REPORT="サイクルコミット: dry-run のため実施せず（検算のみ）"
  [ "${VERIFY_RC}" -eq 2 ] && emit_and_exit 2
  emit_and_exit 0
fi

# amend は journal .md の追記だけを対象にする（index.jsonl は 1 周 1 行スキーマを崩さない）
if [ "${SUBCMD}" = "amend" ]; then
  # **正本（CANON_PATHS）は書き換えない**。amend の pathspec は「正本の範囲内に限った
  # MD_LIST」であり、MD_LIST 自体は上で check_md_scope を通っている。
  COMMIT_PATHS="$(printf '%s' "${MD_LIST}" | grep . )
"
  [ -n "${MESSAGE}" ] || MESSAGE="chore(cycle): ${CYCLE} の事後補記"
fi

stage_allowed

if ! staged_in_scope; then
  REPORT="サイクルコミット: 実施せず（許可パスに変更がありません）"
  [ "${VERIFY_RC}" -eq 2 ] && emit_and_exit 2
  emit_and_exit 0
fi

if ! check_staged_scope; then
  VERIFY="violation"
  REPORT="サイクルコミット: 実施せず（コミットに入る集合に許可パス外が含まれています。正本かステージ内容を確認する）"
  warn "コミットに入る集合に許可パス外が含まれています"
  emit_and_exit 1
fi

if ! commit_allowed; then
  VIOLATIONS="${VIOLATIONS}commit: git commit に失敗しました
"
  REPORT="サイクルコミット: 失敗（git commit が非 0。stderr を確認する）"
  warn "git commit に失敗しました"
  emit_and_exit 1
fi

if ! verify_commit_contents; then
  COMMITTED="yes"
  REPORT="サイクルコミット: ${COMMIT_SHA}（**許可パス外がコミットに含まれています**。直ちに人間へ報告する）"
  warn "許可パス外がコミットに含まれています: ${COMMIT_SHA}"
  emit_and_exit 1
fi

COMMITTED="yes"
if [ "${VERIFY_RC}" -eq 2 ]; then
  REPORT="サイクルコミット: ${COMMIT_SHA}（検算は検査不能。理由は stderr。「検査不能」を「違反なし」と読み替えない）"
  emit_and_exit 2
fi
REPORT="サイクルコミット: ${COMMIT_SHA}"
emit_and_exit 0
