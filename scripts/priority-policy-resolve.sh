#!/usr/bin/env bash
#
# priority-policy-resolve.sh — `priority-policy.md` の適用条件を検証し、
# **適用方針モード**を1つの解決結果として返す（読み取り専用）。
#
# run-cycle 手順0 が呼ぶ。手順1（優先度判定）・手順2（着手順の選択）は、本スクリプトが
# 返した解決結果**のみ**を参照し、適用条件を後続手順で再判定しない。
#
# 使い方:
#   scripts/priority-policy-resolve.sh [--workspace <dir>] [--file <name>]
#   scripts/priority-policy-resolve.sh --list-fallbacks | --list-exits
#
#   --workspace       エージェント repo のルート（既定: `.`）。この直下の <file> を見る
#   --file            方針ファイル名（既定: `priority-policy.md`）。vendoring・テスト用の
#                     フックであり、run-cycle は既定のまま呼ぶ
#   --list-fallbacks  フォールバック分類の**宣言**を1行1件で出力して終了（exit 0）。
#                     テストが「宣言」と「振る舞い」の一致を双方向で固定するために使う
#   --list-exits      本スクリプト自身が返す終了コードの**宣言**（0/1/2）。同上。
#                     126/127 は含めない（シェルが返す「起動できなかった」の値であり、
#                     このとき stdout は空＝`report=` を取得できない）
#
# なぜ作業ツリーを読まないか（本スクリプトの要）:
#   検証（追跡済み・差分なし）と読み込みの間に作業ツリーが編集されると、検証を通した
#   内容と実際に適用する内容がずれる。そこで**検証開始前に控えた SHA** を使い
#   `git show <SHA>:<file>` の出力だけを読む。適用内容は常に検証時点の SHA に固定され、
#   後から同じコマンドで再現・監査できる。作業ツリーのファイルは一度も開かない。
#
# 検証の順序（この順でなければならない）:
#   1. `git rev-parse HEAD` で SHA を控える
#   2. `git ls-files --error-unmatch -- <file>`  … 追跡済みか
#   3. `git diff --quiet -- <file>`              … 作業ツリーに差分が無いか
#   4. `git diff --cached --quiet -- <file>`     … ステージに差分が無いか
#   5. すべて成功したときに限り `git show <SHA>:<file>` を解析
#
# 出力（stdout・`key=value` の行。呼び出し側は `report=` をサイクルレポートへ転記する）:
#   resolution=policy|agent-discretion   解決結果の種別（常に出力）
#   mode=<モード名>                       resolution=policy のときのみ
#   fallback=<分類>                       resolution=agent-discretion かつ exit 1 のときのみ
#   active=<検出値>                       fallback=undefined-mode のときのみ。他の分類は
#                                        ファイル内容を読んでいないため該当なし
#   sha=<40hex>                          `git rev-parse HEAD` に成功したときのみ
#   report=<1行>                          サイクルレポートへ転記する文言（**常に出力**）
#
# 終了コード（heartbeat-check.sh / noop-check.rb の3値規約に倣う）:
#   - 0 = 適用方針モードが確定した（`mode=` を使う）
#   - 1 = フォールバック＝エージェント裁量（`fallback=` に下記5分類のいずれか）
#   - 2 = 検査不能（引数エラー・ワークスペース不正）。**呼び出し側はエージェント裁量として
#         扱う**（fail-closed。「検査不能」を「適用できた」と読み替えない）。この場合
#         `fallback=` は出さない＝5分類は exit 1 のときだけ現れる
#   起動自体に失敗した場合（exit 126/127 等＝実行不能）も exit 2 と同じ「検査不能」として
#   扱う（ゲートが効かない環境では従来どおりエージェント裁量へ縮退する）。**ただしこの経路は
#   本スクリプトが1行も実行されないため stdout が空で、`report=` を取得できない**——
#   呼び出し側は「起動できなかった事実と stderr」を自分でレポートへ書く（run-cycle 手順0）。
#
# フォールバック5分類（**この一覧が正本**。増減したら
# scripts/tests/priority-policy-resolve.test.sh の双方向の完全性検査が落ちる）:
#   missing         ファイルが存在しない（後方互換。不在をエラーにしない）
#   untracked       存在するが未追跡
#   dirty           未コミットの変更あり（作業ツリー／ステージ。追跡済みファイルの削除を含む）
#   git-error       上記以外の予期しない非0（Git リポジトリでない・git 不在等）
#   undefined-mode  内容は読めたが `active` に一致するモード定義が無い（タイプミス等）
#
# 解析の規則:
#   - `active` の値 … 行頭が `active:` の行（HTML コメント内は無視）。**ちょうど1行**の
#     ときだけ採用する。0行・2行以上は undefined-mode へ倒す（推測でどれかを選ばない）。
#     方針ファイルの散文は `active:` をバッククォートで囲んで言及するため行頭には来ない。
#   - モード定義 … `### ` の直後のバッククォート内トークン（HTML コメント内・コード
#     フェンス内は無視＝例示を実定義と取り違えない）。
#   - 一致判定は**完全一致**のみ（前方一致・部分一致では受理しない）。
#
# 本スクリプトは書き込みを一切行わない。

set -uo pipefail

USAGE="usage: $0 [--workspace <dir>] [--file <name>] | $0 --list-fallbacks | $0 --list-exits"

# フォールバック分類の宣言（正本）。順序も含めてテストが固定する。
FALLBACKS="missing
untracked
dirty
git-error
undefined-mode"

# 本スクリプト**自身**が返す終了コードの宣言（正本）。テストが宣言と振る舞いの一致を
# 双方向で固定する。**126/127 は含めない**——あれはシェルが「起動できなかった」ことを
# 表すために返す値であり、本スクリプトの返り値ではない。この 3 つが
# 「stdout に `report=` を出せる exit」の集合そのものであり、それ以外の exit で
# 呼び出し側が `report=` を期待してはならない、という境界を担う。
EXITS="0
1
2"

warn() { echo "priority-policy-resolve: $1" >&2; }

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

# emit_policy <mode> <sha>
emit_policy() {
  echo "resolution=policy"
  echo "mode=$1"
  echo "sha=$2"
  echo "report=適用方針モード: $1"
  exit 0
}

# emit_fallback <分類> <report の理由部分> [<active値>] — sha は SHA_OUT（空なら出さない）
emit_fallback() {
  echo "resolution=agent-discretion"
  echo "fallback=$1"
  [ -n "${3:-}" ] && echo "active=$3"
  [ -n "${SHA_OUT:-}" ] && echo "sha=${SHA_OUT}"
  echo "report=適用方針モード: エージェント裁量（$2）"
  exit 1
}

# die <理由> — 検査不能（exit 2）。fallback= は出さない（5分類は exit 1 のみ）
die() {
  warn "検査不能: $1"
  echo "resolution=agent-discretion"
  echo "report=適用方針モード: エージェント裁量（priority-policy.md の検証が実行できなかったため適用せず、エージェント裁量で判定: $1）"
  exit 2
}

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

WORKSPACE="."
POLICY_FILE="priority-policy.md"

while [ $# -gt 0 ]; do
  case "$1" in
    --list-fallbacks) printf '%s\n' "${FALLBACKS}"; exit 0 ;;
    --list-exits)     printf '%s\n' "${EXITS}"; exit 0 ;;
    --workspace) [ $# -ge 2 ] || { warn "${USAGE}"; die "--workspace の値がありません"; }
                 WORKSPACE="$2"; shift 2 ;;
    --file)      [ $# -ge 2 ] || { warn "${USAGE}"; die "--file の値がありません"; }
                 POLICY_FILE="$2"; shift 2 ;;
    -h|--help)   echo "${USAGE}"; exit 0 ;;
    *)           warn "${USAGE}"; die "不明な引数: $1" ;;
  esac
done

[ -n "${WORKSPACE}" ] || die "--workspace が空です"
[ -d "${WORKSPACE}" ] || die "ワークスペースがディレクトリではありません: ${WORKSPACE}"
case "${POLICY_FILE}" in
  ""|/*|*..*) die "--file はワークスペース相対の単純なパスにしてください: ${POLICY_FILE}" ;;
esac

SHA_OUT=""

# ---------------------------------------------------------------------------
# 1. SHA を控える（検証開始より前）
# ---------------------------------------------------------------------------

if ! command -v git >/dev/null 2>&1; then
  emit_fallback git-error \
    "priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定"
fi

SHA="$(git -C "${WORKSPACE}" rev-parse HEAD 2>/dev/null)"
if [ $? -ne 0 ] || [ -z "${SHA}" ]; then
  # Git リポジトリでない／コミットが1つも無い（HEAD 不在）
  emit_fallback git-error \
    "priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定"
fi
SHA_OUT="${SHA}"

# ---------------------------------------------------------------------------
# 2. 追跡済みか（不在／未追跡はファイルの存在有無で区別する）
# ---------------------------------------------------------------------------

git -C "${WORKSPACE}" ls-files --error-unmatch -- "${POLICY_FILE}" >/dev/null 2>&1
st=$?
if [ "${st}" -eq 1 ]; then
  if [ -e "${WORKSPACE}/${POLICY_FILE}" ]; then
    emit_fallback untracked \
      "priority-policy.md が未追跡のため適用せず、エージェント裁量で判定"
  else
    emit_fallback missing \
      "priority-policy.md が存在しないため適用せず、エージェント裁量で判定"
  fi
elif [ "${st}" -ne 0 ]; then
  emit_fallback git-error \
    "priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定"
fi

# ---------------------------------------------------------------------------
# 3-4. 未コミットの変更（作業ツリー／ステージ）。追跡済みファイルの削除もここに落ちる
# ---------------------------------------------------------------------------

for scope in worktree index; do
  if [ "${scope}" = "worktree" ]; then
    git -C "${WORKSPACE}" diff --quiet -- "${POLICY_FILE}" >/dev/null 2>&1
  else
    git -C "${WORKSPACE}" diff --cached --quiet -- "${POLICY_FILE}" >/dev/null 2>&1
  fi
  st=$?
  if [ "${st}" -eq 1 ]; then
    emit_fallback dirty \
      "priority-policy.md に未コミットの変更があるため適用せず、エージェント裁量で判定"
  elif [ "${st}" -ne 0 ]; then
    emit_fallback git-error \
      "priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定"
  fi
done

# ---------------------------------------------------------------------------
# 5. 控えた SHA の内容だけを読む（作業ツリーは開かない）
# ---------------------------------------------------------------------------

CONTENT="$(git -C "${WORKSPACE}" show "${SHA}:${POLICY_FILE}" 2>/dev/null)"
if [ $? -ne 0 ]; then
  emit_fallback git-error \
    "priority-policy.md の検証中に Git 検証エラーが発生したため適用せず、エージェント裁量で判定"
fi

# ---------------------------------------------------------------------------
# 解析: active の値と、モード定義の見出し
# ---------------------------------------------------------------------------

ACTIVE=""
ACTIVE_COUNT=0
MODES=""
in_comment=0
in_fence=0

# bash 3.2 互換: read -r で1行ずつ。コメント／フェンスの状態を1つの走査で持つ。
while IFS= read -r line || [ -n "${line}" ]; do
  # HTML コメントの開始・終了（同一行で閉じる `<!-- ... -->` は状態を変えない）
  if [ "${in_comment}" -eq 0 ]; then
    case "${line}" in
      *'<!--'*)
        case "${line}" in
          *'<!--'*'-->'*) ;;            # 1行で閉じている
          *) in_comment=1; continue ;;  # 複数行コメントの開始行
        esac ;;
    esac
  else
    case "${line}" in
      *'-->'*) in_comment=0 ;;
    esac
    continue
  fi

  # コードフェンス（``` で始まる行）でトグル。フェンス行自体は解析対象にしない
  case "${line}" in
    '```'*) if [ "${in_fence}" -eq 0 ]; then in_fence=1; else in_fence=0; fi; continue ;;
  esac

  # active: は行頭のみ。フェンス内でもよい（雛形は ```text フェンスに置いている）
  case "${line}" in
    'active:'*)
      ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
      v="${line#active:}"
      # 前後の空白（半角スペース・タブ）を落とす
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      ACTIVE="${v}"
      continue ;;
  esac

  # モード定義の見出しはフェンス外のみ（フェンス内は例示）
  [ "${in_fence}" -eq 0 ] || continue
  case "${line}" in
    '### '*)
      rest="${line#\#\#\# }"
      case "${rest}" in
        '`'*)
          rest="${rest#\`}"
          case "${rest}" in
            *'`'*) MODES="${MODES}${rest%%\`*}
" ;;
          esac ;;
      esac ;;
  esac
done <<EOF
${CONTENT}
EOF

# active が 0 行／2 行以上なら推測せず undefined-mode へ倒す
if [ "${ACTIVE_COUNT}" -ne 1 ]; then
  if [ "${ACTIVE_COUNT}" -eq 0 ]; then
    detail="active 行が見つからず"
  else
    detail="active 行が ${ACTIVE_COUNT} 行あり一意に決まらず"
  fi
  emit_fallback undefined-mode \
    "priority-policy.md の ${detail}、一致するモード定義を決められないため適用せず、エージェント裁量で判定"
fi

# 完全一致（前方一致・部分一致では受理しない）
matched=0
while IFS= read -r m; do
  [ -n "${m}" ] || continue
  if [ "${m}" = "${ACTIVE}" ]; then matched=1; break; fi
done <<EOF
${MODES}
EOF

if [ "${matched}" -eq 1 ]; then
  emit_policy "${ACTIVE}" "${SHA}"
fi

emit_fallback undefined-mode \
  "priority-policy.md の active 値 \`${ACTIVE}\` に一致するモード定義が見つからず、エージェント裁量で判定" \
  "${ACTIVE}"
