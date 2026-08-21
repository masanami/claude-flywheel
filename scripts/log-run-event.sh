#!/usr/bin/env bash
#
# log-run-event.sh — 実行イベントログ（.flywheel/runs.jsonl）へ 1 イベントを append する。
#
# run-cycle / 差し込み作業の親セッションが呼ぶ「書き込みの参照実装」。判断はせず機械的に
# 書くだけ。スキーマの正本は利用先ワークスペースの runtime/README.md「実行イベントログ
# （runs.jsonl）」セクション（本スクリプトと食い違う場合はそちらが正）。
#
# 使い方（書き込み）:
#   scripts/log-run-event.sh <event> [--cycle <name>] [--challenge <id>] [--repo <name>]
#                            [--session-id <uuid>] [--result <text>] [--id <adhoc-id>]
#                            [--title <text>] [--skill <text>] [--dry-run] [--workspace <dir>]
#
#   値の渡し方は `--opt <value>` と `--opt=<value>` の 2 形式。**値が `-` / `--` で始まっても
#   そのまま値として扱う**（`--result "--tail を非空レコード基準へ"` のように、オプション名で
#   始まる 1 行要約は実運用で普通に起きるため。Issue #98）。次の引数をフラグとみなすのは、
#   それが**下記のオプション名と一致する**（`--result` や `--workspace=...` 等）ときだけ。
#   値そのものがオプション名と一致する場合は `--opt=<value>` 形式で明示する
#   （例: `--result=--dry-run`。`=` は最初の 1 個だけが区切りなので値に `=` を含めてよい）。
#
#   event        cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end
#   --cycle      当周の journal ファイル名 basename（cycle_* 用）
#   --challenge  課題 ID（C-xxx。delegate_* 用）
#   --repo       repos.tsv の <name>
#   --session-id 事前採番した子セッションの UUID（delegate_* 用。" や \ は使用不可＝
#                check の対応付けキー抽出（extract_field）の前提を守るための入力制約）
#   --result     結果 1 行（*_end 用。JSON エスケープはスクリプトが行う）
#   --id         adhoc_start / adhoc_end の対応付けキー（" や \ は使用不可。理由は
#                --session-id と同じ）
#   --title      1 行タイトル（adhoc_start 用は必須。delegate_start 用は任意＝委譲内容の
#                1 行要約）
#   --skill      子セッションで実行するスキル名（delegate_start 用。任意。自由テキスト
#                扱いで json_escape 経由のサニタイズを適用する＝--title と同等）
#   --dry-run    何も書かず exit 0（journal と同じパリティ。dry-run は状態を変えないため）
#   --workspace  ワークスペースのルート（既定: .）。<workspace>/.flywheel/runs.jsonl に書く
#
# 使い方（検算・読み取り専用）:
#   scripts/log-run-event.sh check [--workspace <dir>]   （`--workspace=<dir>` 形式も可）
#
#   未終了の delegate_start / adhoc_start（対応する *_end がまだ無いもの）を列挙する。
#   run-cycle step 6 で cycle_end を記録する直前に呼び、未終了があれば実状態に基づく
#   delegate_end（事後補記）で閉じてから cycle_end を打つ（詳細は skills/run-cycle/SKILL.md
#   手順6を参照。未終了 adhoc_start は代筆回収しない＝runtime/README.md の既定。しきい値
#   超過の要確認判定は消費者〔観測プレーン〕側が担い、本スクリプト・run-cycle は毎回
#   報告する義務を負わない）。対応付けの意味論（キー〔delegate_* は session_id・
#   adhoc_* は id〕ごとに start/end を ts 順〔＝行順。append-only のため一致〕にペアリング
#   し、末尾が start のまま残るものを未終了とみなす。resume による同一キーの再登場
#   〔start→end→start〕にも対応する。cycle_start / cycle_end は対象外）の正本は
#   利用先ワークスペースの runtime/README.md「実行イベントログ（runs.jsonl）」節。
#   - runs.jsonl が空 → 未終了なし・exit 0（何も出力しない）。
#   - runs.jsonl が不在 → 未終了なし・exit 0。ただし初回サイクルとの区別が付かないため
#     stderr に確認を促す警告を出す（--workspace の指定ミスの可能性があるため。exit code
#     は 0 のまま＝検算不能を fail-closed〔exit 2〕にはしない設計判断）。
#   - 未終了が無い → exit 0（何も出力しない）。
#   - 未終了がある → 該当行を 1 件 1 行で stdout に列挙し、exit 1。
#   - 引数エラー・環境エラー（不明な引数・値欠落・`--workspace` に不正な値・
#     ワークスペースディレクトリの不在／ワークスペースか `.flywheel` の走査不可・
#     runs.jsonl が読み取り不可）→ stderr に警告し exit 2（`.flywheel` 自体の不在は
#     上記のとおり exit 0＋警告。「未終了あり」= exit 1 と区別するため。
#     cycle-lock.sh の複数終了コード規約に倣う）。
#
# 注意:
#   - ts は自動付与する（ISO 8601・タイムゾーンオフセットはコロン付き +09:00 形式）。
#   - 1 イベント＝1 行の JSON を単一の printf で append する（並行 append でも実用上
#     行が交錯しないため。append 前に mkdir -p .flywheel を行う）。
#   - best-effort（exit 0）: 書き込みイベント（上記「使い方（書き込み）」）の**環境要因の
#     失敗**（日時の取得・`mkdir`・`append` の失敗）は stderr に警告して exit 0 で返す。
#     呼び出し側では回復できず、サイクルを止める理由にならないため（観測が制御を阻害しない）。
#   - **引数エラーは exit 2**（不正なイベント名・不明な引数・値の欠落／曖昧・必須フィールドの
#     欠落・`--session-id` / `--id` の不正文字・空の `--workspace`）。イベントは書かれていない。
#     これらは**呼び出し側の誤りであり呼び出し側で直せる**ため、exit 0 に混ぜると記録の欠落が
#     無言で積み上がる（Issue #98。落ちた `*_end` は後続の `check` で「未終了 `*_start`」と
#     いう実在しない異常になって現れ、本物の記録漏れを埋もれさせる）。best-effort の意図は
#     「観測の失敗が制御を止めないこと」であって「失敗を無言にすること」ではないため、
#     環境要因（exit 0）と呼び出し側の誤り（exit 2）を exit code で分ける。exit 2 でも本
#     スクリプトは何も書かずに終了するだけで、呼び出し側のサイクルを止める副作用は持たない。
#   - `check` は書き込みを行わない読み取り・検証コマンドであり、exit code 自体が
#     「未終了 start の有無」のシグナルのため上記とは別契約（未終了があれば exit 1、
#     引数・環境エラーは exit 2）。
#   - 秘密情報のチェックはしない（書き手の規律。本スクリプトは内容を解釈しない機械）。

set -euo pipefail

USAGE="usage: $0 <event> [--cycle <name>] [--challenge <id>] [--repo <name>] [--session-id <uuid>] [--result <text>] [--id <adhoc-id>] [--title <text>] [--skill <text>] [--dry-run] [--workspace <dir>]"
USAGE_CHECK="usage: $0 check [--workspace <dir>]"

# 警告を stderr へ出す（環境要因の失敗はこれだけを出して exit 0＝best-effort。呼び出し側で
# 直せる引数エラーは arg_error 経由で警告のうえ exit 2 にする）。
warn() {
  echo "log-run-event: $1" >&2
}

# 引数エラー（呼び出し側が直せる誤り）は警告して exit 2 で返す。環境要因の失敗
# （日時取得・mkdir・append）は best-effort の exit 0 のままとし、両者を exit code で
# 区別する（Issue #98。理由は冒頭「注意」）。
arg_error() {
  warn "${1}。イベントは書いていません（引数エラー: exit 2）"
  exit 2
}

# 書き込みパスが認識するオプション名の集合（`--opt=<value>` 形式を含む）。
# 「次の引数は値かフラグか」の判定は**この集合との一致だけ**で行い、先頭が `-` / `--` か
# どうかでは判定しない（`--result "--tail を非空レコード基準へ"` のような値を落とさないため）。
is_known_option() {
  case "$1" in
    --cycle|--challenge|--repo|--session-id|--result|--id|--title|--skill|--workspace|--dry-run)
      return 0 ;;
    --cycle=*|--challenge=*|--repo=*|--session-id=*|--result=*|--id=*|--title=*|--skill=*|--workspace=*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# 値を JSON 文字列として安全にする（バックスラッシュ→\\、二重引用符→\"、
# 制御文字・改行→スペース）。自由テキスト（--result / --title）向けだが全フィールドに適用する。
json_escape() {
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # 制御文字（改行含む）はスペースへ潰す（1 イベント＝1 行の不変条件を守るため）。
  # tr の八進レンジは GNU/BSD 双方で動く。末尾の改行もスペースになるため
  # コマンド置換で失われない。
  s="$(printf '%s' "$s" | tr '\000-\037\177' ' ')"
  printf '%s' "$s"
}

# JSON 1 行 ($1) から "<field>":"<value>" の値を抜き出す（本スクリプト自身が書く
# 単純な平坦フィールドが対象。session_id/id/event は値にエスケープが要る文字を含まない
# 前提の読み取り専用ヘルパー）。fork を伴う外部プロセス（sed 等）を使わず bash 組み込みの
# パラメータ展開のみで行う（runs.jsonl は肥大化対策を入れず単調増加する設計〔YAGNI〕のため、
# 行ごとに fork するとホットパスのコストが行数に比例して悪化するのを避ける）。
# 戻り値ではなくグローバル変数 FIELD_VALUE への代入で結果を返す（呼び出し側で
# `x="$(extract_field ...)"` のようにコマンド置換すると、それ自体が1行ごとにサブシェルを
# fork してしまい fork 除去の意味が無くなるため）。抜き出せなければ空文字を代入する。
extract_field() {
  needle="\"$2\":\""
  rest="${1#*"$needle"}"
  if [ "$rest" = "$1" ]; then
    FIELD_VALUE=""
    return
  fi
  FIELD_VALUE="${rest%%\"*}"
}

# check サブコマンド本体: runs.jsonl を ts 順（＝行順。append-only のため一致）に走査し、
# delegate_*/adhoc_* をキー（session_id / id）ごとに start/end でペアリングする。
# 末尾が start のまま閉じられていないキーが残れば、その行を列挙して exit 1（読み取り専用の
# 検証コマンドにつき、書き込みイベントの exit code 契約とは別体系）。
#
# ペアリングは「未終了 start のスタック」で行う（同一キーの start を複数回 push しうる。
# start では既存の未終了 start を上書きしない＝記録漏れで同一キーの start が連続しても
# 古い未終了 start を握りつぶさない。end は同一キーの**最も新しい**未終了 start だけを
# 閉じ、それより古い未終了 start は残す）。
cmd_check() {
  workspace="."
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workspace=*)
        # `--workspace=<dir>` 形式（値がオプション名と一致する場合の明示手段。書き込みパスと同形）。
        workspace="${1#*=}"
        if [ -z "$workspace" ]; then
          warn "--workspace に値がありません: $1"
          echo "$USAGE_CHECK" >&2
          exit 2
        fi
        shift
        ;;
      --workspace)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          warn "--workspace に値がありません"
          echo "$USAGE_CHECK" >&2
          exit 2
        fi
        # 次の引数をフラグとみなすのは check が認識するオプション名と一致するときだけ
        # （先頭が `-` かどうかでは判定しない＝`-` で始まるディレクトリ名を落とさない。Issue #98）。
        case "$2" in
          --workspace|--workspace=*|-h|--help)
            warn "--workspace の値がオプション名と一致するため、値か指定漏れか判別できません: $1 $2（値として渡すなら --workspace=$2 形式を使う）"
            echo "$USAGE_CHECK" >&2
            exit 2
            ;;
        esac
        workspace="$2"
        shift 2
        ;;
      -h|--help)
        echo "$USAGE_CHECK"
        exit 0
        ;;
      *)
        warn "check の不明な引数: $1"
        echo "$USAGE_CHECK" >&2
        exit 2
        ;;
    esac
  done

  if [ -z "$workspace" ]; then
    warn "--workspace が空です"
    exit 2
  fi
  if [ ! -d "$workspace" ]; then
    warn "workspace ディレクトリが存在しません: $workspace"
    exit 2
  fi
  if [ ! -x "$workspace" ]; then
    # workspace 自体の実行（走査）権限が無いと、配下の .flywheel/runs.jsonl は存在しても
    # -e/-r が偽になり「ファイル無し」と誤判定しうる（fail-open の温床）。.flywheel と
    # 同様、workspace 自身でも先に区別して弾く。
    warn "workspace ディレクトリを走査できません（権限不足の可能性）: $workspace"
    exit 2
  fi

  flywheel_dir="$workspace/.flywheel"
  if [ -d "$flywheel_dir" ] && [ ! -x "$flywheel_dir" ]; then
    # ディレクトリの実行（走査）権限が無いと、中の runs.jsonl は存在しても -e/-r が
    # 偽になり「ファイル無し」と誤判定しうる（fail-open の温床）。先に区別して弾く。
    warn ".flywheel ディレクトリを走査できません（権限不足の可能性）: $flywheel_dir"
    exit 2
  fi

  file="$flywheel_dir/runs.jsonl"
  if [ ! -e "$file" ]; then
    # .flywheel/runs.jsonl 自体が無い = まだ一度もイベントが書かれていない（初回サイクル等の
    # 正常な状態）ことが多いが、--workspace の指定ミス（無関係な既存ディレクトリを指した等）
    # でも同じ状態になりうる。未終了 start は検出できないため、判別の手掛かりとして警告だけ
    # 出し、契約どおり exit 0 とする（best-effort ではなく検算不能を明示するのみ）。
    warn "runs.jsonl が見つかりません（初回サイクルなら正常。--workspace の指定に誤りがないか確認）: $file"
    exit 0
  fi
  if [ ! -r "$file" ]; then
    warn "runs.jsonl を読み取れません（権限不足の可能性）: $file"
    exit 2
  fi
  if [ ! -s "$file" ]; then
    # 空ファイル = 未終了 start は無い。
    exit 0
  fi

  # 未終了 start のスタック（同一キーの多重 start を保持できるよう、start は常に追加する）。
  open_keys=()
  open_lines=()

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    extract_field "$line" "event"
    event="$FIELD_VALUE"
    key=""
    case "$event" in
      delegate_start|delegate_end)
        extract_field "$line" "session_id"
        sid="$FIELD_VALUE"
        [ -z "$sid" ] && continue
        key="d:$sid"
        ;;
      adhoc_start|adhoc_end)
        extract_field "$line" "id"
        aid="$FIELD_VALUE"
        [ -z "$aid" ] && continue
        key="a:$aid"
        ;;
      *)
        continue
        ;;
    esac

    case "$event" in
      delegate_start|adhoc_start)
        # 既存の未終了 start を上書きせず、常に新しいエントリとして積む。
        open_keys+=("$key")
        open_lines+=("$line")
        ;;
      delegate_end|adhoc_end)
        # 同一キーの最も新しい（インデックスが最大の）未終了 start だけを閉じる。
        idx=-1
        for i in "${!open_keys[@]}"; do
          if [ "${open_keys[i]}" = "$key" ]; then
            idx=$i
          fi
        done
        if [ "$idx" -ge 0 ]; then
          unset 'open_keys[idx]'
          unset 'open_lines[idx]'
        fi
        ;;
    esac
  done < "$file"

  if [ "${#open_keys[@]}" -eq 0 ]; then
    exit 0
  fi

  for line in "${open_lines[@]+"${open_lines[@]}"}"; do
    printf '%s\n' "$line"
  done
  exit 1
}

if [ "$#" -ge 1 ]; then
  case "$1" in
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
  esac
fi

if [ "$#" -lt 1 ]; then
  warn "$USAGE"
  arg_error "イベント名がありません"
fi

EVENT="$1"
shift

if [ "$EVENT" = "check" ]; then
  cmd_check "$@"
fi

case "$EVENT" in
  cycle_start|cycle_end|delegate_start|delegate_end|adhoc_start|adhoc_end) ;;
  *)
    arg_error "不正なイベント名: ${EVENT}（cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end のいずれか）"
    ;;
esac

CYCLE=""
CHALLENGE=""
REPO=""
SESSION_ID=""
RESULT=""
ADHOC_ID=""
TITLE=""
SKILL=""
DRY_RUN=0
WORKSPACE="."

# OPT / OPT_VAL に「オプション名」と「その値」を確定させてから代入する
# （`--opt <value>` と `--opt=<value>` の 2 形式を同じ経路へ合流させる）。
OPT=""
OPT_VAL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cycle=*|--challenge=*|--repo=*|--session-id=*|--result=*|--id=*|--title=*|--skill=*|--workspace=*)
      # `--opt=<value>` 形式。最初の `=` だけが区切り（値に `=` を含めてよい）。
      # 値がオプション名と一致する場合（`--result=--dry-run` 等）の明示手段でもある。
      OPT="${1%%=*}"
      OPT_VAL="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      continue
      ;;
    --cycle|--challenge|--repo|--session-id|--result|--id|--title|--skill|--workspace)
      OPT="$1"
      if [ "$#" -lt 2 ]; then
        arg_error "オプションに値がありません: ${OPT}"
      fi
      # 次の引数をフラグとみなすのは、それが認識済みオプション名と一致するときだけ。
      # 先頭が `-` / `--` かどうかでは判定しない（Issue #98）。一致して曖昧になった場合は
      # 黙って捨てず、`--opt=<value>` 形式への書き換えを促して exit 2 で知らせる。
      if is_known_option "$2"; then
        arg_error "${OPT} の値がオプション名と一致するため、値か指定漏れか判別できません: ${OPT} ${2}（値として渡すなら ${OPT}=${2} 形式を使う）"
      fi
      OPT_VAL="$2"
      shift 2
      ;;
    *)
      warn "$USAGE"
      arg_error "不明な引数: ${1}"
      ;;
  esac

  case "$OPT" in
    --cycle)      CYCLE="$OPT_VAL" ;;
    --challenge)  CHALLENGE="$OPT_VAL" ;;
    --repo)       REPO="$OPT_VAL" ;;
    --session-id) SESSION_ID="$OPT_VAL" ;;
    --result)     RESULT="$OPT_VAL" ;;
    --id)         ADHOC_ID="$OPT_VAL" ;;
    --title)      TITLE="$OPT_VAL" ;;
    --skill)      SKILL="$OPT_VAL" ;;
    --workspace)  WORKSPACE="$OPT_VAL" ;;
  esac
done

# 空の --workspace は出力先が /.flywheel（ルート直下）に化けるため拒否する。
if [ -z "$WORKSPACE" ]; then
  arg_error "--workspace が空です"
fi

# イベント別の必須フィールド検証（仕様の正本 templates/runtime/README.md のフィールド表に従う）。
# 欠落したまま書くと消費者（観測プレーン）が対応付けできないため、警告して書かずに終了する
# （呼び出し側で直せる誤り＝引数エラーにつき exit 2）。
require_nonempty() {
  if [ -z "$1" ]; then
    arg_error "必須オプションがありません: ${2}（event=${EVENT}）"
  fi
}

# --session-id / --id は check サブコマンドの extract_field（"<field>":"<value>" の
# 未エスケープ " 区切り前提で読む対応付けキー）で読み戻されるため、" や \ を含むと
# check が誤ったキーとして扱う（json_escape は runs.jsonl 自体は壊さないが、
# extract_field 側の前提までは救わない）。書き込み時点で拒否する
# （他の必須フィールド検証と同じ扱い＝呼び出し側で直せる引数エラーにつき exit 2）。
reject_unsafe_key() {
  case "$1" in
    *'"'*|*\\*)
      arg_error "${2} に \" または \\ を含めることはできません: ${1}（event=${EVENT}）"
      ;;
  esac
}

reject_unsafe_key "$SESSION_ID" "--session-id"
reject_unsafe_key "$ADHOC_ID" "--id"

case "$EVENT" in
  cycle_start)
    require_nonempty "$CYCLE" "--cycle" ;;
  cycle_end)
    require_nonempty "$CYCLE" "--cycle"
    require_nonempty "$RESULT" "--result" ;;
  delegate_start)
    require_nonempty "$CHALLENGE" "--challenge"
    require_nonempty "$REPO" "--repo"
    require_nonempty "$SESSION_ID" "--session-id" ;;
  delegate_end)
    require_nonempty "$CHALLENGE" "--challenge"
    require_nonempty "$REPO" "--repo"
    require_nonempty "$SESSION_ID" "--session-id"
    require_nonempty "$RESULT" "--result" ;;
  adhoc_start)
    require_nonempty "$ADHOC_ID" "--id"
    require_nonempty "$TITLE" "--title" ;;
  adhoc_end)
    require_nonempty "$ADHOC_ID" "--id"
    require_nonempty "$RESULT" "--result" ;;
esac

# ts の自動付与。date +%z は +0900 形式を返すため、末尾 2 桁の前にコロンを挿入して
# +09:00 形式（ISO 8601）へ変換する（GNU/BSD 双方で動く %z のみ使用）。
if ! ts_raw="$(date +%Y-%m-%dT%H:%M:%S%z)"; then
  warn "日時の取得に失敗しました。書かずに終了します（best-effort）"
  exit 0
fi
TS="${ts_raw%??}:${ts_raw#"${ts_raw%??}"}"

# 1 行 JSON を組み立てる。フィールド順は ts, event, cycle, challenge, repo,
# session_id, id, title, skill, result（与えられたものだけ出力する）。
json="{\"ts\":\"$(json_escape "$TS")\",\"event\":\"$(json_escape "$EVENT")\""
if [ -n "$CYCLE" ]; then      json="${json},\"cycle\":\"$(json_escape "$CYCLE")\""; fi
if [ -n "$CHALLENGE" ]; then  json="${json},\"challenge\":\"$(json_escape "$CHALLENGE")\""; fi
if [ -n "$REPO" ]; then       json="${json},\"repo\":\"$(json_escape "$REPO")\""; fi
if [ -n "$SESSION_ID" ]; then json="${json},\"session_id\":\"$(json_escape "$SESSION_ID")\""; fi
if [ -n "$ADHOC_ID" ]; then   json="${json},\"id\":\"$(json_escape "$ADHOC_ID")\""; fi
if [ -n "$TITLE" ]; then      json="${json},\"title\":\"$(json_escape "$TITLE")\""; fi
if [ -n "$SKILL" ]; then      json="${json},\"skill\":\"$(json_escape "$SKILL")\""; fi
if [ -n "$RESULT" ]; then     json="${json},\"result\":\"$(json_escape "$RESULT")\""; fi
json="${json}}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "log-run-event: dry-run（書き込みなし）: $json"
  exit 0
fi

# append 前にディレクトリを確保し、1 行を単一の printf で append する。
# 失敗しても警告のみで exit 0（best-effort。set -e を壊さないよう条件文の中で評価する）。
outdir="$WORKSPACE/.flywheel"
if ! mkdir -p "$outdir" 2>/dev/null; then
  warn "ディレクトリを作成できません: ${outdir}。書かずに終了します（best-effort）"
  exit 0
fi
if ! printf '%s\n' "$json" >> "$outdir/runs.jsonl" 2>/dev/null; then
  warn "append に失敗しました: $outdir/runs.jsonl（best-effort につき正常終了します）"
  exit 0
fi

exit 0
