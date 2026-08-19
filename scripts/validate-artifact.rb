#!/usr/bin/ruby
# frozen_string_literal: true

# validate-artifact.rb — run-cycle 成果物のフォーマット契約バリデータ。
#
# run-cycle 手順6が「書き込み後・コミット前」に呼ぶ決定的な検算（Issue #91）。契約の全体像・
# 検査項目の由来（実際に起きた事故）・フィクスチャは contracts/README.md を参照。
#
# 使い方:
#   scripts/validate-artifact.rb <type> <file> [--schema-dir <dir>]
#
#   type:
#     ledger         challenge-ledger.md（課題台帳）
#     archive        challenge-archive.md（アーカイブ。検査内容は ledger と同一）
#     journal-md     journal/YYYY-MM-DD-cycle.md（サイクルジャーナル）
#     journal-index  journal/index.jsonl
#     runs           .flywheel/runs.jsonl
#   --schema-dir   JSON Schema の置き場（既定: 本スクリプトからの相対
#                  ../contracts/schemas。vendoring 先で層構成が変わる場合に指定）
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

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_UNCHECKABLE = 2

USAGE = "usage: #{$PROGRAM_NAME} <ledger|archive|journal-md|journal-index|runs> <file> [--schema-dir <dir>]"

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
  minLength minimum oneOf
].freeze
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
  when "integer" then value.is_a?(Integer) || (value.is_a?(Float) && value == value.to_i)
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

def check_ledger(file)
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

def check_jsonl(file, schema)
  errors = []
  read_lines(file).each_with_index do |line, idx|
    lineno = idx + 1
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
  errors
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

args = ARGV.dup
schema_dir = File.expand_path("../contracts/schemas", __dir__)
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
      check_ledger(file)
    when "journal-md"
      check_journal_md(file)
    when "journal-index"
      schema = load_schema(schema_dir, "journal-index.schema.json")
      assert_schema_supported(schema, "journal-index.schema.json")
      check_jsonl(file, schema)
    when "runs"
      schema = load_schema(schema_dir, "runs.schema.json")
      assert_schema_supported(schema, "runs.schema.json")
      check_jsonl(file, schema)
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
