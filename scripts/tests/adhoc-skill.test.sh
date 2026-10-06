#!/usr/bin/env bash
#
# adhoc-skill.test.sh — 差し込み作業スキル（skills/adhoc/SKILL.md）の構造不変条件テスト。
#
# 実行: bash scripts/tests/adhoc-skill.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk。テストフレームワーク不使用。
#   - 読み取り専用。
#
# 散文の SKILL.md には型検査もコンパイラも効かず、「文言が在るか」だけを見るテストは、
# 規定が骨抜きになっても緑のままになる。ここで固定するのは次の 4 つの構造:
#
#   1. **正本が 1 箇所**: 記録規律の運用詳細はスキル側にだけ在り、templates/CLAUDE.md へ
#      再掲されていない（否定検査）。**同じ検出語彙をスキル側では在ることの検査に使う**
#      ——両方向に掛けることで、パターンが壊れて否定検査が空虚に真になる形を潰す。
#   2. **書き込み範囲の完全性（語彙駆動）**: run-cycle がコミットするパス集合の正本
#      contracts/cycle-commit-paths.txt の [commit] に載るパスは、**全件**がスキルの
#      「読み取りだけ」側に列挙されている。正本へパスを足したのにスキルが追従しなければ
#      ここで落ちる（2 つのリストを手で同期させない）。例外は受け箱 `handoff` だけで、
#      無条件の表に「新規作成だけ」として載る（既存ファイルは読み取りだけ。Issue #191）。
#   3. **代替手段が用意されている**: 「書くな」だけの行を作らない。代替手段の表の各行に
#      行き先（書かず〜／取得しない〜）が書かれていること。禁止だけでは守られない。
#   4. **停止条件の明文化**: 未終了 adhoc_start の扱い 3 点が在る。
#   5. **代行編集の枠が閉じている**（Issue #181）: 人間の明示指示で書いてよい例外は
#      【代行編集】表の行だけで、ロック取得を条件とする行の対象は challenge-ledger.md と
#      priority-policy.md の 2 つちょうど。[commit] の他のパス（journal・memory 等）が
#      例外側へ漏れたら落ちる（語彙駆動）。条件は「確認」ではなく「取得」、解放は取得成功時だけ。
#
# **走査対象・抽出結果が空のまま pass しない**ことを各所で確認する（空リストは全称条件を
# 空虚に真にする）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

SKILL="skills/adhoc/SKILL.md"
CLAUDE_TPL="templates/CLAUDE.md"
COMMIT_PATHS="contracts/cycle-commit-paths.txt"

PASS=0
FAIL=0
FAILED=()

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED+=("$1")
  echo "FAIL - $1"
  [ $# -ge 2 ] && echo "       $2"
  return 0
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=$2 actual=$3"; fi
}

echo "=== (A) 対象ファイルが実在する（0 件の「違反なし」を pass にしない） ==="

for f in "$SKILL" "$CLAUDE_TPL" "$COMMIT_PATHS"; do
  if [ -r "$f" ]; then pass "(A) 読める: ${f}"; else fail "(A) 読める: ${f}" "見つからない"; fi
done

# 以降の検査は 3 ファイルが読めることが前提。読めないなら空虚に真にせずここで落とす。
if [ ! -r "$SKILL" ] || [ ! -r "$CLAUDE_TPL" ] || [ ! -r "$COMMIT_PATHS" ]; then
  echo ""
  echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
  exit 1
fi

echo ""
echo "=== (B) 記録規律の正本はスキル 1 箇所（CLAUDE.md へ再掲しない） ==="

# 「運用詳細」を表す語彙。**同じ語彙を両方向に掛ける**:
#   スキル側に在る（検出器が生きている） ∧ CLAUDE.md 側に無い（正本が 1 箇所）
# 片側だけを見ると、パターンの打ち間違いで否定検査が黙って通る。
DETAIL_TOKENS=(
  'log-run-event.sh'
  'dangling_start'
  'adhoc-YYYYMMDD'
  '--result'
  '代筆'
  'cycle-lock.sh'
)
for tok in "${DETAIL_TOKENS[@]}"; do
  if grep -qF -- "$tok" "$SKILL"; then
    pass "(B) 運用詳細がスキル側に在る: ${tok}"
  else
    fail "(B) 運用詳細がスキル側に在る: ${tok}" "${SKILL} に無い（検出語彙が実態とずれている）"
  fi
  if grep -qF -- "$tok" "$CLAUDE_TPL"; then
    fail "(B) 運用詳細が CLAUDE.md に無い: ${tok}" "${CLAUDE_TPL} に再掲されている（正本の二重化）"
  else
    pass "(B) 運用詳細が CLAUDE.md に無い: ${tok}"
  fi
done

# 正本の所在（スキル名）が CLAUDE.md から張られている。詳細を落としたうえで所在も無いと、
# 規定ごと消えたのと同じになる。
if grep -qF -- '/claude-flywheel:adhoc' "$CLAUDE_TPL"; then
  pass "(B) CLAUDE.md が正本の所在（スキル名）を名指ししている"
else
  fail "(B) CLAUDE.md が正本の所在（スキル名）を名指ししている" "/claude-flywheel:adhoc が無い"
fi

# 旧規定（台帳起票と adhoc_start の二者択一）が残っていないこと。並走中の台帳書き込みを
# 許す読み方が復活すると、run-cycle と競合する。
if grep -qF -- '着手前に台帳起票または' "$CLAUDE_TPL"; then
  fail "(B) 旧規定「台帳起票または adhoc_start」が残っていない" "見つかった"
else
  pass "(B) 旧規定「台帳起票または adhoc_start」が残っていない"
fi

echo ""
echo "=== (C) 記録の対（adhoc_start / adhoc_end）が両方在る ==="

for ev in adhoc_start adhoc_end; do
  n="$(grep -cF -- "log-run-event.sh\" ${ev}" "$SKILL")"
  n="$(printf '%s' "$n" | tr -d ' ')"
  if [ "$n" -ge 1 ]; then
    pass "(C) ${ev} の記録コマンドが在る"
  else
    fail "(C) ${ev} の記録コマンドが在る" "log-run-event.sh の呼び出しが見つからない"
  fi
done

echo ""
echo "=== (D) 書き込み範囲の完全性（run-cycle のコミット対象は全件が読み取り専用側） ==="

# 正本は contracts/cycle-commit-paths.txt の [commit] セクション 1 本。ここで表を持たない。
commit_paths="$(awk '/^\[commit\]$/{f=1;next} /^\[/{f=0} f && $0 !~ /^#/ && NF {print $0}' "$COMMIT_PATHS")"
n_paths="$(printf '%s\n' "$commit_paths" | grep -c . )"
n_paths="$(printf '%s' "$n_paths" | tr -d ' ')"
assert_eq "(D) [commit] のパスを 1 件以上抽出できた" "true" \
  "$(if [ "$n_paths" -ge 1 ]; then echo true; else echo false; fi)"

# スキルの「読み取りだけ」の行を 1 行だけ取り出す。行が見つからなければ以降は空虚に真に
# なるため、行の存在自体を検査する。
readonly_line="$(grep -F '**読み取りだけ（書かない）**' "$SKILL" | head -1)"
if [ -n "$readonly_line" ]; then
  pass "(D) スキルに「読み取りだけ」の列挙行が在る"
else
  fail "(D) スキルに「読み取りだけ」の列挙行が在る" "見つからない"
fi

if [ -n "$readonly_line" ] && [ "$n_paths" -ge 1 ]; then
  missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$readonly_line" in
      *"$p"*) ;;
      *) missing="${missing} ${p}" ;;
    esac
  done <<EOF
$commit_paths
EOF
  if [ -z "$missing" ]; then
    pass "(D) [commit] のパス ${n_paths} 件がすべて「読み取りだけ」に列挙されている"
  else
    fail "(D) [commit] のパス ${n_paths} 件がすべて「読み取りだけ」に列挙されている" "欠落:${missing}"
  fi

  # 検出器の自己検査: 正本に無いパスは「列挙されている」と判定されないこと。
  case "$readonly_line" in
    *'never-a-cycle-state-file'*) fail "(D) 検出器の自己検査（偽陽性が出ない）" "在るはずのない語にマッチした" ;;
    *) pass "(D) 検出器の自己検査（偽陽性が出ない）" ;;
  esac
fi

# 例外は受け箱 handoff だけ（Issue #191）: adhoc が無条件に書いてよい表のうち、[commit] の
# パスに当たる行は「新規作成だけ」の行で、その対象は handoff ちょうど 1 つ。既存ファイルは
# 「読み取りだけ」側に残る（上の全件検査が handoff も要求する）。journal・memory 等が
# 「新規作成だけ」の名目で無条件の表へ漏れたら落ちる。
uncond_rows() {
  awk '
    /\*\*無条件に書き込んでよいのは/ {f=1; next}
    f && $0 !~ /^\|/ && NF==0 {next}
    f && $0 !~ /^\|/ {f=0}
    f && $0 ~ /^\|/ {
      if ($0 ~ /^\| *---/) next
      if ($0 ~ /^\| *対象 *\|/) next
      print $0
    }
  ' "$1"
}
# 無条件の表のうち、1 列目に [commit] のパスを含む行の、そのパスを 1 行 1 件で返す。
uncond_commit_targets() {
  first="$(uncond_rows "$1" | awk -F'|' '{print $2}')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$first" in *"\`$p"*) printf '%s\n' "$p" ;; esac
  done <<EOF
$commit_paths
EOF
}
n_urows="$(uncond_rows "$SKILL" | grep -c .)"
n_urows="$(printf '%s' "$n_urows" | tr -d ' ')"
assert_eq "(D) 無条件に書いてよい表から本文行を 1 行以上抽出できた" "true" \
  "$(if [ "$n_urows" -ge 1 ]; then echo true; else echo false; fi)"
assert_eq "(D) 無条件の表に載る [commit] のパスは handoff ちょうど 1 つ" "handoff" \
  "$(uncond_commit_targets "$SKILL")"
handoff_row="$(uncond_rows "$SKILL" | grep -F '`handoff/')"
if printf '%s' "$handoff_row" | grep -qF '**新規作成だけ**'; then
  pass "(D) 受け箱の行は「新規作成だけ」に限っている"
else
  fail "(D) 受け箱の行は「新規作成だけ」に限っている" "行: ${handoff_row}"
fi
# 検出器の自己検査: journal/ の行を無条件の表へ足した変異は、対象が 2 つになって検出される。
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/adhoc-skill-test.XXXXXX")"
awk '{print} /^\| `handoff\/<手順2 で発番した id>.md`/ {print "| `journal/<id>.md` | 変異 |"}' "$SKILL" > "$tmpd/mutant.md"
if [ "$(uncond_commit_targets "$tmpd/mutant.md" | grep -c .)" -eq 2 ]; then
  pass "(D) 検出器の自己検査（無条件の表への漏れを検出する）"
else
  fail "(D) 検出器の自己検査（無条件の表への漏れを検出する）" "変異版の抽出が 2 件にならない"
fi
rm -rf "$tmpd"

echo ""
echo "=== (E) 代替手段が用意されている（禁止だけの行を作らない） ==="

# 「書きたくなったときの代替手段」表の本文行を取り出す（見出し行・区切り行は除く）。
alt_rows="$(awk '
  /書きたくなったときの代替手段/ {f=1; next}
  f && $0 !~ /^\|/ && NF==0 {next}
  f && $0 !~ /^\|/ {f=0}
  f && $0 ~ /^\|/ {
    if ($0 ~ /^\| *---/) next
    if ($0 ~ /書きたくなった対象/) next
    print $0
  }
' "$SKILL")"
n_rows="$(printf '%s\n' "$alt_rows" | grep -c .)"
n_rows="$(printf '%s' "$n_rows" | tr -d ' ')"
assert_eq "(E) 代替手段の表から本文行を 1 行以上抽出できた" "true" \
  "$(if [ "$n_rows" -ge 1 ]; then echo true; else echo false; fi)"

if [ "$n_rows" -ge 1 ]; then
  bare=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # 行き先（何をするか）が書かれていない行＝禁止だけの行。
    if printf '%s' "$row" | grep -qE '書かず|取得しない|報告に出す'; then
      continue
    fi
    bare=$((bare + 1))
    echo "     禁止だけの行: ${row}"
  done <<EOF
$alt_rows
EOF
  assert_eq "(E) 代替手段の表に「禁止だけの行」が無い（${n_rows} 行）" "0" "$bare"
fi

echo ""
echo "=== (F) 未終了 adhoc_start の停止条件が明文化されている ==="

STOP_PHRASES=(
  '**誰も代筆しない**'
  '同じ `id` で継続する'
  '未記録である事実と `id` を手順5 の報告に明記する'
)
for ph in "${STOP_PHRASES[@]}"; do
  if grep -qF -- "$ph" "$SKILL"; then
    pass "(F) 停止条件が在る: ${ph}"
  else
    fail "(F) 停止条件が在る: ${ph}" "見つからない"
  fi
done

echo ""
echo "=== (G) 代行編集の枠（人間の明示指示 ∧ ロック取得）が閉じている ==="

# 【代行編集】表の本文行（見出し行・区切り行を除く）を取り出す。
delegate_rows() {
  awk '
    /\*\*【代行編集】/ {f=1; next}
    f && $0 !~ /^\|/ && NF==0 {next}
    f && $0 !~ /^\|/ {f=0}
    f && $0 ~ /^\|/ {
      if ($0 ~ /^\| *---/) next
      if ($0 ~ /^\| *対象 *\|/) next
      print $0
    }
  ' "$1"
}
# ロック取得を条件とする行の対象（1 列目のバッククォート内）を 1 行 1 件で返す。
locked_targets() {
  delegate_rows "$1" | grep -F 'ロック取得' | awk -F'|' '{print $2}' \
    | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p' | sort
}
# 表の 1 列目（対象）だけを返す。
delegate_first_cells() {
  delegate_rows "$1" | awk -F'|' '{print $2}'
}

n_drows="$(delegate_rows "$SKILL" | grep -c .)"
n_drows="$(printf '%s' "$n_drows" | tr -d ' ')"
assert_eq "(G) 【代行編集】表から本文行を 1 行以上抽出できた" "true" \
  "$(if [ "$n_drows" -ge 1 ]; then echo true; else echo false; fi)"

assert_eq "(G) ロック取得を条件とする対象は台帳と priority-policy.md の 2 つちょうど" \
  "$(printf '%s\n' challenge-ledger.md priority-policy.md | sort)" \
  "$(locked_targets "$SKILL")"

# 語彙駆動: [commit] のパスのうち台帳以外は、どれも代行編集の対象に現れない。
check_no_leak() {
  leaked=""
  first_cells="$(delegate_first_cells "$1")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "challenge-ledger.md" ] && continue
    case "$first_cells" in
      *"$p"*) leaked="${leaked} ${p}" ;;
    esac
  done <<EOF
$commit_paths
cadence.json
EOF
  printf '%s' "$leaked"
}
if [ "$n_drows" -ge 1 ] && [ "$n_paths" -ge 1 ]; then
  assert_eq "(G) [commit] の他パスと cadence.json が代行編集の対象に漏れていない" "" "$(check_no_leak "$SKILL")"

  # 検出器の自己検査: 表へ journal/ の行を足した版では漏れとして検出されること。
  # 抽出が壊れて空になると上の 2 件が空虚に通るため、変異版で検出器が生きていることを示す。
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/adhoc-skill-test.XXXXXX")"
  awk '{print} /^\| `priority-policy.md` \|/ {print "| `journal/` | (a) 対話中の人間の明示指示 ∧ (b) ロック取得 | 変異 |"}' \
    "$SKILL" > "$tmpd/mutant.md"
  case "$(check_no_leak "$tmpd/mutant.md")" in
    *journal*) pass "(G) 検出器の自己検査（漏れを足した変異を検出する）" ;;
    *) fail "(G) 検出器の自己検査（漏れを足した変異を検出する）" "journal/ の行を足しても検出しなかった" ;;
  esac
  if [ "$(locked_targets "$tmpd/mutant.md" | grep -c .)" -eq 3 ]; then
    pass "(G) 検出器の自己検査（ロック条件の対象が増えたら件数が変わる）"
  else
    fail "(G) 検出器の自己検査（ロック条件の対象が増えたら件数が変わる）" "変異版の抽出件数が 3 でない"
  fi
  rm -rf "$tmpd"
fi

# 規定の骨格。「確認」ではなく「取得」、失敗時は書かない、解放は取得成功時だけ、書き方の条件。
DELEGATE_PHRASES=(
  '「ロックが無いことを確認する」ではなく**取得する**'
  'cycle-lock.sh" acquire --session-id <手順2 で発番した id> --workspace <エージェント repo ルート>'
  '**exit 2（並走検出）** → run-cycle（または別の差し込み）が保持中。**従来どおり書かず**'
  '**解放は取得に成功した場合だけ**'
  'cycle-lock.sh" release --session-id <手順2 で発番した id> --workspace <エージェント repo ルート>'
  '**`--dry-run` は付けない**'
  '`challenge-ledger.md.tmp` に対して行い'
  '`mv` で置換する'
  '`.flywheel/ledger-tx.json`'
  '**専用の独立コミット**'
  '`git commit -- <書いたパス>`'
  '`[commit]` にも `[exclude]` にも載っていないパス'
  '**ただし `.flywheel/` 配下（`cadence.json` を含む）と `.claude/` 配下'
)
for ph in "${DELEGATE_PHRASES[@]}"; do
  if grep -qF -- "$ph" "$SKILL"; then
    pass "(G) 規定が在る: ${ph}"
  else
    fail "(G) 規定が在る: ${ph}" "見つからない"
  fi
done

# acquire のコマンド行に --dry-run が付いていない（付けると stale 回収時の abandoned 代筆が
# 飛び、前周クラッシュの cycle_start が未終了のまま残る）。
acq_lines="$(grep -F 'cycle-lock.sh" acquire' "$SKILL")"
if [ -z "$acq_lines" ]; then
  fail "(G) acquire のコマンド行に --dry-run が無い" "acquire のコマンド行が見つからない"
elif printf '%s\n' "$acq_lines" | grep -qF -- '--dry-run'; then
  fail "(G) acquire のコマンド行に --dry-run が無い" "付いている"
else
  pass "(G) acquire のコマンド行に --dry-run が無い"
fi

# CLAUDE.md の台帳起票の規定が、旧規定（「並走していない」ことの確認）から取得条件へ移っている。
if grep -qF -- '並走していない対話セッションに限る' "$CLAUDE_TPL"; then
  fail "(G) CLAUDE.md に旧規定「並走していない対話セッションに限る」が残っていない" "見つかった"
else
  pass "(G) CLAUDE.md に旧規定「並走していない対話セッションに限る」が残っていない"
fi
if grep -qF -- '**取得できたとき**' "$CLAUDE_TPL"; then
  pass "(G) CLAUDE.md が台帳起票の条件をロックの取得としている"
else
  fail "(G) CLAUDE.md が台帳起票の条件をロックの取得としている" "**取得できたとき** が無い"
fi

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - $t"; done
  exit 1
fi
exit 0
