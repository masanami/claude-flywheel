#!/usr/bin/env bash
#
# parallel-plan.test.sh — run-cycle の並列化規定（Issue #149）の構造不変条件テスト。
#   手順2 が「その周の実行計画」を出し、手順3 がそのとおりに起動する、という分担と、
#   「並列は既定でも義務でもない」「同一スロットの既定は 1 件ずつ順に委譲」を固定する。
#
# 実行: bash scripts/tests/parallel-plan.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・grep・awk・ls。読み取り専用。
#
# 検査の要:
#   - **節を切り出してから**検査する。SKILL.md 全文への grep は、同じ語が別の節にあるだけで
#     空虚に真になる（PR #143 / #146 / #152 で実測）。抽出器自身も自己検査する（(A)）。
#   - **「規定がその節に在る」は出現回数の一致で固定する**（全文の出現回数 == 節内の出現回数）。
#     別の節や docs へ移しただけでは通らない＝位置まで固定される（空虚性検査）。
#   - **既定と例外の向きを構造で見る**（(C)）。「既定＝1 件ずつ順に委譲」の行が宣言に条件づけ
#     られていないこと**と**、束ねる許可がすべて宣言前提の行にしかないことを対で見る。
#     既定と例外が入れ替わると、バッチ非対応の接続ツールで主経路が成立しなくなる。
#   - **接続ツール固有のスキル名は形で見る**（(D)）。flywheel は接続ツールのスキル名リストを
#     持たない（ツール非依存が前提）ので、手書きの許可リストを置くと必ずずれる 2 本目の
#     リストになる（PR #96 の教訓）。代わりに「`/<英字>` 形の参照は、コードフェンス内か
#     『例』を含む行にしか現れてはならない」という形の規則で見て、flywheel 自身のスキル名
#     だけを `skills/` のディレクトリ名から**導出して**除外する（正本 1 本）。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

SKILL_MD="skills/run-cycle/SKILL.md"
POSITION_TPL="templates/position.md"
MIGRATE_RB="scripts/migrate-workspace.rb"

# 規範文（逐語で在ることと、在る場所を固定する）
SLOT_INVARIANT='1 作業スロットにつき同時に 1 セッション'
CURRENT_MAPPING='同一 repo の課題は同時に起動しない'
PLAN_RULE='【その周の実行計画】'
PLAN_DEF='`着手中` の課題を、手順3 が起動する前にここで実行計画へ落とす'
NO_N='「並列度 N」のような数値は出力しない'
CEILING='天井であって目標ではない'
ONE_IS_OK='同一条件でも当周は 1 本だけ起動する計画にしてよい'
SET_PLAN='計画は「集合」で立てる（1 件ずつに固定しない）'
PLAN_DRIVEN='起動は手順2【その周の実行計画】のとおりに行う'
DEFAULT_RULE='同一スロットに複数の課題が割り当たっている場合の既定は「1 件ずつ順に委譲」'
JOIN_ALL='手順4 へ進む前に、当周に起動した委譲を全件合流させる'
RESERVED='起動済み未合流分の予約額'
BATCH_MIN='束ねた各課題の `予算上限` の最小値'
BATCH_SUM='束ねた各課題の `予算上限` の合計'
BATCH_ONE_PAIR='起動ごとに 1 対だけ記録する'
LOG_EVENT_SH='scripts/log-run-event.sh'
DECL_NAME='委譲の起動形'

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
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "見つからない: $3"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "見つかった: $3"; else pass "$1"; fi; }
count_of() { printf '%s\n' "$1" | grep -cF -- "$2" | tr -d ' '; }
nonempty() {
  assert_eq "$1" "true" "$(if [ -n "$2" ]; then echo true; else echo false; fi)"
}

step2="$(awk '/^### 2\. /{f=1} /^### 3\. /{f=0} f' "${SKILL_MD}")"
step3="$(awk '/^### 3\. /{f=1} /^### 4\. /{f=0} f' "${SKILL_MD}")"
whole="$(cat "${SKILL_MD}")"

echo "=== (A) 抽出器の自己検査（手順2 / 手順3 を取り違えていない） ==="

nonempty "(A) 手順2 の節を切り出せた（空でない）" "${step2}"
nonempty "(A) 手順3 の節を切り出せた（空でない）" "${step3}"
has   "(A) 手順2 に手順2 固有のアンカーがある" "${step2}" '- 目標 → タスクに分解し'
hasnt "(A) 手順2 に手順3 固有のアンカーが混ざっていない（全文を返していない）" "${step2}" \
  '【費用ガード】委譲コマンドには必ず'
has   "(A) 手順3 に手順3 固有のアンカーがある" "${step3}" '【費用ガード】委譲コマンドには必ず'
hasnt "(A) 手順3 に手順2 固有のアンカーが混ざっていない" "${step3}" '- 目標 → タスクに分解し'

echo ""
echo "=== (B) 手順2: その周の実行計画（スロット割り当て・直列化グループ・本数の天井） ==="

has "(B) 手順2 が実行計画を出す" "${step2}" "${PLAN_RULE}"
has "(B) 出力① スロット割り当て" "${step2}" '**スロット割り当て**'
has "(B) 出力② 直列化グループ" "${step2}" '**直列化グループ**'
has "(B) 出力③ 子セッション本数の上限" "${step2}" '**子セッション本数の上限**'
has "(B) 判定できない組は同時に走らせない側へ倒す（fail-closed）" "${step2}" \
  '判定できない組は、走らせない側へ倒す'
has "(B) 計画は journal へ残る" "${step2}" 'journal「委譲」へ記録する'

# 不変条件は**普遍形**で書く（現状の写像で書くと、スロットの払い出し方が変わった周に
# 規定ごと書き直しになる）。語そのものを固定し、現状の写像が復活したら落とす。
has   "(B) 不変条件が普遍形の語で書かれている" "${step2}" "${SLOT_INVARIANT}"
hasnt "(B) 不変条件が現状の写像で書かれていない（否定検査）" "${whole}" "${CURRENT_MAPPING}"
has   "(B) 払い出し方は不変条件の外だと明示している" "${step2}" \
  'これは払い出し方の**現状**であって不変条件ではない'
has   "(B) スロットが 1 から N になっても規定を書き直さずに済む（前方互換）" "${step2}" \
  '複数スロットが出るようになっても本節の規定は書き換えずそのまま効く'

# 並列は**義務ではない**。天井の語・1 本でよい旨・スロットを埋めない旨を対で固定する。
has "(B) 本数は天井であって目標ではない" "${step2}" "${CEILING}"
has "(B) 同一条件でも 1 本にする計画が規定内で表現できる" "${step2}" "${ONE_IS_OK}"
has "(B) スロットを埋めることは要件ではない" "${step2}" 'スロットを埋めることは要件ではない'
has "(B) 天井は別に数を宣言せず 2 つの制約から導く（2 本目のリストを持たない）" "${step2}" \
  '**小さい方**として導き、別に数を宣言しない'

# 否定検査（並列非義務）: 「スロットを埋める」に言及する行は、必ず「要件ではない」と対で
# 書かれていること。義務（埋めよ）へ書き換わると、この向きが崩れて落ちる。
fill_bad="$(printf '%s\n' "${step2}" | grep -F -- 'スロットを埋める' | grep -vF -- '要件ではない')"
assert_eq "(B) 否定検査: 「スロットを埋める」が義務として書かれていない" "" "${fill_bad}"

# 否定検査（数値を出さない）: 並列度の数値を計画の出力にしない旨が在ること。
has "(B) 「並列度 N」という数値を出力しない" "${step2}" "${NO_N}"

# 集合単位の計画（`分類済` から 1 件ずつに固定されない）
has "(B) 分類済からの計画が集合単位である" "${step2}" "${SET_PLAN}"
has "(B) 並行して走らせられる集合をまとめて承認へ出す" "${step2}" \
  '**まとめてタスク案を書いて承認へ出す**'
has "(B) 1 件ずつだと並列が入口で枯れる理由が書かれている" "${step2}" '並列が入口で枯れる'
# FR-13 の承認ゲート自体は変えない（集合は提示の単位であって承認の単位ではない）
has "(B) FR-13 はエントリごとに 1 件ずつ適用する（ゲートを緩めない）" "${step2}" \
  '承認ゲート FR-13 は集合ではなくエントリごとに従来どおり 1 件ずつ適用する'

# 位置の固定（別の節・docs へ移しただけでは通らない＝空虚性検査）
assert_eq "(B) 実行計画の定義文は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${PLAN_DEF}")" "$(count_of "${whole}" "${PLAN_DEF}")"
assert_eq "(B) 実行計画の定義文がちょうど 1 回ある" "1" "$(count_of "${step2}" "${PLAN_DEF}")"
assert_eq "(B) 天井の規定は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${CEILING}")" "$(count_of "${whole}" "${CEILING}")"
assert_eq "(B) 「1 本にしてよい」は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${ONE_IS_OK}")" "$(count_of "${whole}" "${ONE_IS_OK}")"
assert_eq "(B) 「並列度 N を出力しない」は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${NO_N}")" "$(count_of "${whole}" "${NO_N}")"
assert_eq "(B) 集合計画の規定は手順2 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step2}" "${SET_PLAN}")" "$(count_of "${whole}" "${SET_PLAN}")"

echo ""
echo "=== (C) 手順3: 計画のとおりに起動する／既定は 1 件ずつ順に委譲／全件合流 ==="

has "(C) 手順3 は計画のとおりに起動する" "${step3}" "${PLAN_DRIVEN}"
has "(C) 手順3 に起動時のアドホックな並列判断が残っていない" "${step3}" \
  '本手順で並列度・順序・組み合わせを判断し直さない'
has "(C) 不変条件が手順3 にも普遍形の語で書かれている" "${step3}" "${SLOT_INVARIANT}"
has "(C) 各規定は委譲 1 件ごとに適用する（単数形の規定を複数件へ配る）" "${step3}" \
  'は**委譲 1 件ごとに**適用する'
assert_eq "(C) 計画駆動の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${PLAN_DRIVEN}")" "$(count_of "${whole}" "${PLAN_DRIVEN}")"
assert_eq "(C) 不変条件は手順2・手順3 の外に無い（全文の出現回数と一致）" \
  "$(($(count_of "${step2}" "${SLOT_INVARIANT}") + $(count_of "${step3}" "${SLOT_INVARIANT}")))" \
  "$(count_of "${whole}" "${SLOT_INVARIANT}")"

# --- 既定と例外の向き（入れ替わったら落ちる） ---
default_line="$(printf '%s\n' "${step3}" | grep -F -- "${DEFAULT_RULE}" | head -1)"
nonempty "(C) 既定の行がある" "${default_line}"
has   "(C) 既定は「1 件ずつ順に委譲」" "${default_line}" '1 件ずつ順に委譲'
has   "(C) 既定はどの接続ツールでも成立する経路である" "${default_line}" \
  '**この既定はどの接続ツールでも成立する**'
# **既定は無条件**であること: 既定の行がポジションの宣言に条件づけられていたら、
# バッチ非対応の接続ツールで主経路が成立しなくなる（既定と例外の入れ替わり）。
hasnt "(C) 否定検査: 既定がポジションの宣言に条件づけられていない" "${default_line}" '宣言'

# **束ねる許可は宣言前提の分岐の中にしか無い**こと。許可を与える語（束ねてよい／バッチ委譲）
# を含む行は、すべてポジションの宣言を参照していなければならない。
batch_bad="$(printf '%s\n' "${step3}" | grep -E -- '束ねてよい|バッチ委譲' | grep -vF -- '宣言')"
assert_eq "(C) 否定検査: 束ねる許可は宣言前提の行にしかない" "" "${batch_bad}"
batch_line="$(printf '%s\n' "${step3}" | grep -F -- '束ねてよい' | head -1)"
nonempty "(C) バッチ委譲の許可行がある" "${batch_line}"
has "(C) 許可は positions の §接続ツールの宣言から引く" "${batch_line}" \
  '`positions/<domain>.md` §接続ツールの**委譲の起動形**の宣言'
has "(C) 許可は条件付き（〜の場合に限り）" "${batch_line}" 'となっている場合に限り'
has "(C) 渡し方も同じ宣言から引く" "${batch_line}" '**渡し方も同じ宣言から引く**'
has "(C) run-cycle 本体に接続ツール固有のスキル名・フラグ名を書かない" "${batch_line}" \
  '**本スキルに接続ツール固有のスキル名・フラグ名を書かない**'
has "(C) 宣言なし・未宣言・非対応はすべて既定へ倒す（fail-closed）" "${batch_line}" \
  'すべて既定（1 件ずつ順に委譲）へ倒す'
# 既定が例外より先に書かれている（読み順でも既定が主経路）
d_no="$(printf '%s\n' "${step3}" | grep -nF -- "${DEFAULT_RULE}" | head -1 | cut -d: -f1)"
b_no="$(printf '%s\n' "${step3}" | grep -nF -- '束ねてよい' | head -1 | cut -d: -f1)"
if [ -n "${d_no}" ] && [ -n "${b_no}" ] && [ "${d_no}" -lt "${b_no}" ]; then
  pass "(C) 既定が例外より先に書かれている"
else
  fail "(C) 既定が例外より先に書かれている" "default=${d_no} batch=${b_no}"
fi

# --- 全件合流 ---
has "(C) 手順4 の前に全件合流させる" "${step3}" "${JOIN_ALL}"
has "(C) 合流の定義（返り値 → 照合 → delegate_end）" "${step3}" \
  '合流とは**返り値の受領 →【委譲結果の照合】→ `delegate_end` の記録**までを指す'
has "(C) 合流できない委譲は打ち切って閉じる（未終了 start を残さない）" "${step3}" \
  '合流できない委譲（応答が返らない等）は待ち続けず打ち切り'
has "(C) 照合は起動した全件を 1 件ずつ行う" "${step3}" \
  '**照合は当周に起動した委譲を全件、1 件ずつ行う**'
has "(C) 束ねた委譲でも照合とステータス更新は課題ごと" "${step3}" \
  '照合とステータス更新は束ねた課題ごとに行う'
assert_eq "(C) 全件合流の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${JOIN_ALL}")" "$(count_of "${whole}" "${JOIN_ALL}")"

# --- 費用ガードが複数件に対応している（詳細は cycle-budget-guard.test.sh） ---
has "(C) 起動前評価が起動済み未合流分を予約額として数える" "${step3}" "${RESERVED}"

echo ""
echo "=== (G) バッチ委譲: 予算は最小値・イベントは起動ごとに 1 対（PR #155 レビュー対応） ==="

# --- 予算: 最小値であって合計ではない ---
# 1 セッションが返す total_cost_usd は 1 つで per-課題 の按分ができない。合計を渡すと
# 承認額の小さい課題が束ね全体の枠を使えてしまい、FR-13 の承認（大きさ・予算の承認でもある）
# が壊れる。**否定検査を対で置く**（合計へ戻したら落ちる）。
has   "(G) バッチの上限は束ねた各課題の予算上限の最小値" "${step3}" "${BATCH_MIN}"
hasnt "(G) 否定検査: バッチの上限が「合計」へ戻っていない" "${step3}" "${BATCH_SUM}"
has   "(G) 最小値である理由（total_cost_usd が 1 つで按分できない）" "${step3}" \
  '**1 セッションが返す `total_cost_usd` は 1 つで、どの課題がいくら使ったかを按分できない**'
has   "(G) 合計にすると FR-13 の承認を壊すと書かれている" "${step3}" \
  '**FR-13 の承認（方向に加えて大きさ・予算の承認でもある）を壊す**'
# 帰結を黙らせない（算出不能なものを算出できるかのように残さない）
has "(G) 上限到達時は束ねた全課題をまとめて打ち切り扱い" "${step3}" \
  '上限到達時は束ねた全課題をまとめて打ち切り扱いにし'
has "(G) 残予算は束ね単位で追い、per-課題 の残予算は算出しない" "${step3}" \
  'per-課題 の残予算は算出しない＝算出不能であることを黙らせない'
has "(G) 束ねる動機は起動回数の削減であって予算ではない" "${step3}" \
  '**束ねる動機は起動回数の削減であって予算ではない**'
has "(G) 利得が無ければ束ねず既定へ倒せる（各課題は自分の予算上限を使える）" "${step3}" \
  '**最小値が小さすぎて利得が無いなら束ねずに既定（1 件ずつ順に委譲）へ倒せばよい**'

# --- イベント: 起動ごとに 1 対（課題ごとに積まない） ---
has   "(G) バッチのイベントは起動ごとに 1 対だけ" "${step3}" "${BATCH_ONE_PAIR}"
hasnt "(G) 否定検査: 「課題ごとに同じ session_id で記録する」へ戻っていない" "${step3}" \
  '課題ごとに同じ `session_id` で記録する'
has   "(G) 課題ごとの start を同じ session_id へ積まない（禁止として書かれている）" "${step3}" \
  '**課題ごとの `delegate_start` を同じ `session_id` へ積んではならない**'
# **理由を残す**（理由が消えると次の周に「課題ごとに打つ」へ戻される）
has "(G) 理由: 対応付けは session_id のみをキーに LIFO で行う" "${step3}" \
  '対応付けは `session_id` だけをキーに **LIFO**'
has "(G) 理由: end が 1 件落ちると別の課題が dangling_start として報告される" "${step3}" \
  '実際には完了した課題のほうが `dangling_start` として報告される'
has "(G) 束ねた課題の判別は --title と journal が担う" "${step3}" \
  '`--title`（束ねた課題 ID を列挙）と手順6 の journal「委譲」が担い'
has "(G) --challenge はカンマ区切りの 1 値" "${step3}" \
  '**束ねた課題 ID をカンマ区切りで 1 つの値として渡す**'
has "(G) 対応付けの規約と log-run-event.sh は変更しない" "${step3}" \
  '**対応付けの規約（正本は `runtime/README.md`）と `log-run-event.sh` は変更しない**'

# 位置の固定（別の節・docs へ移しただけでは通らない＝空虚性検査）
assert_eq "(G) バッチ予算の規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${BATCH_MIN}")" "$(count_of "${whole}" "${BATCH_MIN}")"
assert_eq "(G) バッチ予算の規定がちょうど 1 回ある" "1" "$(count_of "${step3}" "${BATCH_MIN}")"
assert_eq "(G) バッチのイベント規定は手順3 の外に無い（全文の出現回数と一致）" \
  "$(count_of "${step3}" "${BATCH_ONE_PAIR}")" "$(count_of "${whole}" "${BATCH_ONE_PAIR}")"
assert_eq "(G) バッチのイベント規定がちょうど 1 回ある" "1" "$(count_of "${step3}" "${BATCH_ONE_PAIR}")"

# --- 規定が寄りかかっている実装の性質を、実コードで確認する ---
# 「--challenge はカンマ区切りで置ける」「対応付けキーは session_id のみ」は
# log-run-event.sh の実装に依存する主張。実装が変わったらここで落として規定を見直させる
# （散文が実装の性質を語るときは、その性質自体を検査する）。
log_sh="$(cat "${LOG_EVENT_SH}")"
has   "(G) 実コード: delegate_* の対応付けキーは session_id のみ" "${log_sh}" 'key="d:$sid"'
hasnt "(G) 実コード: 対応付けキーに challenge を使っていない" "${log_sh}" 'key="d:$sid:$CHALLENGE"'
has   "(G) 実コード: --session-id は対応付けキーとして文字を拒否される" "${log_sh}" \
  'reject_unsafe_key "$SESSION_ID" "--session-id"'
hasnt "(G) 実コード: --challenge は対応付けキー扱いされていない（文字制約が無い）" "${log_sh}" \
  'reject_unsafe_key "$CHALLENGE"'

echo ""
echo "=== (D) 接続ツール固有のスキル名は、フェンス内か「例」を含む行にしか現れない ==="

# flywheel 自身のスキル名は `skills/` から**導出**する（手書きの 2 本目のリストを持たない）。
own_skills="$(ls -1 skills 2>/dev/null | tr '\n' ' ')"
nonempty "(D) flywheel 自身のスキル名を skills/ から導出できた" "${own_skills}"

scan_skill_refs() {
  awk -v own="$1" '
    BEGIN { n = split(own, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]] = 1 }
    /^[ \t]*```/ { fence = 1 - fence; next }
    fence { next }
    {
      line = $0
      s = line
      while (match(s, /`\/[a-z][a-z0-9:-]*`/)) {
        tok = substr(s, RSTART + 2, RLENGTH - 3)
        s = substr(s, RSTART + RLENGTH)
        bare = tok
        if (index(bare, ":") > 0) { k = split(bare, p, ":"); bare = p[k] }
        if ((bare in ok) || (tok in ok)) continue
        if (index(line, "例") > 0) continue
        printf "%d:/%s\n", NR, tok
      }
    }
  ' "$2"
}

# 検出器の自己検査: 違反を必ず 1 件見つける合成入力で、検出器が黙っていないことを示す。
probe="$(mktemp "${TMPDIR:-/tmp}/parallel-plan-probe.XXXXXX")"
printf '%s\n' \
  '- 接続ツールの `/some-tool-skill` を使う。' \
  '- フェンス内は数えない:' \
  '```bash' \
  'claude -p --skill `/fenced-skill`' \
  '```' \
  '- 例: `/allowed-by-example` は許す。' > "${probe}"
probe_hits="$(scan_skill_refs "${own_skills}" "${probe}")"
rm -f "${probe}"
assert_eq "(D) 検出器の自己検査: 合成入力の違反をちょうど 1 件検出する" \
  "1:/some-tool-skill" "${probe_hits}"

violations="$(scan_skill_refs "${own_skills}" "${SKILL_MD}")"
assert_eq "(D) run-cycle SKILL.md に例文脈外のスキル名参照が無い" "" "${violations}"

echo ""
echo "=== (E) 並列度をフラグで持たない（並列度フラグのリテラルを本体に持ち込まない） ==="

# 禁止リテラルは実行時に組み立てる（このテストファイル自身が検査に引っかからないため）。
banned="--max-""parallel"
mp="$(grep -rl -- "${banned}" skills scripts contracts templates 2>/dev/null | tr '\n' ' ')"
assert_eq "(E) flywheel 本体に ${banned} のリテラルが無い" "" "$(printf '%s' "${mp}" | sed 's/ *$//')"

echo ""
echo "=== (F) 起動形の宣言欄がポジション雛形にあり、追従検出が拾える ==="

pos_tpl="$(cat "${POSITION_TPL}")"
has "(F) ポジション雛形に起動形の宣言欄がある" "${pos_tpl}" "**${DECL_NAME}**"
has "(F) 宣言の値域が示されている" "${pos_tpl}" '`受け取れる` | `受け取れない` | `未宣言`'
has "(F) 宣言なしは既定（1 件ずつ順に委譲）へ倒すと雛形にも書かれている" "${pos_tpl}" \
  '**`受け取れない` と `未宣言` はどちらも既定のまま**'
has "(F) 渡し方の記入欄がある（run-cycle 本体に固有名を置かないための正本）" "${pos_tpl}" \
  '**束ね方はこの宣言だけが正本**'
has "(F) 手順3 の参照先の宣言名が雛形と一致する" "${step3}" "**${DECL_NAME}**"

# 内容ベースの追従検出（既存ワークスペースは版マーカーだけでは拾えない世代がある）
has "(F) migrate-workspace.rb の必須宣言項目に起動形が入っている" \
  "$(cat "${MIGRATE_RB}")" "\"${DECL_NAME}\","

# 検出器が要求する宣言項目は、すべて雛形が提供していること（雛形に無い項目を要求すると
# 誰も追従できない報告が出続ける）。項目の正本は雛形側 1 本。
items="$(awk '/^POSITION_TOOL_ITEMS = \[/{f=1; next} /^\]\.freeze/{f=0} f' "${MIGRATE_RB}" \
  | sed -e 's/^[ \t]*"//' -e 's/",[ \t]*$//' -e 's/"[ \t]*$//')"
nonempty "(F) POSITION_TOOL_ITEMS を抽出できた" "${items}"
missing=""
while IFS= read -r label; do
  [ -n "${label}" ] || continue
  printf '%s\n' "${pos_tpl}" | grep -qF -- "${label}" || missing="${missing} ${label}"
done <<EOF
${items}
EOF
assert_eq "(F) 検出器が要求する宣言項目はすべて雛形にある" "" "${missing}"

echo ""
echo "=== summary === pass: ${PASS}, fail: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo "failed:"
  for t in ${FAILED+"${FAILED[@]}"}; do echo "  - ${t}"; done
  exit 1
fi
exit 0
