#!/usr/bin/env bash
#
# codex-plugin.test.sh — Codex plugin manifest と repo-local skill discovery の契約テスト。
#
# 実行: bash scripts/tests/codex-plugin.test.sh
#   - 依存: bash / ruby（JSON は標準ライブラリのみ）
#   - marketplace や個人設定は変更しない。

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
CODEX_MANIFEST="$REPO_ROOT/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
DISCOVERY_LINK="$REPO_ROOT/.agents/skills"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "ok   - $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
}

if ruby -rjson -e '
  manifest = JSON.parse(File.read(ARGV.fetch(0)))
  required = %w[name version description skills interface]
  abort "missing top-level field" unless required.all? { |key| manifest.key?(key) }
  abort "wrong name" unless manifest["name"] == "claude-flywheel"
  abort "wrong skills path" unless manifest["skills"] == "./skills/"
  interface = manifest.fetch("interface")
  required_interface = %w[displayName shortDescription longDescription developerName category capabilities defaultPrompt]
  abort "missing interface field" unless required_interface.all? { |key| interface.key?(key) }
' "$CODEX_MANIFEST"; then
  ok "Codex plugin manifest の必須フィールドと skills path"
else
  fail "Codex plugin manifest の必須フィールドと skills path"
fi

if ruby -rjson -e '
  codex = JSON.parse(File.read(ARGV.fetch(0)))
  claude = JSON.parse(File.read(ARGV.fetch(1)))
  abort "name drift" unless codex["name"] == claude["name"]
  abort "version drift" unless codex["version"] == claude["version"]
' "$CODEX_MANIFEST" "$CLAUDE_MANIFEST"; then
  ok "Claude/Codex manifest の name と version が一致"
else
  fail "Claude/Codex manifest の name と version が一致"
fi

if [ -L "$DISCOVERY_LINK" ] && [ "$(readlink "$DISCOVERY_LINK")" = "../skills" ]; then
  ok ".agents/skills は正本 skills/ への相対 symlink"
else
  fail ".agents/skills は正本 skills/ への相対 symlink"
fi

expected_skills="agent-memory bootstrap-domain-map flywheel-init ingest-challenges reflect run-cycle start-day"
actual_skills=""
for skill_file in "$REPO_ROOT"/skills/*/SKILL.md; do
  skill_dir="$(basename "$(dirname "$skill_file")")"
  name="$(sed -n 's/^name:[[:space:]]*//p' "$skill_file" | head -n 1)"
  description="$(sed -n 's/^description:[[:space:]]*//p' "$skill_file" | head -n 1)"
  case "$description" in
    *"<"*|*">"*) description_valid=0 ;;
    *) description_valid=1 ;;
  esac
  if [ "$name" != "$skill_dir" ] || [ -z "$description" ] || [ "$description_valid" -ne 1 ]; then
    fail "skill metadata: $skill_dir"
    continue
  fi
  actual_skills="${actual_skills}${actual_skills:+ }${skill_dir}"
done

if [ "$actual_skills" = "$expected_skills" ]; then
  ok "既存7 skills の name/description と discovery 対象"
else
  fail "既存7 skills の name/description と discovery 対象 (got: $actual_skills)"
fi

echo
echo "passed: $PASS / failed: $FAIL"
[ "$FAIL" -eq 0 ]
