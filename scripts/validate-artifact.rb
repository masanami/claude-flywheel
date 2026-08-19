#!/usr/bin/ruby
# frozen_string_literal: true

# validate-artifact.rb — run-cycle 成果物のフォーマット契約バリデータ。
#
# run-cycle 手順6が「書き込み後・コミット前」に呼ぶ決定的な検算（Issue #91）。契約の全体像・
# 検査項目の由来（実際に起きた事故）・フィクスチャは contracts/README.md を参照。
#
# 使い方:
#   scripts/validate-artifact.rb <type> <file> [--schema-dir <dir>] [--tail <n>]
#                                [--expect-ids <id,...>] [--expect-cycle <cycle名>]
#                                [--since-last-cycle-start]
#
#   type:
#     ledger         challenge-ledger.md（課題台帳）
#     archive        challenge-archive.md（アーカイブ。検査内容は ledger と同一）
#     journal-md     journal/YYYY-MM-DD-cycle.md（サイクルジャーナル）
#     journal-index  journal/index.jsonl
#     runs           .flywheel/runs.jsonl
#   --schema-dir   JSON Schema の置き場（既定: 本スクリプトからの相対
#                  ../contracts/schemas。vendoring 先で層構成が変わる場合に指定）
#   --tail <n>     jsonl（journal-index / runs）専用: 末尾 n レコード（**非空行基準**。
#                  末尾に空行が続いても実レコードが検証範囲から漏れない）だけを検証する。
#                  あわせて「末尾が非空レコードで終わっている」「非空レコードが n 件以上
#                  存在する」ことも検証する（空行のみの追記・追記の消失を素通しにしない）。
#   --expect-ids <id,...>
#                  ledger / archive 専用: 当該操作で追記したエントリの課題 ID（カンマ区切り）。
#                  末尾 |ids| エントリだけを検証し、かつ**見出し ID 集合が期待と一致する**ことを
#                  証明する（件数・形だけの検査では「台帳から削除したのにアーカイブへ追記
#                  しなかった」場合に古いエントリを検証して exit 0 になるため、同一性まで要求
#                  する）。アーカイブは「ステータス行以外は原文のまま」の履歴＝過去エントリを
#                  修復対象にしないための範囲限定を兼ねる。エントリ不足・ID 不一致は違反。
#                  台帳（現在状態・修復が正規運用）は従来どおりオプション無しの全体検証。
#   --expect-cycle <cycle名>
#                  当周のサイクル名（journal ファイル名 basename。YYYY-MM-DD-cycle[-N]）。
#                  journal-index: 末尾レコードの date・seq がサイクル名から導いた期待値と
#                  一致することを証明する（当周の append の欠落＝前周レコードでの誤証明を防ぐ）。
#                  runs: --since-last-cycle-start のアンカーに**そのサイクル名の cycle_start**を
#                  要求する（前周の stale な cycle_start を受理しない。見つからなければ違反）。
#                  append-only の恒久記録には契約導入前の不正行が残っていることがあり
#                  （既存行の正しさは正本が保証しない・履歴は書き換えない）、全行検証だと
#                  過去行の違反で以後の全周が恒久失敗する。run-cycle 手順6 は「1 周 1 行
#                  append」（journal/README.md）の正本保証に基づき --tail 1 で当周の追記行
#                  のみを検証する。違反の行番号はファイル内の絶対行番号で出力する
#   --since-last-cycle-start
#                  runs 専用: 最後の `cycle_start` 行以降（当周の追記分）だけを検証する。
#                  runs は 1 周の追記行数が可変で --tail の n を静的に決められないため、
#                  当周の開始マーカーからの範囲指定を用意する。cycle_start 行が見つからない
#                  場合は exit 2（当周の開始点を特定できない＝検査不能。0 件と読み替えない）
#
# exit code（3 値。検査不能を正常にも違反にも丸めない）:
#   0 = 違反なし（何も出力しない）
#   1 = 違反あり（stdout に「<file>:<行>: <内容>」を列挙。コミットを止める fail-closed）
#   2 = 検査不能（対象ファイル不在・読み取り不可・不正な引数・スキーマ自体の欠損／破損／
#       未対応キーワード等。stderr に理由。コミットは止めないが報告に残す）
#
# 設計メモ:
#   - cwd 非依存: 対象は引数のパスで受け、スキーマは本スクリプトの位置から解決する。
#   - JSON Schema はサブセットを直接解釈する（検証ロジックとスキーマの二重管理をなくす）。
#     サポート外のキーワードがスキーマに現れたら exit 2（黙って無視すると「検査したつもりで
#     素通し」になるため）。サポート一覧は ASSERTION_KEYWORDS を参照。
#   - 実装言語は /usr/bin/ruby（macOS 標準搭載）: 日本語 markdown と JSON の両方を扱うため、
#     bash 3.2 の全角文字直前の変数展開・${var/…} の多バイト破壊、macOS awk の多バイト等値
#     比較の各罠を回避する。追加インストール不要（CLT も不要）。

require "json"
require "date"

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_UNCHECKABLE = 2

USAGE = "usage: #{$PROGRAM_NAME} <ledger|archive|journal-md|journal-index|runs> <file> [--schema-dir <dir>] [--tail <n>] [--expect-ids <id,...>] [--expect-cycle <cycle名>] [--since-last-cycle-start]"

def uncheckable(msg)
  warn "validate-artifact: 検査不能: #{msg}"
  exit EXIT_UNCHECKABLE
end

# ---------------------------------------------------------------------------
# JSON Schema サブセットの解釈
# ---------------------------------------------------------------------------

# 検証として作用するキーワード（これ以外の未知キーワードは exit 2）。
ASSERTION_KEYWORDS = %w[
  type required properties additionalProperties items enum const pattern
  minLength minimum oneOf format
].freeze

# format は検証として作用させる（JSON Schema 上は注釈が既定だが、本契約では意味検証に使う。
# pattern の桁形状だけでは 2026-99-99T99:99:99+99:99 のような不正成分を受理してしまうため）。
# 対応する値はこの 2 つのみ（他の値は exit 2＝黙って注釈扱いに落とすと「検査したつもりで
# 素通し」になる）。
SUPPORTED_FORMATS = %w[date-time date].freeze
# 注釈キーワード（検証には作用しない。存在を許可するのみ）。
ANNOTATION_KEYWORDS = %w[$schema $id title description $comment examples].freeze

SUPPORTED_TYPES = %w[object array string integer number boolean null].freeze

# スキーマ全体を再帰的に走査し、サポート外キーワード・**キーワード値の形の不正**があれば
# 検査不能で止める。値の形を受理前に検証しないと、不正なスキーマ（例: "required":"date"・
# "oneOf":{}）が空入力で exit 0／非空入力で未捕捉例外の exit 1 になり、検査不能が正常/違反に
# 化ける（3 値 exit 契約の破れ）。
def assert_schema_supported(schema, where)
  uncheckable("スキーマがオブジェクトではありません: #{where}") unless schema.is_a?(Hash)
  schema.each_key do |k|
    next if ASSERTION_KEYWORDS.include?(k) || ANNOTATION_KEYWORDS.include?(k)
    uncheckable("スキーマに未対応のキーワードがあります（黙って無視しない）: #{where}/#{k}")
  end

  if schema.key?("type")
    t = schema["type"]
    unless t.is_a?(String) && SUPPORTED_TYPES.include?(t)
      uncheckable("スキーマの type が未対応の値です（#{SUPPORTED_TYPES.join(' | ')} の文字列 1 つのみ対応）: #{where}/type = #{t.inspect}")
    end
  end
  if schema.key?("required")
    r = schema["required"]
    unless r.is_a?(Array) && r.all? { |e| e.is_a?(String) }
      uncheckable("スキーマの required は文字列の配列が必要です: #{where}/required = #{r.inspect}")
    end
  end
  if schema.key?("properties")
    props = schema["properties"]
    uncheckable("スキーマの properties はオブジェクトが必要です: #{where}/properties") unless props.is_a?(Hash)
    props.each { |name, sub| assert_schema_supported(sub, "#{where}/properties/#{name}") }
  end
  if schema.key?("additionalProperties")
    ap = schema["additionalProperties"]
    unless ap == true || ap == false
      uncheckable("スキーマの additionalProperties は true/false のみ対応です（サブスキーマ形式は未対応）: #{where}/additionalProperties = #{ap.inspect}")
    end
  end
  # items は単一スキーマ形式のみ対応（配列形式は未対応。assert の Hash 検査で弾かれる）
  assert_schema_supported(schema["items"], "#{where}/items") if schema.key?("items")
  if schema.key?("enum")
    e = schema["enum"]
    uncheckable("スキーマの enum は空でない配列が必要です: #{where}/enum = #{e.inspect}") unless e.is_a?(Array) && !e.empty?
  end
  # const は任意の JSON 値を許容（形の制約なし）
  if schema.key?("pattern")
    pat = schema["pattern"]
    uncheckable("スキーマの pattern は文字列が必要です: #{where}/pattern = #{pat.inspect}") unless pat.is_a?(String)
    begin
      Regexp.new(pat)
    rescue RegexpError => e
      uncheckable("スキーマの pattern が正規表現として不正です: #{where}/pattern（#{e.message}）")
    end
  end
  if schema.key?("minLength")
    ml = schema["minLength"]
    uncheckable("スキーマの minLength は 0 以上の整数が必要です: #{where}/minLength = #{ml.inspect}") unless ml.is_a?(Integer) && ml >= 0
  end
  if schema.key?("minimum")
    m = schema["minimum"]
    uncheckable("スキーマの minimum は数値が必要です: #{where}/minimum = #{m.inspect}") unless m.is_a?(Numeric)
  end
  if schema.key?("format")
    f = schema["format"]
    unless f.is_a?(String) && SUPPORTED_FORMATS.include?(f)
      uncheckable("スキーマの format が未対応の値です（#{SUPPORTED_FORMATS.join(' | ')} のみ対応）: #{where}/format = #{f.inspect}")
    end
  end
  if schema.key?("oneOf")
    oo = schema["oneOf"]
    uncheckable("スキーマの oneOf は空でない配列が必要です: #{where}/oneOf = #{oo.inspect}") unless oo.is_a?(Array) && !oo.empty?
    oo.each_with_index { |sub, i| assert_schema_supported(sub, "#{where}/oneOf[#{i}]") }
  end
end

def type_match?(type, value)
  case type
  when "object"  then value.is_a?(Hash)
  when "array"   then value.is_a?(Array)
  when "string"  then value.is_a?(String)
  # Float は有限値のみ整数とみなす（1e999 は JSON として構文的に妥当だが Ruby では
  # Float::INFINITY にパースされ、finite? ガード無しの to_i が FloatDomainError →
  # トップレベル rescue で exit 2 に化ける＝本来 exit 1 のスキーマ違反が warn-only に丸まる）。
  when "integer" then value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.to_i)
  when "number"  then value.is_a?(Numeric)
  when "boolean" then value == true || value == false
  when "null"    then value.nil?
  else
    uncheckable("スキーマに未対応の type があります: #{type}")
  end
end

def type_name(value)
  case value
  when Hash then "object"
  when Array then "array"
  when String then "string"
  when Integer then "integer"
  when Numeric then "number"
  when true, false then "boolean"
  when nil then "null"
  else value.class.to_s
  end
end

# schema に対する value の違反を errors（文字列の配列）へ積む。path は "touched_issues[0].to" 形式。
def validate_value(schema, value, path, errors)
  loc = path.empty? ? "(トップレベル)" : path

  if schema.key?("oneOf")
    branches = schema["oneOf"]
    branch_errors = branches.map do |sub|
      errs = []
      validate_value(sub, value, path, errs)
      errs
    end
    matched = branch_errors.count(&:empty?)
    if matched != 1
      # 分岐は event の const で判別される想定。値の event に対応する分岐があれば
      # その違反を具体的に示し、無ければ分岐不一致として報告する。
      hint = nil
      if value.is_a?(Hash)
        idx = branches.find_index { |b| b.dig("properties", "event", "const") == value["event"] }
        hint = branch_errors[idx] if idx
      end
      if matched > 1
        errors << "#{loc}: oneOf の複数の分岐に一致しました（スキーマの分岐が排他になっていません）"
      elsif hint
        errors.concat(hint)
      else
        errors << "#{loc}: oneOf のどの分岐にも一致しません（event=#{value.is_a?(Hash) ? value['event'].inspect : type_name(value)}）"
      end
    end
    return
  end

  if schema.key?("type") && !type_match?(schema["type"], value)
    errors << "#{loc}: 型が #{schema['type']} ではありません（実際: #{type_name(value)}）"
    return
  end

  if schema.key?("const") && value != schema["const"]
    errors << "#{loc}: #{schema['const'].inspect} ではありません（実際: #{value.inspect}）"
  end

  if schema.key?("enum") && !schema["enum"].include?(value)
    errors << "#{loc}: 許可された語彙ではありません（実際: #{value.inspect} / 許可: #{schema['enum'].join(' | ')}）"
  end

  if value.is_a?(String)
    if schema.key?("pattern") && !(Regexp.new(schema["pattern"]) =~ value)
      errors << "#{loc}: 形式が不正です（実際: #{value.inspect} / 期待パターン: #{schema['pattern']}）"
    end
    if schema.key?("minLength") && value.length < schema["minLength"]
      errors << (schema["minLength"] == 1 ? "#{loc}: 空にできません" : "#{loc}: 長さが #{schema['minLength']} 未満です")
    end
    if schema.key?("format")
      # 暦日・時刻・オフセットの意味的検証。DateTime/Date.iso8601 は存在しない日付
      # （2026-02-31・13 月・非閏年の 02-29）を拒否し、閏年の 02-29 は受理する
      # （Time.iso8601 は不正日を繰り上げ正規化してしまうため使わない）。
      case schema["format"]
      when "date-time"
        # うるう秒 :60 は一律違反にする（ISO 8601 としては正規だが、既知の消費者
        # heartbeat-check.sh が委譲する GNU date -d は :60 を拒否し心拍検知が検査不能に
        # なる〔BSD date は受理＝環境依存〕。契約は全サポート環境の消費者が読める値だけを
        # 受理する。DateTime.iso8601 は :60 を受理・正規化するため明示的に検査する）。
        if value =~ /T[0-9]{2}:[0-9]{2}:60/
          errors << "#{loc}: うるう秒 :60 は不許可です（消費者 heartbeat-check の GNU date が解析できないため。実際: #{value.inspect}）"
        else
          begin
            DateTime.iso8601(value)
          rescue ArgumentError
            errors << "#{loc}: ISO 8601 の日時として不正です（暦日・時刻・オフセットの意味検証。実際: #{value.inspect}）"
          end
        end
      when "date"
        begin
          Date.iso8601(value)
        rescue ArgumentError
          errors << "#{loc}: ISO 8601 の日付として不正です（暦日の意味検証。実際: #{value.inspect}）"
        end
      end
    end
  end

  if value.is_a?(Numeric) && schema.key?("minimum") && value < schema["minimum"]
    errors << "#{loc}: #{schema['minimum']} 以上が必要です（実際: #{value}）"
  end

  if value.is_a?(Hash)
    (schema["required"] || []).each do |k|
      errors << "#{loc}: 必須フィールドがありません: #{k}" unless value.key?(k)
    end
    props = schema["properties"] || {}
    props.each do |k, sub|
      next unless value.key?(k)
      child = path.empty? ? k : "#{path}.#{k}"
      validate_value(sub, value[k], child, errors)
    end
    if schema["additionalProperties"] == false
      unknown = value.keys - props.keys
      unless unknown.empty?
        errors << "#{loc}: スキーマに無いフィールドがあります: #{unknown.join(', ')}"
      end
    end
  end

  if value.is_a?(Array) && schema.key?("items")
    value.each_with_index do |elem, i|
      validate_value(schema["items"], elem, "#{path}[#{i}]", errors)
    end
  end
end

# ---------------------------------------------------------------------------
# 対象ファイルの読み込み
# ---------------------------------------------------------------------------

def read_lines(file)
  uncheckable("ファイルが存在しません: #{file}") unless File.exist?(file)
  uncheckable("ファイルを読み取れません（権限不足の可能性）: #{file}") unless File.readable?(file)
  begin
    content = File.read(file, encoding: "UTF-8")
  rescue SystemCallError => e
    uncheckable("ファイルを読み取れません: #{file}（#{e.message}）")
  end
  uncheckable("UTF-8 として解釈できません（検査を続けられません）: #{file}") unless content.valid_encoding?
  lines = content.split("\n", -1)
  lines.pop if lines.last == "" # 末尾改行によるダミー要素を除く
  lines
end

# ---------------------------------------------------------------------------
# markdown 共通: フェンス・HTML コメントの除外判定
# ---------------------------------------------------------------------------

# 各行に included?（検査対象か）を付ける。docs/challenge-ledger-format.md §台帳を機械で
# 編集するときの規律の awk 検算と同じく ``` フェンスをトグルで除外し、加えて複数行 HTML
# コメント（<!-- が開き -->で閉じるまで）を除外する。同一行で開閉するインラインコメント
# （取り込み元マーカーの <!-- fp:... --> 等）は行ごと検査対象のまま。
def annotate_exclusions(lines)
  in_fence = false
  in_comment = false
  lines.each_with_index.map do |line, idx|
    included = true
    if in_comment
      included = false
      in_comment = false if line.include?("-->")
    elsif line =~ /^```/
      in_fence = !in_fence
      included = false
    elsif in_fence
      included = false
    else
      opens = line.rindex("<!--")
      in_comment = true if opens && !line.index("-->", opens)
      included = false if line.strip.start_with?("<!--") && in_comment
    end
    [idx + 1, line, included]
  end
end

# ---------------------------------------------------------------------------
# ledger / archive
# ---------------------------------------------------------------------------

# 全生成者（手書き＝記入例コピー / ingest-challenges / periodic-audit）のエントリに共通して
# 存在する行だけを必須にする（受理されるべき正規形を拒否しないため。任意フィールド
# 〔完了条件・体感の緊急度・関連サービス・取り込み元・監査元〕は必須にしない）。
# 実測: 実運用ワークスペースの台帳17＋アーカイブ18の全35エントリで全行の存在を確認済み。
LEDGER_REQUIRED_LINES = [
  ["人間記入欄", /^\*\*人間記入欄\*\*/],
  ["起票者 / 起票日", %r{^- 起票者 / 起票日:}],
  ["説明", /^- 説明:/],
  ["分類欄", /^\*\*分類欄/],
  ["担当ポジション", /^- 担当ポジション:/],
  ["優先度", /^- 優先度:/],
  ["ステータス", /^- ステータス:/],
  ["タスク案", /^- タスク案:/],
  ["承認（人間がチェック）", /^- 承認（人間がチェック）:/],
  ["計画を承認チェックボックス", /^ {2}- \[[ xX]\] 計画を承認/],
  ["完了を承認チェックボックス", /^ {2}- \[[ xX]\] 完了を承認/],
  ["備考", /^- 備考:/],
].freeze

def check_ledger(file, expect_ids = nil)
  lines = read_lines(file)
  annotated = annotate_exclusions(lines)
  errors = []

  # エントリ（見出し〜次見出し）へ分割する。見出しはフェンス・コメント内を除外して拾う。
  entries = [] # [heading_lineno, heading_text, included_body_lines]
  annotated.each do |lineno, text, included|
    next unless included
    if text =~ /^### \[/
      entries << [lineno, text, []]
    elsif !entries.empty?
      entries.last[2] << text
    end
  end

  # --expect-ids: アーカイブ追記用の範囲限定＋**同一性の証明**。アーカイブは「ステータス行
  # 以外は原文のまま」の履歴（docs/challenge-ledger-format.md §アーカイブ）であり、契約導入前の
  # 過去エントリを修復対象にしないため、当該操作で追記された末尾 n エントリだけを検証する
  # （台帳は現在状態＝修復が正規運用のため全体検証のまま）。件数・形だけの検査では
  # 「台帳から削除したのにアーカイブへ追記しなかった」場合に古いエントリを検証して exit 0 に
  # なる（課題の消失がコミットされる）ため、呼び出し側が**当周に移動した課題 ID** を渡し、
  # 末尾 n エントリの見出し ID 集合が期待と一致することまで証明する。
  if expect_ids
    n = expect_ids.size
    if entries.size < n
      errors << "1: エントリが #{entries.size} 件しかありません（--expect-ids は #{n} 件の追記エントリを要求: #{expect_ids.join(', ')}。追記が失われていないか確認）"
    end
    target = entries.last([n, entries.size].min)
    actual_ids = target.map { |_, heading, _| heading[/\A### \[([^\]]*)\]/, 1] || "" }
    if actual_ids.sort != expect_ids.sort
      at = target.empty? ? 1 : target.first[0]
      errors << "#{at}: 末尾 #{n} エントリの ID が期待と一致しません（期待: #{expect_ids.sort.join(', ')} / 実際: #{actual_ids.sort.join(', ')}。アーカイブへの追記漏れ・移動対象の取り違えを確認）"
    end
    entries = target
  end

  entries.each do |lineno, heading, body|
    # (1) 見出し直前の空行（事故: アーカイブ追記で空行が欠け、見出しが直前の箇条書きに
    #     吸収される）。直前の物理行が空行であること（ファイル先頭の見出しは対象外）。
    if lineno > 1 && lines[lineno - 2] !~ /^[ \t]*$/
      errors << "#{lineno}: エントリ見出しの直前に空行がありません（直前行: #{lines[lineno - 2][0, 40]}）: #{heading[0, 60]}"
    end

    # (2) 必須フィールド行の存在（事故: エントリの範囲削除が隣接エントリの行を巻き添えにする）。
    LEDGER_REQUIRED_LINES.each do |label, re|
      unless body.any? { |l| re =~ l }
        errors << "#{lineno}: 必須フィールド行がありません: 「#{label}」: #{heading[0, 60]}"
      end
    end

    # (3) 見出しとマーカーの整合（docs/challenge-ledger-format.md §台帳を機械で編集するときの
    #     規律の awk 検算と同じ意味論: 値のあるマーカーはエントリごとに高々 1 つ・両種の同居禁止）。
    t = body.count { |l| l =~ /^- 取り込み元: *[^ ]/ }
    a = body.count { |l| l =~ /^- 監査元: *[^ ]/ }
    if t > 1 || a > 1 || (t > 0 && a > 0)
      errors << "#{lineno}: マーカーの整合違反（取り込み元=#{t} 監査元=#{a}。高々 1 つ・両種の同居禁止）: #{heading[0, 60]}"
    end
  end

  errors
end

# ---------------------------------------------------------------------------
# journal-md
# ---------------------------------------------------------------------------

JOURNAL_SECTIONS = [
  "## 触った課題",
  "## 委譲",
  "## 作成した PR・ブランチの URL",
  "## 承認待ちゲート一覧",
  "## 判断と根拠",
].freeze

def check_journal_md(file)
  annotated = annotate_exclusions(read_lines(file))
  errors = []
  found = [] # [lineno, heading]
  annotated.each do |lineno, text, included|
    next unless included
    found << [lineno, text.rstrip] if text.start_with?("## ")
  end

  found_titles = found.map { |_, h| h }
  (JOURNAL_SECTIONS - found_titles).each do |missing|
    errors << "1: 定型セクションがありません: 「#{missing}」"
  end
  found.each do |lineno, h|
    unless JOURNAL_SECTIONS.include?(h)
      errors << "#{lineno}: 定型 5 セクションに無い見出しです: 「#{h}」"
    end
  end
  known = found_titles.select { |h| JOURNAL_SECTIONS.include?(h) }
  if known.uniq != known
    errors << "1: 定型セクションが重複しています"
  elsif known != (JOURNAL_SECTIONS & known)
    # JOURNAL_SECTIONS & known は「存在するセクションを正規の順に並べたもの」。
    errors << "1: 定型セクションの順序が不正です（#{known.join(' → ')}）"
  end
  errors
end

# ---------------------------------------------------------------------------
# jsonl（journal-index / runs）
# ---------------------------------------------------------------------------

# expect_record: {date:, seq:}（journal-index の同一性証明。末尾レコードが当周の行で
# あること＝当周の append が実際に起きたことを検証する。前周の正常レコードを「検証して
# 正常」と誤証明しないため）。anchor_cycle: runs の同一性証明（そのサイクル名を持つ
# cycle_start をアンカーに要求する。前周の stale な cycle_start を受理しないため）。
def check_jsonl(file, schema, tail = nil, since_cycle_start = false, expect_record = nil, anchor_cycle = nil)
  lines = read_lines(file)

  # 検証範囲の起点（0-based）。既定は全行。--tail / --since-last-cycle-start は
  # append-only の恒久記録に残る契約導入前の不正行で恒久失敗しないための範囲限定
  # （過去行を「検証して正常」と読み替えるのではなく、対象外として扱う）。
  errors = []
  start_idx = 0
  if since_cycle_start
    # 最後の cycle_start 行を探す。他フィールドが壊れた行でも拾えるよう単純な部分一致で判定する
    # （JSON 解析に依存すると、壊れ方によって当周の開始点そのものを見失うため）。
    # 空行は部分一致しえないためアンカーに選ばれず、アンカー以降のレコードは空行の有無に
    # かかわらず全て検証対象になる（下記 --tail のような物理行/論理レコードのずれは生じない）。
    # --expect-cycle 指定時は「そのサイクル名の cycle_start」だけをアンカーとして受理する
    # （当周の cycle_start が best-effort で書かれなかった場合に、前周の stale な cycle_start を
    # 選んで前周分を「当周の検証」として誤証明しないため。見つからなければ違反として報告する）。
    last = nil
    lines.each_with_index do |l, i|
      next unless l.include?('"event":"cycle_start"')
      next if anchor_cycle && !l.include?("\"cycle\":\"#{anchor_cycle}\"")
      last = i
    end
    if last.nil?
      if anchor_cycle
        errors << "1: 期待したサイクル #{anchor_cycle} の cycle_start が見つかりません（当周の開始記録の欠落＝append の失敗、または --expect-cycle の指定誤り）"
        return errors
      end
      uncheckable("--since-last-cycle-start: cycle_start 行が見つからず当周の開始点を特定できません: #{file}")
    end
    start_idx = last
  elsif tail
    # 末尾 n は**非空の JSONL レコード基準**で数える（物理行基準にすると、末尾に空行が
    # 続くファイルで start_idx が空行を指し、検証ループの空行スキップと合わさって実レコードが
    # 一度も検証されずに exit 0 になる＝範囲計算と検証が同じ入力を 2 規則で読むずれ）。
    record_idxs = []
    lines.each_with_index { |l, i| record_idxs << i unless l.strip.empty? }
    # --tail は「直近の追記が n 件の非空レコードとして存在する」ことまで検証する
    # （run-cycle の書き込みゲート用の意味論）:
    # - 末尾が空行のままだと「当周の追記が空行のみ」でも前周の非空レコードを検証して
    #   exit 0 になり、当周レコードの欠落が素通しになるため、末尾の空行は違反にする。
    # - 非空レコードが n 件に満たない場合（空ファイル含む）は「追記されたはずのレコードが
    #   存在しない」＝追記の消失として違反にする。
    if !lines.empty? && lines.last.strip.empty?
      errors << "#{lines.size}: 末尾が空行です（--tail 検証は直近の追記が非空レコードで終わっていることを要求する。空行のみの追記・余分な末尾空行を確認）"
    end
    if record_idxs.size < tail
      errors << "1: 非空レコードが #{record_idxs.size} 件しかありません（--tail #{tail} は直近 #{tail} 件の追記レコードの存在を要求する。追記が失われていないか確認）"
    end
    start_idx = record_idxs.size > tail ? record_idxs[-tail] : 0
  end

  lines.each_with_index do |line, idx|
    next if idx < start_idx
    lineno = idx + 1 # 範囲限定時もファイル内の絶対行番号で報告する
    next if line.strip.empty? # 空行は対応付けの読み手（log-run-event.sh check）と同様に読み飛ばす
    begin
      value = JSON.parse(line)
    rescue JSON::ParserError
      errors << "#{lineno}: JSON として解析できません"
      next
    end
    line_errors = []
    validate_value(schema, value, "", line_errors)
    line_errors.each { |e| errors << "#{lineno}: #{e}" }
  end

  # 同一性の証明: 末尾の非空レコードが「当周の行」（date・seq が期待値と一致）であること。
  # 形の検証だけでは、当周の append が丸ごと欠落していても前周の正常レコードで exit 0 に
  # なり「1 周 1 行」の不変条項をゲートが強制できないため。
  if expect_record
    last_line = nil
    last_no = nil
    lines.each_with_index do |l, i|
      next if l.strip.empty?
      last_line = l
      last_no = i + 1
    end
    if last_line.nil?
      errors << "1: レコードがありません（期待: 当周の行 date=#{expect_record[:date]} seq=#{expect_record[:seq]}）"
    else
      begin
        rec = JSON.parse(last_line)
        if !rec.is_a?(Hash) || rec["date"] != expect_record[:date] || rec["seq"] != expect_record[:seq]
          actual = rec.is_a?(Hash) ? "date=#{rec['date'].inspect} seq=#{rec['seq'].inspect}" : rec.class.to_s
          errors << "#{last_no}: 末尾レコードが当周の行ではありません（期待: date=#{expect_record[:date]} seq=#{expect_record[:seq]} / 実際: #{actual}。当周の append の欠落を確認）"
        end
      rescue JSON::ParserError
        errors << "#{last_no}: 末尾レコードを解析できず、当周の行（date=#{expect_record[:date]} seq=#{expect_record[:seq]}）であることを確認できません"
      end
    end
  end
  errors
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

args = ARGV.dup
schema_dir = File.expand_path("../contracts/schemas", __dir__)
tail = nil
expect_ids = nil
expect_cycle = nil
since_cycle_start = false
positional = []
until args.empty?
  arg = args.shift
  case arg
  when "--schema-dir"
    val = args.shift
    if val.nil? || val.empty? || val.start_with?("--")
      uncheckable("--schema-dir に値がありません\n#{USAGE}")
    end
    schema_dir = val
  when "--tail"
    val = args.shift
    unless val.is_a?(String) && val =~ /\A[0-9]+\z/ && val.to_i >= 1
      uncheckable("--tail は 1 以上の整数が必要です: #{val.inspect}\n#{USAGE}")
    end
    tail = val.to_i
  when "--expect-ids"
    val = args.shift
    if val.nil? || val.start_with?("--")
      uncheckable("--expect-ids に値がありません\n#{USAGE}")
    end
    expect_ids = val.split(",").map(&:strip)
    if expect_ids.empty? || expect_ids.any?(&:empty?)
      uncheckable("--expect-ids はカンマ区切りの課題 ID（1 件以上・空要素なし）が必要です: #{val.inspect}\n#{USAGE}")
    end
  when "--expect-cycle"
    val = args.shift
    if val.nil? || val.empty? || val.start_with?("--")
      uncheckable("--expect-cycle に値がありません\n#{USAGE}")
    end
    expect_cycle = val
  when "--since-last-cycle-start"
    since_cycle_start = true
  when "-h", "--help"
    puts USAGE
    exit EXIT_OK
  when /^--/
    uncheckable("不明な引数: #{arg}\n#{USAGE}")
  else
    positional << arg
  end
end

uncheckable("引数が不足しています\n#{USAGE}") if positional.size < 2
uncheckable("引数が多すぎます: #{positional[2..-1].join(' ')}\n#{USAGE}") if positional.size > 2
type, file = positional

if tail && !%w[journal-index runs].include?(type)
  uncheckable("--tail は jsonl（journal-index / runs）専用です（type=#{type}）\n#{USAGE}")
end
if expect_ids && !%w[ledger archive].include?(type)
  uncheckable("--expect-ids は ledger / archive 専用です（type=#{type}）\n#{USAGE}")
end
if expect_cycle && !%w[journal-index runs].include?(type)
  uncheckable("--expect-cycle は journal-index / runs 専用です（type=#{type}）\n#{USAGE}")
end
if since_cycle_start && type != "runs"
  uncheckable("--since-last-cycle-start は runs 専用です（type=#{type}）\n#{USAGE}")
end
if tail && since_cycle_start
  uncheckable("--tail と --since-last-cycle-start は同時に指定できません\n#{USAGE}")
end
if expect_cycle && type == "runs" && !since_cycle_start
  uncheckable("runs の --expect-cycle は --since-last-cycle-start と併用してください\n#{USAGE}")
end

# journal-index の --expect-cycle はサイクル名（journal ファイル名 basename）から
# 当周レコードの期待値（date・seq）を導く。seq はサフィックス無し＝1・`-N`＝N
# （templates/journal/README.md のスキーマと命名規則に一致）。
expect_record = nil
if expect_cycle && type == "journal-index"
  m = expect_cycle.match(/\A([0-9]{4}-[0-9]{2}-[0-9]{2})-cycle(?:-([0-9]+))?\z/)
  unless m
    uncheckable("--expect-cycle はサイクル名（YYYY-MM-DD-cycle または YYYY-MM-DD-cycle-N）が必要です: #{expect_cycle.inspect}\n#{USAGE}")
  end
  expect_record = { date: m[1], seq: (m[2] || "1").to_i }
end

def load_schema(schema_dir, basename)
  path = File.join(schema_dir, basename)
  uncheckable("スキーマが存在しません: #{path}") unless File.exist?(path)
  begin
    schema = JSON.parse(File.read(path, encoding: "UTF-8"))
  rescue JSON::ParserError, SystemCallError => e
    uncheckable("スキーマを読み込めません: #{path}（#{e.message}）")
  end
  schema
end

errors =
  begin
    case type
    when "ledger", "archive"
      check_ledger(file, expect_ids)
    when "journal-md"
      check_journal_md(file)
    when "journal-index"
      schema = load_schema(schema_dir, "journal-index.schema.json")
      assert_schema_supported(schema, "journal-index.schema.json")
      check_jsonl(file, schema, tail, false, expect_record)
    when "runs"
      schema = load_schema(schema_dir, "runs.schema.json")
      assert_schema_supported(schema, "runs.schema.json")
      check_jsonl(file, schema, tail, since_cycle_start, nil, expect_cycle)
    else
      uncheckable("不明な type: #{type}\n#{USAGE}")
    end
  rescue StandardError => e
    # バックストップ: バリデータ自身の欠陥による未捕捉例外は「検証した結果の違反」ではない。
    # 素の例外終了（exit 1 相当）に任せると違反に化けるため、検査不能へ倒す。
    # （SystemExit は StandardError ではないため、uncheckable 等の正規の exit はここを通らない）
    uncheckable("内部エラー（違反とは判定できないため検査不能に倒す）: #{e.class}: #{e.message}")
  end

if errors.empty?
  exit EXIT_OK
else
  errors.each { |e| puts "#{file}:#{e}" }
  exit EXIT_VIOLATION
end
