#!/usr/bin/env bash
# pinned.sh
# 現在解決されている Node / pnpm のバージョンを読み取り、
# プロジェクトのファイルに書き出して固定する。
#
#   .node-version        ← Node のバージョン
#   package.json         ← "packageManager": "pnpm@x.y.z"
#
# 何度実行しても同じ結果になる(冪等)。既存の値は --force を付けない限り上書きしない。

set -euo pipefail

NODE_MODE="full"   # full: 24.17.0 / major: 24
FORCE=0
DRY=0
INSTALL=0
CHECK=0
NODE_OVERRIDE=""
PNPM_OVERRIDE=""

usage() {
  cat <<'EOF'
使い方: ./pin-env.sh [オプション]

  --node-major        Node はメジャーのみ固定する(例: 24)。既定は完全なバージョン
  --node <ver>        Node のバージョンを指定(自動検出しない)
  --pnpm <ver>        pnpm のバージョンを指定(自動検出しない)
  --force             既存の固定値を上書きする
  --dry-run           書き込まず、何を変更するかだけ表示する
  --install           固定後に vp install を実行してロックファイルを更新する
  --check             書き込まず、固定されているかだけ検証する(CI 向け、未固定なら exit 1)
  -h, --help          このヘルプを表示

プロジェクトのルート(package.json があるディレクトリ)で実行してください。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-major) NODE_MODE="major"; shift ;;
    --node)       NODE_OVERRIDE="${2:?--node にはバージョンが必要です}"; shift 2 ;;
    --pnpm)       PNPM_OVERRIDE="${2:?--pnpm にはバージョンが必要です}"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    --install)    INSTALL=1; shift ;;
    --check)      CHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die()  { printf 'エラー: %s\n' "$*" >&2; exit 1; }

[[ -f package.json ]] || die "package.json が見つかりません。プロジェクトのルートで実行してください。"
command -v node >/dev/null 2>&1 || die "node が見つかりません。vp env の設定(vp env doctor)を確認してください。"

# ---------------------------------------------------------------- --check
if [[ $CHECK -eq 1 ]]; then
  rc=0
  node_ok=0
  [[ -f .node-version ]] && node_ok=1
  if [[ $node_ok -eq 0 ]]; then
    node -e 'const p=require("./package.json"); process.exit(p.devEngines && p.devEngines.runtime ? 0 : 1)' \
      && node_ok=1 || true
  fi
  if [[ $node_ok -eq 1 ]]; then log "OK: Node のバージョンが固定されています"; else log "NG: Node が未固定です(.node-version か devEngines.runtime)"; rc=1; fi

  if node -e 'const p=require("./package.json"); process.exit(p.packageManager || (p.devEngines && p.devEngines.packageManager) ? 0 : 1)'; then
    log "OK: パッケージマネージャが固定されています"
  else
    log "NG: packageManager が未設定です"; rc=1
  fi

  if [[ -f pnpm-lock.yaml || -f package-lock.json || -f yarn.lock || -f bun.lock || -f bun.lockb ]]; then
    log "OK: ロックファイルがあります"
  else
    log "NG: ロックファイルがありません"; rc=1
  fi
  exit "$rc"
fi

# ---------------------------------------------------------------- 現在のバージョンを取得
detect_semver() { grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }

NODE_VER="${NODE_OVERRIDE:-$(node -v 2>/dev/null | sed 's/^v//')}"
[[ -n "$NODE_VER" ]] || die "Node のバージョンを取得できませんでした。--node で指定してください。"
NODE_PIN="$NODE_VER"
[[ "$NODE_MODE" == "major" ]] && NODE_PIN="${NODE_VER%%.*}"

PNPM_VER="$PNPM_OVERRIDE"
if [[ -z "$PNPM_VER" ]] && command -v pnpm >/dev/null 2>&1; then
  PNPM_VER="$(pnpm --version 2>/dev/null | detect_semver)"
fi

log "検出したバージョン"
log "  node : ${NODE_VER}  (固定値: ${NODE_PIN})"
log "  pnpm : ${PNPM_VER:-(未検出)}"
[[ $DRY -eq 1 ]] && log "(--dry-run: 書き込みは行いません)"
log ""

# ---------------------------------------------------------------- .node-version
write_node_version() {
  if [[ -f .node-version ]]; then
    current="$(tr -d '[:space:]' < .node-version)"
    if [[ "$current" == "$NODE_PIN" ]]; then
      log ".node-version: 変更なし (${current})"; return
    fi
    if [[ $FORCE -ne 1 ]]; then
      warn ".node-version は既に ${current} です。上書きするには --force を付けてください。"; return
    fi
  fi
  if [[ $DRY -eq 1 ]]; then
    log ".node-version: ${NODE_PIN} を書き込みます(dry-run)"
  else
    printf '%s\n' "$NODE_PIN" > .node-version
    log ".node-version: ${NODE_PIN} を書き込みました"
  fi
}
write_node_version

# ---------------------------------------------------------------- package.json の packageManager
write_package_manager() {
  if [[ -z "$PNPM_VER" ]]; then
    warn "pnpm のバージョンを検出できなかったため、packageManager は変更しません(--pnpm で指定できます)。"
    return
  fi
  PM_VALUE="pnpm@${PNPM_VER}" FORCE="$FORCE" DRY="$DRY" node - <<'NODE'
const fs = require('fs');
const file = 'package.json';
const raw = fs.readFileSync(file, 'utf8');
const m = raw.match(/^([ \t]+)"/m);
const indent = m ? m[1] : '  ';
const pkg = JSON.parse(raw);
const want = process.env.PM_VALUE;
const cur = pkg.packageManager;
if (cur === want) {
  console.log(`package.json: packageManager は変更なし (${cur})`);
  process.exit(0);
}
if (cur && process.env.FORCE !== '1') {
  console.error(`警告: packageManager は既に ${cur} です。上書きするには --force を付けてください。`);
  process.exit(0);
}
if (process.env.DRY === '1') {
  console.log(`package.json: packageManager を ${want} に設定します(dry-run)`);
  process.exit(0);
}
pkg.packageManager = want;
fs.writeFileSync(file, JSON.stringify(pkg, null, indent) + '\n');
console.log(`package.json: packageManager を ${want} に設定しました`);
NODE
}
write_package_manager

# ---------------------------------------------------------------- vp install / doctor
if [[ $INSTALL -eq 1 && $DRY -eq 0 ]]; then
  command -v vp >/dev/null 2>&1 || die "vp が見つからないため --install を実行できません。"
  log ""
  log "vp install を実行します"
  vp install
fi

if [[ $DRY -eq 0 ]] && command -v vp >/dev/null 2>&1; then
  log ""
  log "vp env doctor の結果"
  vp env doctor || true
fi

log ""
log "完了。.node-version、package.json、ロックファイルをコミットしてください。"
log "コンテナ・CI では vp install --frozen-lockfile を使います。"
