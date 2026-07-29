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
#                            [--title <text>] [--dry-run] [--workspace <dir>]
#
#   event        cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end
#   --cycle      当周の journal ファイル名 basename（cycle_* 用）
#   --challenge  課題 ID（C-xxx。delegate_* 用）
#   --repo       repos.tsv の <name>
#   --session-id 事前採番した子セッションの UUID（delegate_* 用）
#   --result     結果 1 行（*_end 用。JSON エスケープはスクリプトが行う）
#   --id         adhoc_start / adhoc_end の対応付けキー
#   --title      差し込み作業の 1 行タイトル（adhoc_start 用）
#   --dry-run    何も書かず exit 0（journal と同じパリティ。dry-run は状態を変えないため）
#   --workspace  ワークスペースのルート（既定: .）。<workspace>/.flywheel/runs.jsonl に書く
#
# 使い方（検算・読み取り専用）:
#   scripts/log-run-event.sh check [--workspace <dir>]
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
#   - best-effort: 書き込みイベント（上記「使い方（書き込み）」）は常に exit 0。不正な
#     イベント名・引数エラー・書き込み失敗は stderr に警告し、書かずに正常終了する
#     （観測が制御を阻害しないため）。
#   - **例外**: `check` は書き込みを行わない読み取り・検証コマンドであり、exit code
#     自体が「未終了 start の有無」等のシグナルのため、上記 best-effort 契約（常に exit 0）
#     の対象外とする（未終了があれば exit 1、引数・環境エラーは exit 2 を返す）。
#   - 秘密情報のチェックはしない（書き手の規律。本スクリプトは内容を解釈しない機械）。

set -euo pipefail

USAGE="usage: $0 <event> [--cycle <name>] [--challenge <id>] [--repo <name>] [--session-id <uuid>] [--result <text>] [--id <adhoc-id>] [--title <text>] [--dry-run] [--workspace <dir>]"
USAGE_CHECK="usage: $0 check [--workspace <dir>]"

# 警告を stderr へ出す（best-effort 契約のため、警告してもスクリプトは exit 0 で終える）。
warn() {
  echo "log-run-event: $1" >&2
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
# 検証コマンドにつき、書き込みイベントの best-effort＝常に exit 0 契約の対象外）。
#
# ペアリングは「未終了 start のスタック」で行う（同一キーの start を複数回 push しうる。
# start では既存の未終了 start を上書きしない＝記録漏れで同一キーの start が連続しても
# 古い未終了 start を握りつぶさない。end は同一キーの**最も新しい**未終了 start だけを
# 閉じ、それより古い未終了 start は残す）。
cmd_check() {
  workspace="."
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workspace)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "log-run-event: --workspace に値がありません" >&2
          echo "$USAGE_CHECK" >&2
          exit 2
        fi
        case "$2" in
          --*)
            echo "log-run-event: --workspace に値がありません（次の引数もフラグ）: $1 $2" >&2
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
        echo "log-run-event: check の不明な引数: $1" >&2
        echo "$USAGE_CHECK" >&2
        exit 2
        ;;
    esac
  done

  if [ -z "$workspace" ]; then
    echo "log-run-event: --workspace が空です" >&2
    exit 2
  fi
  if [ ! -d "$workspace" ]; then
    echo "log-run-event: workspace ディレクトリが存在しません: $workspace" >&2
    exit 2
  fi
  if [ ! -x "$workspace" ]; then
    # workspace 自体の実行（走査）権限が無いと、配下の .flywheel/runs.jsonl は存在しても
    # -e/-r が偽になり「ファイル無し」と誤判定しうる（fail-open の温床）。.flywheel と
    # 同様、workspace 自身でも先に区別して弾く。
    echo "log-run-event: workspace ディレクトリを走査できません（権限不足の可能性）: $workspace" >&2
    exit 2
  fi

  flywheel_dir="$workspace/.flywheel"
  if [ -d "$flywheel_dir" ] && [ ! -x "$flywheel_dir" ]; then
    # ディレクトリの実行（走査）権限が無いと、中の runs.jsonl は存在しても -e/-r が
    # 偽になり「ファイル無し」と誤判定しうる（fail-open の温床）。先に区別して弾く。
    echo "log-run-event: .flywheel ディレクトリを走査できません（権限不足の可能性）: $flywheel_dir" >&2
    exit 2
  fi

  file="$flywheel_dir/runs.jsonl"
  if [ ! -e "$file" ]; then
    # .flywheel/runs.jsonl 自体が無い = まだ一度もイベントが書かれていない（初回サイクル等の
    # 正常な状態）ことが多いが、--workspace の指定ミス（無関係な既存ディレクトリを指した等）
    # でも同じ状態になりうる。未終了 start は検出できないため、判別の手掛かりとして警告だけ
    # 出し、契約どおり exit 0 とする（best-effort ではなく検算不能を明示するのみ）。
    echo "log-run-event: runs.jsonl が見つかりません（初回サイクルなら正常。--workspace の指定に誤りがないか確認）: $file" >&2
    exit 0
  fi
  if [ ! -r "$file" ]; then
    echo "log-run-event: runs.jsonl を読み取れません（権限不足の可能性）: $file" >&2
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
  warn "イベント名がありません。書かずに終了します（best-effort）"
  exit 0
fi

EVENT="$1"
shift

if [ "$EVENT" = "check" ]; then
  cmd_check "$@"
fi

case "$EVENT" in
  cycle_start|cycle_end|delegate_start|delegate_end|adhoc_start|adhoc_end) ;;
  *)
    warn "不正なイベント名: ${EVENT}（cycle_start | cycle_end | delegate_start | delegate_end | adhoc_start | adhoc_end のいずれか）。書かずに終了します（best-effort）"
    exit 0
    ;;
esac

CYCLE=""
CHALLENGE=""
REPO=""
SESSION_ID=""
RESULT=""
ADHOC_ID=""
TITLE=""
DRY_RUN=0
WORKSPACE="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      continue
      ;;
    --cycle|--challenge|--repo|--session-id|--result|--id|--title|--workspace)
      if [ "$#" -lt 2 ]; then
        warn "オプションに値がありません: ${1}。書かずに終了します（best-effort）"
        exit 0
      fi
      case "$2" in
        --*)
          warn "オプションに値がありません（次の引数もフラグ）: ${1} ${2}。書かずに終了します（best-effort）"
          exit 0
          ;;
      esac
      ;;
    *)
      warn "不明な引数: ${1}。書かずに終了します（best-effort）"
      warn "$USAGE"
      exit 0
      ;;
  esac
  case "$1" in
    --cycle)      CYCLE="$2" ;;
    --challenge)  CHALLENGE="$2" ;;
    --repo)       REPO="$2" ;;
    --session-id) SESSION_ID="$2" ;;
    --result)     RESULT="$2" ;;
    --id)         ADHOC_ID="$2" ;;
    --title)      TITLE="$2" ;;
    --workspace)  WORKSPACE="$2" ;;
  esac
  shift 2
done

# 空の --workspace は出力先が /.flywheel（ルート直下）に化けるため拒否する。
if [ -z "$WORKSPACE" ]; then
  warn "--workspace が空です。書かずに終了します（best-effort）"
  exit 0
fi

# イベント別の必須フィールド検証（仕様の正本 templates/runtime/README.md のフィールド表に従う）。
# 欠落したまま書くと消費者（観測プレーン）が対応付けできないため、警告して書かずに終了する。
require_nonempty() {
  if [ -z "$1" ]; then
    warn "必須オプションがありません: ${2}（event=${EVENT}）。書かずに終了します（best-effort）"
    exit 0
  fi
}

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
# session_id, id, title, result（与えられたものだけ出力する）。
json="{\"ts\":\"$(json_escape "$TS")\",\"event\":\"$(json_escape "$EVENT")\""
if [ -n "$CYCLE" ]; then      json="${json},\"cycle\":\"$(json_escape "$CYCLE")\""; fi
if [ -n "$CHALLENGE" ]; then  json="${json},\"challenge\":\"$(json_escape "$CHALLENGE")\""; fi
if [ -n "$REPO" ]; then       json="${json},\"repo\":\"$(json_escape "$REPO")\""; fi
if [ -n "$SESSION_ID" ]; then json="${json},\"session_id\":\"$(json_escape "$SESSION_ID")\""; fi
if [ -n "$ADHOC_ID" ]; then   json="${json},\"id\":\"$(json_escape "$ADHOC_ID")\""; fi
if [ -n "$TITLE" ]; then      json="${json},\"title\":\"$(json_escape "$TITLE")\""; fi
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
