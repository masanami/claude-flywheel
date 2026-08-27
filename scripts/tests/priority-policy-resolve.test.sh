#!/usr/bin/env bash
#
# priority-policy-resolve.test.sh — scripts/priority-policy-resolve.sh のテスト。
#
# 実行: bash scripts/tests/priority-policy-resolve.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・git。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 本テストが守る要（run-cycle 手順0 の判定をスクリプトへ移すにあたって）:
#
#   1. **フォールバック 5 分類の行の完全性**（双方向）。`--list-fallbacks` が返す一覧と、
#      振る舞いで実際に観測できた `fallback=` の集合が**両方向で一致**すること。片方向だけの
#      検査（「一覧の各行が振る舞いに現れる」だけ）は、分類を足して振る舞いを書き忘れても
#      通ってしまう。ここは両方向で固定する。
#   2. **異常系の出力契約**。exit 1 なら必ず `fallback=` が 1 行、exit 0 なら `fallback=` を
#      出さない、`active=` は undefined-mode のときだけ（他 4 分類はファイル内容を読んでいない
#      ため該当なし）、exit 2 でも `report=` は必ず出る（呼び出し側の転記手順を一様にする）。
#   3. **受理方向**。実際に配布している `templates/priority-policy.md` をそのまま置いた状態が
#      受理されること（「自分の正規出力を自分が受理しない」欠陥の予防）。
#   4. **同一性**。作業ツリーではなく控えた SHA の内容を読んでいること（作業ツリーのファイルを
#      読めなくしても解決できる）。一般形（「モードが取れる」）だけでなく出典まで固定する。
#   5. **部分一致で受理しない**。`active` とモード名は完全一致のみ。
#   6. **起動失敗経路の境界**。スクリプトが起動できない（exit 126/127）と stdout が空になり
#      `report=` を取得できない。`--list-exits` は**スクリプト自身が返す** 0/1/2 だけを宣言し
#      （126/127 はシェル由来なので含めない）、SKILL 側に別経路の規定があることを要求する。
#      exit の宣言と振る舞いも 5 と同じく双方向＋空集合ガードで固定する。
#   7. **準備の失敗を被検体の欠陥として報告しない**。外部の Git 設定（`core.hooksPath` /
#      `core.excludesFile` 等）で `git init` / `add` / `commit` が失敗すると、HEAD が作られず
#      以後の検査が `git-error` を報告する——本物の欠陥と見分けが付かないうえ、
#      「Git 検証エラーの分類」のような検査は**間違った理由で pass する**（偽陽性）。
#      環境変数で外部設定を遮断し、準備コマンドの終了状態を毎回確認して即座に打ち切る。

set -u
set -o pipefail   # 準備用パイプライン（policy_file | commit_policy）の失敗を握り潰さないため

# **外部の Git 設定を遮断する**（Git 2.32+）。グローバル／システム設定の `core.hooksPath` で
# フックが走ると `git commit` が失敗して HEAD が作られず、以後のテストが**準備の失敗を
# 被検体の欠陥として報告する**（例:「不在の分類 want=missing got=git-error」）。さらに悪いことに
# 「Git 検証エラーの分類」のような検査は**間違った理由で pass する**（偽陽性）。
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$TESTS_DIR/../priority-policy-resolve.sh"
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"
TEMPLATE="$REPO_ROOT/templates/priority-policy.md"

PASS=0
FAIL=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 振る舞いで観測した値の記録先（構造不変条件の双方向検査で使う）
OBSERVED="$tmp/observed-fallbacks.txt"
OBSERVED_EXITS="$tmp/observed-exits.txt"
: > "$OBSERVED"
: > "$OBSERVED_EXITS"

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; shift; for l in "$@"; do echo "       $l"; done; }

# setup_fail <理由> — 準備の失敗。**呼び出し側の文脈から**呼ぶこと。
# new_ws はコマンド置換、commit_policy はパイプの中で走るため、それらの関数内で exit しても
# 親スクリプトは止まらない。準備が壊れたまま先へ進むと被検体の欠陥として誤報告されるので、
# ここで即座に打ち切る。
setup_fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - テスト準備に失敗: $1"
  echo
  echo "passed: $PASS / failed: $FAIL"
  exit 1
}

# run <workspace> [extra args...] — スクリプトを実行し RUN_OUT / RUN_ERR / RUN_EXIT に格納する
run() {
  ws="$1"; shift
  RUN_OUT="$(bash "$SCRIPT" --workspace "$ws" "$@" 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  echo "$RUN_EXIT" >> "$OBSERVED_EXITS"
}

# field <key> — RUN_OUT から key=... の値を取り出す（無ければ空）
field() { printf '%s\n' "$RUN_OUT" | sed -n "s/^$1=//p"; }

# assert_exit <名前> <期待exit>
assert_exit() {
  if [ "$RUN_EXIT" -eq "$2" ]; then pass "$1"
  else fail "$1 (exit: got=$RUN_EXIT want=$2)" "stdout: $RUN_OUT" "stderr: $RUN_ERR"; fi
}

# assert_field <名前> <key> <期待値>
assert_field() {
  got="$(field "$2")"
  if [ "$got" = "$3" ]; then pass "$1"
  else fail "$1 ($2: got='$got' want='$3')" "stdout: $RUN_OUT"; fi
}

# assert_no_field <名前> <key>
assert_no_field() {
  got="$(field "$2")"
  if [ -z "$got" ]; then pass "$1"
  else fail "$1 ($2 が出力されている: '$got')" "stdout: $RUN_OUT"; fi
}

# assert_contains <名前> <ファイル> <部分文字列>
assert_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"
  else fail "$1" "'$3' が $2 に見つからない"; fi
}

# assert_not_contains <名前> <ファイル> <部分文字列>
assert_not_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' が $2 に残っている"
  else pass "$1"; fi
}

# record_fallback — 直前の run で観測した fallback 値を記録する
record_fallback() { f="$(field fallback)"; [ -n "$f" ] && echo "$f" >> "$OBSERVED"; return 0; }

# --- ワークスペースの作成ヘルパ ---------------------------------------------

# new_ws <名前> — 一時 Git ワークスペースを作り、パスを stdout に返す。
# **どの準備コマンドが失敗しても非 0 を返す**（呼び出し側で `|| setup_fail` すること）。
# 失敗理由は $tmp/setup-error に残す（コマンド置換の中なので stdout には書けない）。
new_ws() {
  ws="$tmp/$1"
  mkdir -p "$ws" || { echo "mkdir: $ws" > "$tmp/setup-error"; return 1; }
  git -C "$ws" init -q                                   >/dev/null 2>&1 || { echo "git init: $ws"          > "$tmp/setup-error"; return 1; }
  git -C "$ws" config user.email t@example.com           >/dev/null 2>&1 || { echo "config user.email: $ws" > "$tmp/setup-error"; return 1; }
  git -C "$ws" config user.name test                     >/dev/null 2>&1 || { echo "config user.name: $ws"  > "$tmp/setup-error"; return 1; }
  git -C "$ws" config commit.gpgsign false               >/dev/null 2>&1 || { echo "config gpgsign: $ws"    > "$tmp/setup-error"; return 1; }
  git -C "$ws" config core.hooksPath /dev/null           >/dev/null 2>&1 || { echo "config hooksPath: $ws"  > "$tmp/setup-error"; return 1; }
  printf 'seed\n' > "$ws/seed.txt"                                       || { echo "write seed: $ws"        > "$tmp/setup-error"; return 1; }
  git -C "$ws" add -A                                    >/dev/null 2>&1 || { echo "git add: $ws"           > "$tmp/setup-error"; return 1; }
  git -C "$ws" commit -qm init                           >/dev/null 2>&1 || { echo "git commit: $ws"        > "$tmp/setup-error"; return 1; }
  git -C "$ws" rev-parse HEAD                            >/dev/null 2>&1 || { echo "HEAD 未作成: $ws"       > "$tmp/setup-error"; return 1; }
  echo "$ws"
}

# setup_reason — 直近の準備失敗の理由（無ければ "不明"）
setup_reason() { cat "$tmp/setup-error" 2>/dev/null || echo "不明"; }

# policy_file <active値> [追加モード名...] — 最小の priority-policy.md を書き出す
policy_file() {
  a="$1"; shift
  {
    printf '# タスク優先度の決定方針\n\n'
    printf '> 切り替えは `active:` 行の編集で行う（この行は散文であり正本ではない）。\n\n'
    printf '## 現在のモード\n\n'
    printf '```text\n'
    printf 'active: %s\n' "$a"
    printf '```\n\n'
    printf '## モード定義\n\n'
    printf '### `normal`（既定）\n\n- 優先度判定ルール: ...\n- 着手順の選択基準: ...\n\n'
    for m in "$@"; do
      printf '### `%s`（記入例）\n\n- 優先度判定ルール: ...\n- 着手順の選択基準: ...\n\n' "$m"
    done
  }
}

# commit_policy <ws> — stdin の内容を priority-policy.md として書き、コミットする。
# パイプの右側で走るため、`set -o pipefail` と呼び出し側の `|| setup_fail` で失敗を拾う。
commit_policy() {
  cat > "$1/priority-policy.md"                          || { echo "write policy: $1" > "$tmp/setup-error"; return 1; }
  git -C "$1" add -- priority-policy.md  >/dev/null 2>&1 || { echo "add policy: $1"   > "$tmp/setup-error"; return 1; }
  git -C "$1" commit -qm policy          >/dev/null 2>&1 || { echo "commit policy: $1" > "$tmp/setup-error"; return 1; }
}

echo "== 1. 受理方向（正規の入力が受理されること） =="

ws="$(new_ws accept)" || setup_fail "$(setup_reason)"
policy_file normal | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "既定モードは exit 0" 0
assert_field "mode を返す" mode normal
assert_field "resolution=policy" resolution policy
assert_no_field "適用時は fallback を出さない" fallback
assert_no_field "適用時は active を出さない（未定義モード時のみ）" active
if [ -n "$(field sha)" ]; then pass "適用時に sha を出す"; else fail "適用時に sha を出す" "stdout: $RUN_OUT"; fi

# 実際に配布している雛形そのものが受理されること
ws="$(new_ws accept-template)" || setup_fail "$(setup_reason)"
cat "$TEMPLATE" | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "配布中の templates/priority-policy.md をそのまま受理する" 0
assert_field "雛形の既定モードは normal" mode normal

# 雛形は散文中に `active:` を含む。それを拾って誤判定しないこと（上の 2 件で担保されるが明示する）
if grep -q '`active:`' "$TEMPLATE"; then pass "前提確認: 雛形の散文に \`active:\` が含まれている"
else fail "前提確認: 雛形の散文に \`active:\` が含まれている" "テストの前提が崩れている"; fi

ws="$(new_ws accept-switch)" || setup_fail "$(setup_reason)"
policy_file release-freeze release-freeze | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "別モードへの切り替えを受理する" 0
assert_field "切り替え後の mode" mode release-freeze

ws="$(new_ws accept-colon)" || setup_fail "$(setup_reason)"
policy_file 'domain-bootstrap:payments' 'domain-bootstrap:payments' | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "コロンを含むモード名を受理する" 0
assert_field "コロンを含む mode" mode 'domain-bootstrap:payments'

echo "== 2. フォールバック 5 分類（振る舞い） =="

# (1) missing — ファイルが存在しない
ws="$(new_ws fb-missing)" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "不在は exit 1" 1
assert_field "不在の分類" fallback missing
assert_field "不在の resolution" resolution agent-discretion
assert_no_field "不在では active を出さない（内容を読んでいない）" active
record_fallback

# (2) untracked — 存在するが未追跡
ws="$(new_ws fb-untracked)" || setup_fail "$(setup_reason)"
policy_file normal > "$ws/priority-policy.md"
run "$ws"
assert_exit "未追跡は exit 1" 1
assert_field "未追跡の分類" fallback untracked
assert_no_field "未追跡では active を出さない" active
record_fallback

# (3) dirty — 作業ツリーに変更
ws="$(new_ws fb-dirty-worktree)" || setup_fail "$(setup_reason)"
policy_file normal | commit_policy "$ws" || setup_fail "$(setup_reason)"
printf '\n変更\n' >> "$ws/priority-policy.md"
run "$ws"
assert_exit "作業ツリー変更は exit 1" 1
assert_field "作業ツリー変更の分類" fallback dirty
assert_no_field "dirty では active を出さない" active
record_fallback

# (3') dirty — ステージ済み変更
ws="$(new_ws fb-dirty-index)" || setup_fail "$(setup_reason)"
policy_file normal | commit_policy "$ws" || setup_fail "$(setup_reason)"
printf '\n変更\n' >> "$ws/priority-policy.md"
git -C "$ws" add -- priority-policy.md >/dev/null 2>&1
run "$ws"
assert_exit "ステージ済み変更も exit 1" 1
assert_field "ステージ済み変更の分類" fallback dirty
record_fallback

# (3'') dirty — 追跡済みファイルの削除（SKILL が「削除を含む」と明記していた条件）
ws="$(new_ws fb-dirty-deleted)" || setup_fail "$(setup_reason)"
policy_file normal | commit_policy "$ws" || setup_fail "$(setup_reason)"
rm -f "$ws/priority-policy.md"
run "$ws"
assert_exit "追跡済みファイルの削除も exit 1" 1
assert_field "削除は dirty に分類する（不在ではない）" fallback dirty
record_fallback

# (4) git-error — Git リポジトリでない
ws="$tmp/fb-git-error"; mkdir -p "$ws"
policy_file normal > "$ws/priority-policy.md"
run "$ws"
assert_exit "Git リポジトリでないは exit 1" 1
assert_field "Git 検証エラーの分類" fallback git-error
assert_no_field "git-error では active を出さない" active
record_fallback

# (5) undefined-mode — active に一致するモード定義が無い
ws="$(new_ws fb-undefined)" || setup_fail "$(setup_reason)"
policy_file typo-mode | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "未定義モードは exit 1" 1
assert_field "未定義モードの分類" fallback undefined-mode
assert_field "未定義モードでは検出した active 値を出す" active typo-mode
record_fallback

echo "== 3. 解析の細部（部分一致で受理しない・phantom mode を作らない） =="

# active=normal-2。定義側には normal / normal-2 / normal-2x が並ぶ。
# 前方一致で拾うと normal または normal-2x を誤って採る。
ws="$(new_ws parse-prefix)" || setup_fail "$(setup_reason)"
policy_file normal-2 normal-2 normal-2x | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "似た名前が並んでいても解決できる" 0
assert_field "完全一致するモードだけを採る（normal / normal-2x を採らない）" mode normal-2

# 前方一致の**両方向**を塞ぐ。片方向だけだと、比較を `=` から前方一致へ緩めた欠陥が
# 生き残る（実際、変異注入で最初この穴が見つかった）。
#   (i)  active がモード名で始まる: active=normal-extra / 定義=normal のみ
ws="$(new_ws parse-partial-active-longer)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n```text\nactive: normal-extra\n```\n\n'
  printf '### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "active がモード名で始まるだけでは適用しない" 1
assert_field "active=normal-extra は normal に一致しない" fallback undefined-mode
assert_field "その active 値" active normal-extra

#   (ii) モード名が active で始まる: active=norm / 定義=normal のみ
ws="$(new_ws parse-partial-mode-longer)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n```text\nactive: norm\n```\n\n'
  printf '### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "モード名が active で始まるだけでは適用しない" 1
assert_field "部分一致では受理しない（norm ≠ normal）" fallback undefined-mode
assert_field "部分一致時の active 値" active norm

ws="$(new_ws parse-comment-heading)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n```text\nactive: ghost\n```\n\n'
  printf '<!--\n### `ghost`（コメント内の見本。モード定義ではない）\n-->\n\n'
  printf '### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_field "HTML コメント内の見出しをモード定義として採らない" fallback undefined-mode

ws="$(new_ws parse-fence-heading)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n```text\nactive: ghost\n```\n\n'
  printf '```markdown\n### `ghost`（コードブロック内の例示）\n```\n\n'
  printf '### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_field "コードフェンス内の見出しをモード定義として採らない" fallback undefined-mode

ws="$(new_ws parse-comment-active)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n<!--\nactive: ghost\n-->\n\n```text\nactive: normal\n```\n\n'
  printf '### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "コメントアウトされた active: を採らない" 0
assert_field "生きている active: を採る" mode normal

ws="$(new_ws parse-dup-active)" || setup_fail "$(setup_reason)"
{
  printf '```text\nactive: normal\n```\n\n```text\nactive: release-freeze\n```\n\n'
  printf '### `normal`（既定）\n\n- x\n\n### `release-freeze`（例）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "active: が複数あるときは適用しない" 1
assert_field "active: 重複は undefined-mode へ倒す（推測で片方を選ばない）" fallback undefined-mode

ws="$(new_ws parse-no-active)" || setup_fail "$(setup_reason)"
{
  printf '## 現在のモード\n\n（未記入）\n\n### `normal`（既定）\n\n- x\n'
} | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
assert_exit "active: が無いときは適用しない" 1
assert_field "active: 不在は undefined-mode へ倒す" fallback undefined-mode

echo "== 4. 同一性（作業ツリーではなく控えた SHA を読む） =="

# 「作業ツリーを読んでいない」ことを**観測可能にする**: assume-unchanged を立てると
# git diff は当該ファイルを見なくなるため、作業ツリーと HEAD が食い違ったまま
# 「差分なし」で検証を通過する状態を作れる。ここで返るモードが HEAD 側なら
# `git show <SHA>:<file>` を読んでいる証拠になる（作業ツリー側なら読んでいる＝欠陥）。
ws="$(new_ws identity)" || setup_fail "$(setup_reason)"
policy_file normal release-freeze | commit_policy "$ws" || setup_fail "$(setup_reason)"
if git -C "$ws" update-index --assume-unchanged -- priority-policy.md >/dev/null 2>&1; then
  policy_file release-freeze release-freeze > "$ws/priority-policy.md"
  run "$ws"
  git -C "$ws" update-index --no-assume-unchanged -- priority-policy.md >/dev/null 2>&1
  assert_exit "作業ツリーと HEAD が食い違っていても解決できる" 0
  assert_field "作業ツリー（release-freeze）ではなく HEAD（normal）の内容を採る" mode normal
else
  echo "skip - 同一性テスト（git update-index --assume-unchanged が使えない）"
fi

ws="$(new_ws identity-sha)" || setup_fail "$(setup_reason)"
policy_file normal | commit_policy "$ws" || setup_fail "$(setup_reason)"
run "$ws"
head_sha="$(git -C "$ws" rev-parse HEAD)"
assert_field "sha は検証時点の HEAD と一致する" sha "$head_sha"

echo "== 5. exit 2（検査不能）と出力契約の一様性 =="

run "$tmp/does-not-exist"
assert_exit "存在しないワークスペースは exit 2（検査不能）" 2
assert_no_field "検査不能は fallback を出さない（5 分類は exit 1 のみ）" fallback
if [ -n "$(field report)" ]; then pass "検査不能でも report= を出す（転記手順を一様にする）"
else fail "検査不能でも report= を出す" "stdout: $RUN_OUT"; fi
if [ -n "$RUN_ERR" ]; then pass "検査不能は stderr に理由を書く"
else fail "検査不能は stderr に理由を書く" "stderr が空"; fi

echo "== 6. report= の文言（サイクルレポートへの転記の正本） =="

ws="$(new_ws report-policy)" || setup_fail "$(setup_reason)"; policy_file normal | commit_policy "$ws"; run "$ws"
assert_field "report（適用時）" report "適用方針モード: normal"

ws="$(new_ws report-missing)" || setup_fail "$(setup_reason)"; run "$ws"
assert_field "report（不在）" report \
  "適用方針モード: エージェント裁量（priority-policy.md が存在しないため適用せず、エージェント裁量で判定）"

ws="$(new_ws report-untracked)" || setup_fail "$(setup_reason)"; policy_file normal > "$ws/priority-policy.md"; run "$ws"
assert_field "report（未追跡）" report \
  "適用方針モード: エージェント裁量（priority-policy.md が未追跡のため適用せず、エージェント裁量で判定）"

ws="$(new_ws report-dirty)" || setup_fail "$(setup_reason)"; policy_file normal | commit_policy "$ws"
printf 'x\n' >> "$ws/priority-policy.md"; run "$ws"
assert_field "report（未コミットの変更あり）" report \
  "適用方針モード: エージェント裁量（priority-policy.md に未コミットの変更があるため適用せず、エージェント裁量で判定）"

ws="$tmp/report-git-error"; mkdir -p "$ws"; policy_file normal > "$ws/priority-policy.md"; run "$ws"
assert_field "report（Git 検証エラー）" report \
  "適用方針モード: エージェント裁量（priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定）"

ws="$(new_ws report-undefined)" || setup_fail "$(setup_reason)"; policy_file typo | commit_policy "$ws"; run "$ws"
assert_field "report（未定義モード）" report \
  "適用方針モード: エージェント裁量（priority-policy.md の active 値 \`typo\` に一致するモード定義が見つからず、エージェント裁量で判定）"

echo "== 7. 構造不変条件: フォールバック 5 分類の行の完全性（双方向） =="

listed="$(bash "$SCRIPT" --list-fallbacks 2>/dev/null)"
listed_exit=$?

# 宣言の取得は**終了状態まで**検査する。stdout だけを見ると、正しい一覧を出したあとに
# 非 0 で終わる変異（呼び出し側が宣言を取得できない状態）がこの検査を素通りする。
if [ "$listed_exit" -eq 0 ]; then pass "--list-fallbacks は exit 0 で終了する"
else fail "--list-fallbacks は exit 0 で終了する" "got=$listed_exit"; fi
expected="missing
untracked
dirty
git-error
undefined-mode"

if [ "$listed" = "$expected" ]; then
  pass "--list-fallbacks が 5 分類を宣言順どおり返す"
else
  fail "--list-fallbacks が 5 分類を宣言順どおり返す" "got:  $(echo "$listed" | tr '\n' ' ')" "want: $(echo "$expected" | tr '\n' ' ')"
fi

n_listed="$(printf '%s\n' "$listed" | grep -c . || true)"
if [ "$n_listed" -eq 5 ]; then pass "フォールバックはちょうど 5 分類（増減したら落ちる）"
else fail "フォールバックはちょうど 5 分類" "got=$n_listed"; fi

# 双方向の完全性:
#   (a) 宣言 ⊆ 振る舞い … 一覧に足しただけで振る舞いのテストを書き忘れたら落ちる
#   (b) 振る舞い ⊆ 宣言 … 一覧に無い値を返し始めたら落ちる
obs_sorted="$(sort -u "$OBSERVED")"
list_sorted="$(printf '%s\n' "$listed" | grep . | sort -u)"

# 空リストで全称条件が空虚に真になるのを防ぐ（両集合が空だと下の comm は差分ゼロ＝pass に
# 見えてしまう）。まず「観測が 5 件そろっている」ことを独立に固定する。
n_obs="$(printf '%s\n' "$obs_sorted" | grep -c . || true)"
if [ "$n_obs" -eq 5 ]; then
  pass "振る舞いで観測した分類がちょうど 5 種類（空集合で下の比較が空虚に真になるのを防ぐ）"
else
  fail "振る舞いで観測した分類がちょうど 5 種類" \
       "got=$n_obs: $(echo "$obs_sorted" | tr '\n' ' ')"
fi

missing_in_behavior="$(comm -23 <(printf '%s\n' "$list_sorted") <(printf '%s\n' "$obs_sorted"))"
if [ -z "$missing_in_behavior" ]; then
  pass "(a) 宣言した 5 分類すべてが振る舞いテストで観測されている"
else
  fail "(a) 宣言した 5 分類すべてが振る舞いテストで観測されている" \
       "振る舞いで観測されなかった分類: $(echo "$missing_in_behavior" | tr '\n' ' ')"
fi

missing_in_list="$(comm -13 <(printf '%s\n' "$list_sorted") <(printf '%s\n' "$obs_sorted"))"
if [ -z "$missing_in_list" ]; then
  pass "(b) 振る舞いが返す分類はすべて宣言に載っている"
else
  fail "(b) 振る舞いが返す分類はすべて宣言に載っている" \
       "宣言に無い分類が返された: $(echo "$missing_in_list" | tr '\n' ' ')"
fi

echo "== 8. 起動失敗（スクリプトが実行されない）経路 =="

# **この経路では stdout が一切出ない**＝`report=` を取得できない。
# 「どの exit でも report= を転記する」と書くと、この経路で実行不能な規定になる。
# 以下はその前提（出力が無いこと）を固定し、SKILL 側に別経路の規定があることを要求する。

nonexistent="$tmp/no-such-resolver.sh"
out127="$(bash "$nonexistent" --workspace "$tmp" 2>/dev/null)"; ec127=$?
if [ "$ec127" -eq 127 ]; then pass "スクリプト不在は exit 127"
else fail "スクリプト不在は exit 127" "got=$ec127"; fi
if [ -z "$out127" ]; then pass "スクリプト不在では stdout が空（report= を取得できない）"
else fail "スクリプト不在では stdout が空" "stdout: $out127"; fi

noexec="$tmp/noexec-resolve.sh"
cp "$SCRIPT" "$noexec" && chmod 000 "$noexec"
out126="$("$noexec" --workspace "$tmp" 2>/dev/null)"; ec126=$?
chmod 644 "$noexec"
if [ "$ec126" -eq 126 ]; then pass "実行権限なしの直接起動は exit 126"
else fail "実行権限なしの直接起動は exit 126" "got=$ec126"; fi
if [ -z "$out126" ]; then pass "実行不能では stdout が空（report= を取得できない）"
else fail "実行不能では stdout が空" "stdout: $out126"; fi

echo "== 9. 構造不変条件: スクリプトが返す exit の行の完全性（双方向） =="

listed_exits="$(bash "$SCRIPT" --list-exits 2>/dev/null)"
listed_exits_exit=$?

if [ "$listed_exits_exit" -eq 0 ]; then pass "--list-exits は exit 0 で終了する"
else fail "--list-exits は exit 0 で終了する" "got=$listed_exits_exit"; fi
expected_exits="0
1
2"

if [ "$listed_exits" = "$expected_exits" ]; then
  pass "--list-exits がスクリプト自身の返す exit を宣言順どおり返す"
else
  fail "--list-exits がスクリプト自身の返す exit を宣言順どおり返す" \
       "got:  $(echo "$listed_exits" | tr '\n' ' ')" "want: $(echo "$expected_exits" | tr '\n' ' ')"
fi

n_le="$(printf '%s\n' "$listed_exits" | grep -c . || true)"
if [ "$n_le" -eq 3 ]; then pass "スクリプトが返す exit はちょうど 3 種類（増減したら落ちる）"
else fail "スクリプトが返す exit はちょうど 3 種類" "got=$n_le"; fi

# 126/127 は**シェルが返す**値であってスクリプトの返り値ではない。宣言に混ぜると
# 「スクリプトが report= を出せる exit」の集合が濁るため、宣言には含めない。
case "$listed_exits" in
  *12[67]*) fail "--list-exits に 126/127 を含めない（シェル由来でありスクリプトの返り値ではない）" \
                 "got: $(echo "$listed_exits" | tr '\n' ' ')" ;;
  *) pass "--list-exits に 126/127 を含めない（シェル由来でありスクリプトの返り値ではない）" ;;
esac

obs_exits="$(sort -u "$OBSERVED_EXITS")"
le_sorted="$(printf '%s\n' "$listed_exits" | grep . | sort -u)"

# 空集合で全称条件が空虚に真になるのを防ぐ
n_oe="$(printf '%s\n' "$obs_exits" | grep -c . || true)"
if [ "$n_oe" -eq 3 ]; then
  pass "振る舞いで観測した exit がちょうど 3 種類（空集合で下の比較が空虚に真になるのを防ぐ）"
else
  fail "振る舞いで観測した exit がちょうど 3 種類" "got=$n_oe: $(echo "$obs_exits" | tr '\n' ' ')"
fi

miss_e_behavior="$(comm -23 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$miss_e_behavior" ]; then
  pass "(a) 宣言した exit すべてが振る舞いテストで観測されている"
else
  fail "(a) 宣言した exit すべてが振る舞いテストで観測されている" \
       "観測されなかった: $(echo "$miss_e_behavior" | tr '\n' ' ')"
fi

miss_e_list="$(comm -13 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$miss_e_list" ]; then
  pass "(b) 振る舞いが返す exit はすべて宣言に載っている"
else
  fail "(b) 振る舞いが返す exit はすべて宣言に載っている" \
       "宣言に無い exit が返された: $(echo "$miss_e_list" | tr '\n' ' ')"
fi

echo "== 10. 規定・実装・ドキュメントの結線 =="

assert_contains "SKILL 手順0 が検証器スクリプトを呼ぶ規定を持つ" "$SKILL_MD" 'scripts/priority-policy-resolve.sh'
assert_contains "SKILL 手順0 が exit の読み分けを持つ" "$SKILL_MD" 'exit 2'
assert_contains "SKILL 手順0 が report= の転記を規定する" "$SKILL_MD" 'report='

# 起動失敗経路（stdout が無く report= を取得できない）の規定があること。
# 「どの exit でも report= を転記する」という**無条件**の書き方は、この経路で実行できない。
assert_contains "SKILL 手順0 が起動失敗時（report= が得られない）の規定を持つ" \
  "$SKILL_MD" '起動自体に失敗した場合は `report=` が得られない'
assert_not_contains "SKILL 手順0 に「どの exit でも転記」の無条件規定が残っていない" \
  "$SKILL_MD" '**どの exit でも stdout の `report=` の値をそのまま'

# 第2のリストを作らない: 5 分類の逐語列挙・Git コマンド列を SKILL 側へ残さない
#（正本はスクリプト。SKILL に複製すると必ずずれる）
assert_not_contains "SKILL に git ls-files の逐語手順が残っていない" "$SKILL_MD" 'git ls-files --error-unmatch'
assert_not_contains "SKILL に git diff --cached の逐語手順が残っていない" "$SKILL_MD" 'git diff --cached --quiet -- priority-policy.md'
assert_not_contains "SKILL に git show の逐語手順が残っていない" "$SKILL_MD" 'git show <控えたSHA>:priority-policy.md'
assert_not_contains "SKILL 手順6 に 5 分類の逐語再掲が残っていない" "$SKILL_MD" '不在／未追跡／未コミットの変更あり／Git 検証エラー'

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
