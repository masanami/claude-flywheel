#!/usr/bin/env bash
#
# cycle-commit.test.sh — scripts/cycle-commit.sh のテスト。
#
# 実行: bash scripts/tests/cycle-commit.test.sh
#   - 依存: bash（macOS 標準の 3.2 でも可）・git・ruby（バリデータ）。テストフレームワーク不使用。
#   - すべて一時ディレクトリ内で完結し、リポジトリの状態を変更しない。
#
# 本テストが守る要（手順6 の検算・コミット・事後補記をスクリプトへ移すにあたって）:
#
#   1. **許可パスの正本は 1 つ**。pathspec を `contracts/cycle-commit-paths.txt` の `[commit]`
#      から導いていること。正本に行を足したら**テストを書き換えずに**コミット対象へ現れる
#      ——これが「2 つのリストを同期させる」構造が消えたことの証明になる（PR #96 の P1）。
#   2. **許可パス以外を混入させない**。とくに `priority-policy.md` に未コミット変更があっても
#      サイクルコミットへ入らない（コミット後の `git diff-tree` 検証まで含めて保証する）。
#   3. **未追跡ファイルもステージされる**。`git commit -- <pathspec>` は未追跡を拾わないため、
#      当周新規の journal `.md` やアーカイブ追記が黙って漏れる。`git add` を先に行う理由。
#   4. **fail-closed**。検算が違反（exit 1）ならコミットしない。検査不能（exit 2）と
#      **起動自体の失敗（126/127）は同じ扱い**でコミットを止めない（`priority-policy-resolve.sh`
#      と同じ規律）。
#   5. **異常系の出力契約**。`committed=` を常に出し、呼び出し側が exit code から
#      「コミットされたか」を推測しなくて済むようにする。exit の宣言と振る舞いは
#      双方向＋空集合ガードで固定する。
#   6. **準備の失敗を被検体の欠陥として報告しない**（priority-policy-resolve.test.sh と同じ規律）。

set -u
set -o pipefail

# 外部の Git 設定を遮断する（Git 2.32+）。グローバル／システム設定の core.hooksPath 等で
# 準備コマンドが失敗すると、以後の検査が準備の失敗を被検体の欠陥として報告する。
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPT="$TESTS_DIR/../cycle-commit.sh"
PATHS_FILE="$REPO_ROOT/contracts/cycle-commit-paths.txt"
SKILL_MD="$REPO_ROOT/skills/run-cycle/SKILL.md"

PASS=0
FAIL=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

OBSERVED_EXITS="$tmp/observed-exits.txt"
: > "$OBSERVED_EXITS"

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; shift; for l in "$@"; do echo "       $l"; done; }

setup_fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - テスト準備に失敗: $1"
  echo
  echo "passed: $PASS / failed: $FAIL"
  exit 1
}
setup_reason() { cat "$tmp/setup-error" 2>/dev/null || echo "不明"; }

# run <args...> — スクリプトを実行し RUN_OUT / RUN_ERR / RUN_EXIT へ
run() {
  RUN_OUT="$(bash "$SCRIPT" "$@" 2>"$tmp/stderr")"
  RUN_EXIT=$?
  RUN_ERR="$(cat "$tmp/stderr")"
  echo "$RUN_EXIT" >> "$OBSERVED_EXITS"
}

field() { printf '%s\n' "$RUN_OUT" | sed -n "s/^$1=//p"; }

assert_exit() {
  if [ "$RUN_EXIT" -eq "$2" ]; then pass "$1"
  else fail "$1 (exit: got=$RUN_EXIT want=$2)" "stdout: $RUN_OUT" "stderr: $RUN_ERR"; fi
}
assert_field() {
  got="$(field "$2")"
  if [ "$got" = "$3" ]; then pass "$1"
  else fail "$1 ($2: got='$got' want='$3')" "stdout: $RUN_OUT"; fi
}
assert_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"
  else fail "$1" "'$3' が $2 に見つからない"; fi
}
assert_not_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' が $2 に残っている"
  else pass "$1"; fi
}

# committed_files <ws> — 直近コミットに含まれるファイル一覧
committed_files() { git -C "$1" diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | sort; }

# assert_committed <名前> <ws> <期待するパス>
assert_committed() {
  if committed_files "$2" | grep -qx -- "$3"; then pass "$1"
  else fail "$1" "コミット内容: $(committed_files "$2" | tr '\n' ' ')"; fi
}
assert_not_committed() {
  if committed_files "$2" | grep -qx -- "$3"; then
    fail "$1" "コミット内容: $(committed_files "$2" | tr '\n' ' ')"
  else pass "$1"; fi
}

# --- ワークスペース作成 -------------------------------------------------------

# journal_md <cycle名> — 契約に適合する最小の journal .md
journal_md() {
  printf '# %s サイクルジャーナル\n\n' "$1"
  printf '## 触った課題\n\n- なし\n\n'
  printf '## 委譲\n\n- なし\n\n'
  printf '## 作成した PR・ブランチの URL\n\n- なし\n\n'
  printf '## 承認待ちゲート一覧\n\n- なし\n\n'
  printf '## 判断と根拠\n\n- テスト用\n'
}

# index_line <date> <seq>
index_line() {
  printf '{"date":"%s","seq":%s,"touched_issues":[],"delegations":[],"pr_urls":[],"pending_approvals":[],"decisions":["t"]}\n' "$1" "$2"
}

# ledger_min — 契約に適合する最小の台帳
ledger_min() {
  printf '# 課題台帳（Challenge Ledger）\n\n'
  printf '> テスト用。\n\n---\n\n'
  printf '<!-- 新しい課題は下の記入例をコピーして追記する -->\n\n'
}

# new_ws <名前> — エージェントワークスペースを作る。失敗したら非 0（呼び出し側で setup_fail）
new_ws() {
  ws="$tmp/$1"
  mkdir -p "$ws/journal" "$ws/memory" "$ws/positions" "$ws/.flywheel" \
    || { echo "mkdir: $ws" > "$tmp/setup-error"; return 1; }
  git -C "$ws" init -q                          >/dev/null 2>&1 || { echo "git init"    > "$tmp/setup-error"; return 1; }
  git -C "$ws" config user.email t@example.com  >/dev/null 2>&1 || { echo "cfg email"   > "$tmp/setup-error"; return 1; }
  git -C "$ws" config user.name test            >/dev/null 2>&1 || { echo "cfg name"    > "$tmp/setup-error"; return 1; }
  git -C "$ws" config commit.gpgsign false      >/dev/null 2>&1 || { echo "cfg gpg"     > "$tmp/setup-error"; return 1; }
  git -C "$ws" config core.hooksPath /dev/null  >/dev/null 2>&1 || { echo "cfg hooks"   > "$tmp/setup-error"; return 1; }
  ledger_min > "$ws/challenge-ledger.md"
  printf '# 課題アーカイブ（Challenge Archive）\n\n> テスト用。\n\n---\n\n' > "$ws/challenge-archive.md"
  printf 'active: normal\n' > "$ws/priority-policy.md"
  printf '# memo\n' > "$ws/memory/INDEX.md"
  printf '# position\n' > "$ws/positions/harness.md"
  : > "$ws/journal/index.jsonl"
  printf '.flywheel/\n' > "$ws/.gitignore"
  git -C "$ws" add -A                           >/dev/null 2>&1 || { echo "git add"     > "$tmp/setup-error"; return 1; }
  git -C "$ws" commit -qm init                  >/dev/null 2>&1 || { echo "git commit"  > "$tmp/setup-error"; return 1; }
  git -C "$ws" rev-parse HEAD                   >/dev/null 2>&1 || { echo "HEAD 未作成" > "$tmp/setup-error"; return 1; }
  echo "$ws"
}

# write_cycle <ws> <cycle名> <date> <seq> — 当周の journal 成果物を書く（未追跡になる）
write_cycle() {
  journal_md "$2" > "$1/journal/$2.md"
  index_line "$3" "$4" >> "$1/journal/index.jsonl"
}

echo "== 1. 受理方向（正常系のコミット） =="

ws="$(new_ws accept)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "正常系は exit 0" 0
assert_field "committed=yes" committed yes
assert_field "verify=ok" verify ok
if [ -n "$(field commit_sha)" ]; then pass "commit_sha を出す"; else fail "commit_sha を出す" "stdout: $RUN_OUT"; fi
if [ -n "$(field report)" ]; then pass "report= を出す"; else fail "report= を出す" "stdout: $RUN_OUT"; fi
assert_committed "当周の journal .md がコミットに含まれる（未追跡でもステージされる）" "$ws" "journal/2026-08-27-cycle.md"
assert_committed "journal/index.jsonl の追記がコミットに含まれる" "$ws" "journal/index.jsonl"

echo "== 2. 許可パス以外を混入させない =="

ws="$(new_ws exclude)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf 'active: release-freeze\n' > "$ws/priority-policy.md"   # 未コミット変更を作る
printf 'x\n' > "$ws/repos.tsv"                                  # 許可パス外の未追跡ファイル
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "許可パス外に変更があってもコミットは成功する" 0
assert_not_committed "priority-policy.md がコミットに含まれない" "$ws" "priority-policy.md"
assert_not_committed "許可パス外の未追跡ファイルがコミットに含まれない" "$ws" "repos.tsv"
assert_committed "許可パス内の変更はコミットに含まれる" "$ws" "journal/2026-08-27-cycle.md"
if [ -n "$(git -C "$ws" status --porcelain -- priority-policy.md)" ]; then
  pass "priority-policy.md の変更はワーキングツリーに残る（ステージもされない）"
else
  fail "priority-policy.md の変更はワーキングツリーに残る" "status: $(git -C "$ws" status --porcelain)"
fi

echo "== 3. pathspec は許可パスの正本から導かれる（二重化していないことの証明） =="

# 正本に新しい行を足すと、**スクリプトもテストも書き換えずに**コミット対象へ現れる。
ws="$(new_ws canon)" || setup_fail "$(setup_reason)"
mkdir -p "$ws/newdir"
printf 'x\n' > "$ws/newdir/a.txt"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
custom_paths="$tmp/custom-paths.txt"
{ sed 's/^positions$/positions\nnewdir/' "$PATHS_FILE"; } > "$custom_paths"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --paths-file "$custom_paths"
assert_exit "正本を差し替えたコミットも成功する" 0
assert_committed "正本へ足した newdir/ がコミット対象になる（pathspec を正本から導いている）" "$ws" "newdir/a.txt"

# 逆向き: 正本から外したパスはコミット対象にならない
ws="$(new_ws canon-remove)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf '# changed\n' > "$ws/positions/harness.md"
reduced_paths="$tmp/reduced-paths.txt"
grep -v '^positions$' "$PATHS_FILE" > "$reduced_paths"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --paths-file "$reduced_paths"
assert_exit "正本から外した状態でもコミットは成功する" 0
assert_not_committed "正本から外した positions/ はコミット対象にならない" "$ws" "positions/harness.md"

# 正本が読めない/空なら fail-closed（推測でパスを組み立てない）
ws="$(new_ws canon-broken)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf '[commit]\n' > "$tmp/empty-paths.txt"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --paths-file "$tmp/empty-paths.txt"
assert_field "正本の [commit] が空ならコミットしない" committed no
# 「変更が無いからコミットしなかった」（exit 0）と区別する。理由まで固定しないと、
# 正本のガードを外す変異が「結果的に committed=no」で素通りする。
assert_exit "正本の [commit] が空は exit 2（検査不能）" 2
assert_field "正本が空のときは verify=uncheckable" verify uncheckable
run commit --workspace "$ws" --cycle 2026-08-27-cycle --paths-file "$tmp/no-such-file.txt"
assert_field "正本が読めなければコミットしない" committed no
assert_exit "正本が読めないのは exit 2（検査不能）" 2
assert_field "正本が読めないときは verify=uncheckable" verify uncheckable

# **三者一致**: 正本ファイル ／ noop-check.rb の commit_path= ／ cycle-commit.sh の commit_path=
# が同じ集合であること。「分類（noop-check）と pathspec（cycle-commit）を同じ正本から導く」
# という規定を、散文の約束ではなくテストで固定する（片方だけ実装が変わったら落ちる）。
canon_paths="$(/usr/bin/ruby -e '
sec = nil; out = []
File.readlines(ARGV[0], encoding: "UTF-8").each do |l|
  t = l.strip
  next if t.empty? || t.start_with?("#")
  if t == "[commit]" then sec = :c; next end
  if t == "[exclude]" then sec = :x; next end
  out << t if sec == :c
end
puts out' "$PATHS_FILE" 2>/dev/null)"

ws="$(new_ws threeway)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
cc_paths="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^commit_path=//p')"
nc_paths="$(/usr/bin/ruby "$REPO_ROOT/scripts/noop-check.rb" --workspace "$ws" --cycle 2026-08-27-cycle 2>/dev/null \
            | sed -n 's/^commit_path=//p')"

if [ -n "$canon_paths" ]; then pass "前提確認: 正本の [commit] が空でない"
else fail "前提確認: 正本の [commit] が空でない" "空集合だと下の一致比較が空虚に真になる"; fi
if [ "$cc_paths" = "$canon_paths" ]; then pass "cycle-commit.sh の commit_path= が正本の [commit] と一致する"
else fail "cycle-commit.sh の commit_path= が正本の [commit] と一致する" \
       "script: $(echo "$cc_paths" | tr '\n' ' ')" "file:   $(echo "$canon_paths" | tr '\n' ' ')"; fi
if [ "$nc_paths" = "$canon_paths" ]; then pass "noop-check.rb の commit_path= が正本の [commit] と一致する"
else fail "noop-check.rb の commit_path= が正本の [commit] と一致する" \
       "script: $(echo "$nc_paths" | tr '\n' ' ')" "file:   $(echo "$canon_paths" | tr '\n' ' ')"; fi
if [ "$cc_paths" = "$nc_paths" ]; then pass "分類（noop-check）と pathspec（cycle-commit）が同じ集合を指す"
else fail "分類（noop-check）と pathspec（cycle-commit）が同じ集合を指す" \
       "cycle-commit: $(echo "$cc_paths" | tr '\n' ' ')" "noop-check:   $(echo "$nc_paths" | tr '\n' ' ')"; fi

# **コミット後の内容再検証が効いていること**を、それが唯一の検出者になる経路で確かめる。
# 正本にグロブ（`*.md`）を書くと git の pathspec は広く解釈するが、正本の照合は
# リテラルの前置一致なので食い違う。ここで黙って通すと許可パス外が履歴へ入るため、
# 検出して fail-closed に倒れなければならない（グロブは正本の記法として想定していない、
# ということをテストで固定する意味も持つ）。
ws="$(new_ws postverify)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf 'secret\n' > "$ws/out-of-scope.md"
glob_paths="$tmp/glob-paths.txt"
printf '[commit]\n*.md\njournal\n\n[exclude]\npriority-policy.md\n' > "$glob_paths"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --paths-file "$glob_paths"
assert_exit "pathspec が正本より広く解釈された場合は exit 1（コミット後の再検証が捕まえる）" 1
if printf '%s\n' "$RUN_OUT" | grep -q '^violation=commit-scope:'; then
  pass "許可パス外の混入を violation=commit-scope として報告する"
else
  fail "許可パス外の混入を violation=commit-scope として報告する" "stdout: $RUN_OUT"
fi

echo "== 4. 検算の fail-closed =="

ws="$(new_ws violation)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf '## 余計な見出し\n' >> "$ws/journal/2026-08-27-cycle.md"   # 契約違反を作る
before="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "契約違反は exit 1" 1
assert_field "違反時は committed=no" committed no
assert_field "verify=violation" verify violation
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "違反時に HEAD が進んでいない（コミットしていない）"
else fail "違反時に HEAD が進んでいない" "before=$before after=$(git -C "$ws" rev-parse HEAD)"; fi
if [ -n "$RUN_OUT" ]; then pass "違反内容を stdout に出す（レポートへ転記できる）"; else fail "違反内容を stdout に出す"; fi

echo "== 5. 検査不能（exit 2 / 起動失敗 126・127）はコミットを止めない =="

ws="$(new_ws uncheckable)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle --validator "$tmp/no-such-validator.rb"
assert_exit "バリデータ不在（127）は exit 2" 2
assert_field "検査不能でもコミットする" committed yes
assert_field "verify=uncheckable" verify uncheckable
assert_committed "検査不能でも成果物はコミットされる" "$ws" "journal/2026-08-27-cycle.md"

ws="$(new_ws uncheckable126)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
noexec="$tmp/noexec-validator.rb"
printf '#!/bin/sh\nexit 0\n' > "$noexec"; chmod 000 "$noexec"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --validator "$noexec"
chmod 644 "$noexec"
assert_exit "バリデータが実行不能（126）も exit 2" 2
assert_field "126 でもコミットする（127 と同じ扱い）" committed yes
assert_field "126 も verify=uncheckable" verify uncheckable

ws="$(new_ws uncheckable2)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
stub2="$tmp/stub-exit2.rb"
printf '#!/bin/sh\necho "検査不能: stub" >&2\nexit 2\n' > "$stub2"; chmod +x "$stub2"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --validator "$stub2"
assert_exit "バリデータ自身の exit 2 も exit 2" 2
assert_field "バリデータ exit 2 でもコミットする" committed yes

echo "== 6. 保留分を束ねるコミット（検証範囲の拡大） =="

ws="$(new_ws bundle)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-26-cycle 2026-08-26 1     # 前周（保留された分）
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1     # 当周
run commit --workspace "$ws" --cycle 2026-08-27-cycle \
  --tail 2 --md "journal/2026-08-26-cycle.md" --md "journal/2026-08-27-cycle.md"
assert_exit "保留分を束ねたコミットは成功する" 0
assert_committed "保留分の .md もコミットに含まれる" "$ws" "journal/2026-08-26-cycle.md"
assert_committed "当周の .md もコミットに含まれる" "$ws" "journal/2026-08-27-cycle.md"
msg="$(git -C "$ws" log -1 --format=%B)"
case "$msg" in
  *"cycles: 2026-08-26-cycle, 2026-08-27-cycle"*)
    pass "束ねたサイクル名がコミットメッセージ本文に列挙される" ;;
  *) fail "束ねたサイクル名がコミットメッセージ本文に列挙される" "message: $(printf '%s' "$msg" | tr '\n' '|')" ;;
esac

# --tail の範囲拡大が効いていること: **末尾より前**の index 行を壊す。
# --tail 1 のままなら見逃すが、--tail 2 なら捕まえる（範囲拡大を無視する変異を殺す）。
ws="$(new_ws bundle-tail)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-26-cycle 2026-08-26 1
printf '{"date":"2026-08-26","seq":"NOT-A-NUMBER"}\n' > "$ws/journal/index.jsonl"   # 末尾より前になる行
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
before="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle \
  --tail 2 --md "journal/2026-08-26-cycle.md" --md "journal/2026-08-27-cycle.md"
assert_exit "--tail で広げた範囲の違反を検出する（末尾行だけ見ていたら見逃す）" 1
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "範囲内の違反でも HEAD が進んでいない"
else fail "範囲内の違反でも HEAD が進んでいない"; fi

# 保留分に違反があれば、まとめコミットは行わない（無検証で履歴へ入れない）
ws="$(new_ws bundle-violation)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-26-cycle 2026-08-26 1
printf '## 余計な見出し\n' >> "$ws/journal/2026-08-26-cycle.md"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
before="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle \
  --tail 2 --md "journal/2026-08-26-cycle.md" --md "journal/2026-08-27-cycle.md"
assert_exit "保留分の違反もコミットを止める" 1
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "保留分の違反時に HEAD が進んでいない"
else fail "保留分の違反時に HEAD が進んでいない"; fi

# 単一サイクルの周では cycles: 行を出さない（毎周ノイズにしない）
ws="$(new_ws single)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
msg="$(git -C "$ws" log -1 --format=%B)"
case "$msg" in
  *"cycles:"*) fail "単一サイクルの周は cycles: 行を出さない" "message: $(printf '%s' "$msg" | tr '\n' '|')" ;;
  *) pass "単一サイクルの周は cycles: 行を出さない" ;;
esac

echo "== 7. アーカイブ移動は同一コミット =="

ws="$(new_ws archive)" || setup_fail "$(setup_reason)"
# 前提: 台帳にエントリがある状態をコミット済みにしておく（この後の「削除」を差分にするため）
cat "$REPO_ROOT/contracts/fixtures/ledger/valid/handwritten-and-ingested.md" > "$ws/challenge-ledger.md"
git -C "$ws" add -- challenge-ledger.md >/dev/null 2>&1 \
  && git -C "$ws" commit -qm seed-ledger >/dev/null 2>&1 || setup_fail "台帳の seed に失敗"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
# 即アーカイブ: 台帳からエントリを丸ごと削除し、アーカイブへ追記する（同一コミットに入るべき）
ledger_min > "$ws/challenge-ledger.md"
cat "$REPO_ROOT/contracts/fixtures/ledger/valid/archive.md" > "$ws/challenge-archive.md"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --expect-ids C-004
assert_exit "アーカイブ移動があった周のコミットは成功する" 0
assert_committed "challenge-archive.md への追記が同一コミットに入る" "$ws" "challenge-archive.md"
assert_committed "challenge-ledger.md の削除も同一コミットに入る" "$ws" "challenge-ledger.md"

# --expect-ids が実際にアーカイブの検証へ渡っている（渡っていなければ ID 不一致を検出できない）
ws="$(new_ws archive-mismatch)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
cat "$REPO_ROOT/contracts/fixtures/ledger/valid/archive.md" > "$ws/challenge-archive.md"
before="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --expect-ids C-999
assert_exit "--expect-ids が実状態と一致しなければ exit 1（移動漏れを検出する）" 1
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "ID 不一致時に HEAD が進んでいない"
else fail "ID 不一致時に HEAD が進んでいない"; fi

echo "== 8. --dry-run パリティ =="

ws="$(new_ws dryrun)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
before="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle --dry-run
assert_exit "dry-run は exit 0" 0
assert_field "dry-run では committed=no" committed no
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "dry-run で HEAD が進んでいない"
else fail "dry-run で HEAD が進んでいない"; fi
if [ -z "$(git -C "$ws" diff --cached --name-only)" ]; then pass "dry-run でステージもしない"
else fail "dry-run でステージもしない" "staged: $(git -C "$ws" diff --cached --name-only | tr '\n' ' ')"; fi

echo "== 9. verify サブコマンド（保留する周が使う） =="

ws="$(new_ws verify-ok)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
before="$(git -C "$ws" rev-parse HEAD)"
run verify --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "verify は違反が無ければ exit 0" 0
assert_field "verify はコミットしない" committed no
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "verify で HEAD が進んでいない"
else fail "verify で HEAD が進んでいない"; fi

ws="$(new_ws verify-ng)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
printf '## 余計な見出し\n' >> "$ws/journal/2026-08-27-cycle.md"
run verify --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "verify は違反を exit 1 で返す" 1
assert_field "verify の違反時も committed=no" committed no

echo "== 10. amend サブコマンド（事後補記の再検証＋追加コミット） =="

ws="$(new_ws amend)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "amend の前提: 通常コミットが成功している" 0
first_sha="$(field commit_sha)"
# 事後補記（⑤ 判断と根拠 への追記）
printf -- '- 事後補記: 委譲の実状態を確認\n' >> "$ws/journal/2026-08-27-cycle.md"
# index.jsonl にも未コミット変更を置く。amend が許可パス全体をステージしていると
# これを巻き込んでしまう（1 周 1 行スキーマが壊れる）。
index_line 2026-08-27 2 >> "$ws/journal/index.jsonl"
run amend --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "amend は exit 0" 0
assert_field "amend は committed=yes" committed yes
if [ "$(field commit_sha)" != "$first_sha" ]; then pass "amend は追加コミットを作る（既存コミットを書き換えない）"
else fail "amend は追加コミットを作る" "same sha: $first_sha"; fi
assert_committed "amend のコミットに journal .md が含まれる" "$ws" "journal/2026-08-27-cycle.md"
assert_not_committed "amend は index.jsonl を更新しない（1周1行スキーマを崩さない）" "$ws" "journal/index.jsonl"

# amend も fail-closed
ws="$(new_ws amend-ng)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
printf '## 壊れた見出し\n' >> "$ws/journal/2026-08-27-cycle.md"
before="$(git -C "$ws" rev-parse HEAD)"
run amend --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "amend の再検証が違反なら exit 1" 1
assert_field "amend の違反時は committed=no" committed no
if [ "$(git -C "$ws" rev-parse HEAD)" = "$before" ]; then pass "amend の違反時に HEAD が進んでいない"
else fail "amend の違反時に HEAD が進んでいない"; fi

# amend も許可パス以外を混入させない
ws="$(new_ws amend-exclude)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
printf -- '- 事後補記\n' >> "$ws/journal/2026-08-27-cycle.md"
printf 'active: release-freeze\n' > "$ws/priority-policy.md"
run amend --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "amend も許可パス外があっても成功する" 0
assert_not_committed "amend のコミットに priority-policy.md が含まれない" "$ws" "priority-policy.md"

echo "== 11. 変更が無いときは空コミットを作らない（冪等） =="

# 同じ周に対して 2 回呼んでも 2 個目のコミットを作らない（cron の再実行で空コミットが
# 積み上がらない）。**「変更が無い」と「コミットに失敗した」を exit で区別する**——
# 空コミットのガードを外す変異は git commit の失敗（exit 1）へ落ちるため、
# committed=no だけを見ていると素通りする。
ws="$(new_ws nochange)" || setup_fail "$(setup_reason)"
write_cycle "$ws" 2026-08-27-cycle 2026-08-27 1
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_exit "前提: 1 回目のコミットは成功する" 0
after_first="$(git -C "$ws" rev-parse HEAD)"
run commit --workspace "$ws" --cycle 2026-08-27-cycle
assert_field "2 回目は committed=no" committed no
assert_exit "変更が無い周は exit 0（失敗ではない）" 0
assert_field "変更が無い周は verify=ok" verify ok
if [ "$(git -C "$ws" rev-parse HEAD)" = "$after_first" ]; then pass "空コミットを作らない（HEAD が進まない）"
else fail "空コミットを作らない（HEAD が進まない）"; fi

echo "== 12. 出力契約と exit の行の完全性（双方向） =="

listed_exits="$(bash "$SCRIPT" --list-exits 2>/dev/null)"
listed_exits_exit=$?
expected_exits="0
1
2"
if [ "$listed_exits_exit" -eq 0 ]; then pass "--list-exits は exit 0 で終了する"
else fail "--list-exits は exit 0 で終了する" "got=$listed_exits_exit"; fi
if [ "$listed_exits" = "$expected_exits" ]; then pass "--list-exits が宣言順どおり返す"
else fail "--list-exits が宣言順どおり返す" "got: $(echo "$listed_exits" | tr '\n' ' ')"; fi
n_le="$(printf '%s\n' "$listed_exits" | grep -c . || true)"
if [ "$n_le" -eq 3 ]; then pass "宣言はちょうど 3 種類（増減したら落ちる）"
else fail "宣言はちょうど 3 種類" "got=$n_le"; fi
case "$listed_exits" in
  *12[67]*) fail "--list-exits に 126/127 を含めない（シェル由来）" ;;
  *) pass "--list-exits に 126/127 を含めない（シェル由来）" ;;
esac

obs_exits="$(sort -u "$OBSERVED_EXITS")"
le_sorted="$(printf '%s\n' "$listed_exits" | grep . | sort -u)"
n_oe="$(printf '%s\n' "$obs_exits" | grep -c . || true)"
if [ "$n_oe" -eq 3 ]; then pass "振る舞いで観測した exit がちょうど 3 種類（空集合で空虚に真にならないガード）"
else fail "振る舞いで観測した exit がちょうど 3 種類" "got=$n_oe: $(echo "$obs_exits" | tr '\n' ' ')"; fi

m_b="$(comm -23 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$m_b" ]; then pass "(a) 宣言した exit すべてが振る舞いで観測されている"
else fail "(a) 宣言した exit すべてが振る舞いで観測されている" "未観測: $(echo "$m_b" | tr '\n' ' ')"; fi
m_l="$(comm -13 <(printf '%s\n' "$le_sorted") <(printf '%s\n' "$obs_exits"))"
if [ -z "$m_l" ]; then pass "(b) 振る舞いが返す exit はすべて宣言に載っている"
else fail "(b) 振る舞いが返す exit はすべて宣言に載っている" "宣言外: $(echo "$m_l" | tr '\n' ' ')"; fi

echo "== 13. 規定・実装・ドキュメントの結線 =="

assert_contains "SKILL 手順6 がコミッタを呼ぶ規定を持つ" "$SKILL_MD" 'scripts/cycle-commit.sh'
assert_contains "SKILL 手順6 が committed= の読み取りを規定する" "$SKILL_MD" 'committed='
assert_contains "SKILL 手順6 が起動失敗を検査不能として扱う縮退規定を持つ" "$SKILL_MD" 'exit 126/127'

# 第2のリストを作らない: 許可パスの列挙・git 逐語手順を SKILL 側へ残さない
assert_not_contains "SKILL に git add の逐語手順が残っていない" "$SKILL_MD" 'git add -- <許可パス>'
assert_not_contains "SKILL に diff-tree の逐語手順が残っていない" "$SKILL_MD" 'git diff-tree --no-commit-id --name-only -r'
assert_not_contains "SKILL に許可パスの逐語列挙が残っていない" "$SKILL_MD" '現在は `challenge-ledger.md` / `challenge-archive.md` / `memory` / `journal` / `positions`'
assert_not_contains "SKILL にバリデータ 4 種の引数の使い分けが残っていない" "$SKILL_MD" '--tail 1 --expect-cycle <step 0 で確定した当周のサイクル名>'

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
