#!/usr/bin/env bash
#
# quota-check.sh — 委譲した子セッションの返り値 `result` から**利用枠（レート制限）超過**を
# 判定する（読み取り専用・判定のみ）。
#
# run-cycle 手順3【費用ガード】が呼ぶ。手順3 の表（`subtype` / `is_error` による
# 上限到達・異常終了・正常の判別）と**直交する追加判定**であり、表のどの行に落ちた場合でも
# 本判定を行う。**枠超過と判定したあとの扱い**（再委譲しない・照合して `delegate_end` で
# 閉じる・次アクションへ上げて課題を保留する）は親の行動なので SKILL.md 側に残る。
#
# 使い方:
#   scripts/quota-check.sh < <result の値>            … stdin から読む
#   scripts/quota-check.sh --result-file <path>       … ファイルから読む
#   scripts/quota-check.sh --list-exits | --list-reasons | --list-prefix
#
#   --result-file   `result` の値**だけ**を書いたファイル（JSON ではない）。指定した場合は
#                   stdin を読まない
#   --list-prefix   先頭一致に使う判定文字列の**宣言**（末尾の半角スペースを含む）。
#                   テストが「宣言」と「振る舞い」の一致を固定するために使う
#   --list-reasons  理由分類の**宣言**を1行1件で出力して終了（exit 0）。同上
#   --list-exits    本スクリプト自身が返す終了コードの**宣言**（0/1/2）。同上。
#                   126/127 は含めない（シェルが返す「起動できなかった」の値であり、
#                   このとき stdout は空＝`report=` を取得できない）
#
# **入力をシェル引数で受け取らない**（本スクリプトの要）:
#   `result` は子の**自由記述の最終応答**であり、引用符・バッククォート・改行・`--` で
#   始まる行を含みうる。引数に載せる形にすると呼び出し側が毎回クォートを正しく組み立てねば
#   ならず、失敗すると別のコマンドとして解釈される。入力経路は stdin と `--result-file` の
#   2 つだけにし、いずれも内容を一度も評価しない。
#
# 判定規則（**この 3 つが正本**。散文のままでは解釈が揺れるため移設した）:
#
#   1. **先頭一致であって部分一致ではない**。前後の空白（改行・タブを含む）を除いた**先頭**が
#      `You've hit your ` に一致することだけを見る。`result` は子の自由記述でもあるため、
#      部分一致にすると**この規定自体に言及した正当な報告**（本判定を実装・文書化した課題の
#      完了報告など）を枠超過と誤判定する＝自己言及の誤検知。誤判定は課題を不当に保留し、
#      以後の委譲を止めてしまう。**「いずれかの行の行頭」へ緩めても同じ穴が開く**ため、
#      判定するのは文字列全体の先頭 1 箇所だけにする。
#   2. **枠の名前を限定しない**。`You've hit your ...` は CLI のソースに固定文字列としては
#      存在せず実行時に組み立てられるため、`weekly limit` 決め打ちは他の枠
#      （session / モデル別 / クレジット等）を取りこぼす。一致は上記の**前置き部分まで**で
#      判定し、後続（枠名と `· resets <時刻>`）は解釈せず `limit=` にそのまま出す。
#   3. **判定不能なら「枠超過ではない」側へ倒す**。`result` が無い・空・先頭一致しないは
#      すべてこちら。誤って枠超過と判定すると課題を保留して自走が止まり人手が要るが、
#      誤って通常扱いにしても【委譲結果の照合】で成果の有無が分かり、次の起動で同じ
#      シグナルが再び返るだけで回復できる。**引数エラー等の検査不能（exit 2）・起動失敗
#      （exit 126/127）も呼び出し側は同じ側へ倒す**。
#
# 出力（stdout・`key=value` の行）:
#   verdict=quota-exhausted|not-quota-exhausted   判定（exit 0/1 のとき。exit 2 では出さない）
#   reason=<分類>                                  下記 3 分類（exit 0/1 のときのみ）
#   limit=<1行>                                    verdict=quota-exhausted のときのみ。
#                                                 判定文字列の後続（枠名と reset 時刻）を
#                                                 そのまま。**1 行に収める**（`key=value` の
#                                                 行構造を壊さないため、2 行目以降は落とす）
#   report=<1行>                                   サイクルレポートへ転記する文言（**常に出力**）
#
# 理由分類3つ（**この一覧が正本**。増減したら scripts/tests/quota-check.test.sh の
# 双方向の完全性検査が落ちる）:
#   prefix-match  先頭一致した（＝枠超過）
#   empty         `result` が無い・空・空白のみ（判定材料が無い）
#   no-prefix     先頭一致しない（部分一致・言及・2 行目以降の行頭一致を含む）
#
# 終了コード（priority-policy-resolve.sh / cycle-commit.sh の3値規約に倣う）:
#   - 0 = 枠超過と判定した（`limit=` を次アクションへ転記する）
#   - 1 = 枠超過ではない（判定不能を含む。平常の経路）
#   - 2 = 検査不能（引数エラー・入力を読めない）。**呼び出し側は「枠超過ではない」として
#         扱う**（規則3。「検査不能」を「枠超過」と読み替えない）。この場合 `reason=` は
#         出さない＝3分類は exit 0/1 のときだけ現れる
#   起動自体に失敗した場合（exit 126/127 等＝実行不能）も exit 2 と同じ「検査不能」として
#   扱う。**ただしこの経路は本スクリプトが1行も実行されないため stdout が空で、`report=` を
#   取得できない**——呼び出し側は「起動できなかった事実と stderr」を自分でレポートへ書く
#   （run-cycle 手順3）。
#
# 本スクリプトは書き込みを一切行わない。

set -uo pipefail

USAGE="usage: $0 [--result-file <path>] | $0 --list-exits | --list-reasons | --list-prefix"

# 先頭一致に使う判定文字列（正本）。**末尾の半角スペースまでが判定対象**であり、これが
# 枠名との境界を作る（これを落とすと `You've hit yourself ...` のような別の文が一致しうる）。
PREFIX="You've hit your "

# 理由分類の宣言（正本）。順序も含めてテストが固定する。
REASONS="prefix-match
empty
no-prefix"

# 本スクリプト**自身**が返す終了コードの宣言（正本）。**126/127 は含めない**——あれは
# シェルが「起動できなかった」ことを表すために返す値であり、本スクリプトの返り値ではない。
# この 3 つが「stdout に `report=` を出せる exit」の集合そのもの。
EXITS="0
1
2"

warn() { echo "quota-check: $1" >&2; }

# die <理由> — 検査不能（exit 2）。verdict= / reason= は出さない
die() {
  warn "検査不能: $1"
  echo "report=枠超過判定: 判定を実行できなかったため「枠超過ではない」として扱う（${1}）"
  exit 2
}

# ---------------------------------------------------------------------------
# 引数
# ---------------------------------------------------------------------------

RESULT_FILE=""
RESULT_FILE_GIVEN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --list-prefix)  printf '%s\n' "${PREFIX}"; exit 0 ;;
    --list-reasons) printf '%s\n' "${REASONS}"; exit 0 ;;
    --list-exits)   printf '%s\n' "${EXITS}"; exit 0 ;;
    --result-file)  [ $# -ge 2 ] || { warn "${USAGE}"; die "--result-file の値がありません"; }
                    RESULT_FILE="$2"; RESULT_FILE_GIVEN=yes; shift 2 ;;
    -h|--help)      echo "${USAGE}"; exit 0 ;;
    *)              warn "${USAGE}"; die "不明な引数: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 入力の取得（内容は一度も評価しない）
# ---------------------------------------------------------------------------

if [ -n "${RESULT_FILE_GIVEN}" ]; then
  # 空文字は stdin へ黙って縮退させない（別の入力を読んで判定するのは事故）
  [ -n "${RESULT_FILE}" ] || die "--result-file が空です"
  [ -e "${RESULT_FILE}" ] || die "--result-file が存在しません: ${RESULT_FILE}"
  [ -f "${RESULT_FILE}" ] || die "--result-file が通常ファイルではありません: ${RESULT_FILE}"
  [ -r "${RESULT_FILE}" ] || die "--result-file を読めません: ${RESULT_FILE}"
  if ! INPUT="$(cat -- "${RESULT_FILE}" 2>/dev/null)"; then
    die "--result-file の読み込みに失敗しました: ${RESULT_FILE}"
  fi
else
  # stdin が端末のままだと入力待ちで停止する。自走中に固まらせないよう検査不能で返す。
  [ -t 0 ] && die "stdin が端末です（result の値を stdin へ流すか --result-file を使ってください）"
  # **読み取り失敗を空入力と同一視しない**（`set -o errexit` を使っていないため、
  # ここで拾わないと `cat` の失敗が素通りして `reason=empty`・exit 1 になる）。
  # exit 1 は「枠超過ではない」＝平常であり、呼び出し側は `report=` を転記しない
  # 規定（run-cycle 手順3）なので、**読めなかった事実がサイクルレポートに一切
  # 残らない**。判定材料が空だったのか読めなかったのかは別物であり、後者は
  # 検査不能（exit 2）として観測可能にする。
  if ! INPUT="$(cat)"; then
    die "stdin の読み込みに失敗しました"
  fi
fi

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------

# 前後の空白（半角スペース・タブ・改行）を除く。bash 3.2 互換の前後トリム。
lead="${INPUT%%[![:space:]]*}"
TRIMMED="${INPUT#"${lead}"}"
trail="${TRIMMED##*[![:space:]]}"
TRIMMED="${TRIMMED%"${trail}"}"

# emit <verdict> <reason> <report> — exit は呼び出し側が続けて指定する
emit() {
  echo "verdict=$1"
  echo "reason=$2"
  [ -n "${LIMIT_OUT:-}" ] && echo "limit=${LIMIT_OUT}"
  echo "report=$3"
}

if [ -z "${TRIMMED}" ]; then
  # 規則3: `result` が無い・空・空白のみ＝判定材料が無い → 枠超過ではない側へ
  emit not-quota-exhausted empty \
    "枠超過判定: 枠超過なし（result が空のため判定材料が無く「枠超過ではない」側へ倒した）"
  exit 1
fi

# 規則1: 文字列全体の**先頭**だけを見る（部分一致でも、2 行目以降の行頭一致でもない）
case "${TRIMMED}" in
  "${PREFIX}"*) ;;
  *)
    emit not-quota-exhausted no-prefix "枠超過判定: 枠超過なし"
    exit 1 ;;
esac

# 規則2: 一致は前置き部分まで。後続（枠名・reset 時刻）は解釈せずそのまま出す。
# `key=value` の行構造を壊さないよう 1 行目だけを採り、CR と前後の空白を落とす。
rest="${TRIMMED#"${PREFIX}"}"
rest="${rest%%$'\n'*}"
rest="${rest%$'\r'}"
lead="${rest%%[![:space:]]*}"
rest="${rest#"${lead}"}"
trail="${rest##*[![:space:]]}"
LIMIT_OUT="${rest%"${trail}"}"

if [ -n "${LIMIT_OUT}" ]; then
  emit quota-exhausted prefix-match "要対応（人間）: 利用枠超過（${LIMIT_OUT}）"
else
  # 前置きだけで枠名が続いていない。判定は成立しているので枠超過として扱い、
  # 転記できる枠名が無い事実をレポートに残す（黙って空欄にしない）。
  emit quota-exhausted prefix-match "要対応（人間）: 利用枠超過（枠名・reset 時刻は result に含まれず）"
fi
exit 0
