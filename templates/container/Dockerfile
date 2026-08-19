# claude-flywheel コンテナ隔離モード（execution_mode: container）のベースイメージ雛形。
#
# start-day 層（その日のエージェントセッション全体）をこのイメージで包む。
# クリティカル設計決定（Issue #54・単一イメージへの集約）に基づき、対象リポジトリ群
# （.flywheel/repos/ 配下）のツールチェーンは 1 イメージに集約する方針。
# ここに含めるのは Claude Code CLI と、run-cycle スキル自体が前提とする最低限の共通ツール
# （git・gh CLI・uuidgen 等）のみ。実運用ワークスペースでは、対象リポジトリのビルド要件に
# 応じて下記「拡張ポイント」に追加インストールしてください。

FROM node:20-slim

# --- run-cycle が前提とする最低限のツールチェーン ---
# - git / openssh-client: 委譲先クローン（.flywheel/repos/）への push・SSH remote 対応
# - gh: run-cycle の PR 起票・状態照合（gh pr list 等）、ingest-challenges の github-issue ソース
# - uuid-runtime: run-cycle が委譲ごとに `uuidgen` で session_id を事前採番する（runtime/README.md
#   「実行イベントログ」参照）。node:20-slim には含まれないため明示的に追加する
# - ruby: run-cycle 手順6の書き込み後検算（フォーマット契約バリデータ
#   `scripts/validate-artifact.rb`・shebang は `/usr/bin/ruby` 固定）が前提とする。Debian の
#   ruby パッケージは /usr/bin/ruby を提供するため shebang のパスが macOS ホストと一致する。
#   未導入だとバリデータがインタプリタ不在で失敗し、契約の 3 値 exit（0/1/2）のどれでもない
#   形でコミットゲートが不作動になる
# - perl: ingest-challenges の取り込み元マーカー fp・periodic-audit の afp の算式
#   （`shasum -a 256`。/usr/bin/shasum は perl パッケージ同梱）が前提とする。slim イメージの
#   perl-base には shasum が含まれないため明示的に追加する
# - ca-certificates / curl: gh の apt リポジトリ追加・HTTPS 通信に必要
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      openssh-client \
      bash \
      curl \
      ca-certificates \
      procps \
      uuid-runtime \
      ruby \
      perl \
      gnupg \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# --- 拡張ポイント ---
# 対象リポジトリ群（.flywheel/repos/ 配下）の言語・ツールチェーンに応じて追加してください。
# 例:
#   RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip \
#       && rm -rf /var/lib/apt/lists/*
#   RUN corepack enable && corepack prepare pnpm@latest --activate
#
# 注意: compose.yml 側の `user:` が本イメージの既定 USER にどう影響するかは下記 USER 指定直前の
# コメントを、`DISABLE_AUTOUPDATER` の理由は compose.yml 内のコメントを参照。
#
# 既知の制約: ホスト UID/GID をそのまま使う（後述）ため、その UID がイメージ内の
# /etc/passwd に存在しない（getpwuid が引けない）ケースがある。この状態では上記でインストール
# した OpenSSH クライアント（openssh-client パッケージ）が「No user exists for uid <n>」等で
# 失敗し、git の SSH remote は使えない。
# HTTPS + `gh` CLI 認証（本 Dockerfile が導入済み。`repos.tsv` の既定クローン URL も HTTPS）を使う
# 運用であれば影響しない。SSH remote がどうしても必要な場合は、コンテナ起動時に root で
# `/etc/passwd` へ該当 UID のエントリを追記してから `user:` へ降格するエントリポイントスクリプト
# （例: gosu/su-exec パターン）を追加する拡張が必要（本雛形には含めない）。

# 実際のワーキングディレクトリは compose.yml の `working_dir`（ホストと同一の絶対パス。
# クリティカル設計決定①）が起動時に上書きするため、ここではビルド時の既定値のみ置く
# （`docker run` 単体でこのイメージを使う場合のフォールバック）。
WORKDIR /workspace

# 下記 USER 切り替え後も `docker run` 単体起動時に /workspace へ書き込めるよう、
# node:20-slim に既存の `node` ユーザー（uid 1000）に所有権を付与しておく。
# compose 経由ではバインドマウント側のディレクトリに置き換わるため、ここでの所有権は無関係。
RUN chown node:node /workspace

# 既定ユーザーを non-root にする（`docker run` 単体起動時の安全な既定値）。
# compose.yml 側の `user: "${HOST_UID}:${HOST_GID}"` がこの USER 指定を無条件に上書きするため、
# compose 経由の通常運用（HOST_UID/HOST_GID 一致・バインドマウント所有権）には影響しない。
# 新規ユーザーは作成せず、node:20-slim に既存の `node` ユーザー（uid 1000）を流用する。
USER node

# 常駐用フォールバック（compose 経由では compose.yml の command が優先される。docker run 単体時のみ有効）。
CMD ["sleep", "infinity"]
