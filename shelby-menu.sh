#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Shelby CLI 中文菜单一键脚本
# - 自动检测并安装依赖（尽量自动化）
# - 安装 Shelby CLI
# - 生成/管理本地钱包（私钥仅保存在本机）
# - 生成 ~/.shelby/config.yaml
# ============================================================

# -------------------------
# 基本配置
# -------------------------
SHELBY_DIR="${HOME}/.shelby"
ACCOUNTS_DIR="${SHELBY_DIR}/accounts"
CONFIG_FILE="${SHELBY_DIR}/config.yaml"
ACTIVE_ACCOUNT_FILE="${SHELBY_DIR}/active_account"

DEFAULT_CONTEXT="shelbynet"
DEFAULT_EXPIRATION="in 2 days"

# 允许用户通过环境变量注入 API key（可选）
SHELBY_RPC_API_KEY="${SHELBY_RPC_API_KEY:-}"
SHELBY_INDEXER_API_KEY="${SHELBY_INDEXER_API_KEY:-}"
APTOS_API_KEY="${APTOS_API_KEY:-}"

# -------------------------
# 输出样式
# -------------------------
c_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
c_green() { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
c_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

# -------------------------
# OS / 包管理器检测
# -------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

have() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
  if have apt-get; then echo "apt"; return; fi
  if have yum; then echo "yum"; return; fi
  if have dnf; then echo "dnf"; return; fi
  if have pacman; then echo "pacman"; return; fi
  if have brew; then echo "brew"; return; fi
  echo "unknown"
}

PKG_MANAGER="$(detect_pkg_manager)"

# -------------------------
# 安装工具（尽力而为）
# -------------------------
install_with_pkg() {
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt)
      sudo -n true >/dev/null 2>&1 || true
      if have sudo; then
        sudo apt-get update -y
        sudo apt-get install -y "$pkg"
      else
        apt-get update -y
        apt-get install -y "$pkg"
      fi
      ;;
    yum)
      if have sudo; then sudo yum install -y "$pkg"; else yum install -y "$pkg"; fi
      ;;
    dnf)
      if have sudo; then sudo dnf install -y "$pkg"; else dnf install -y "$pkg"; fi
      ;;
    pacman)
      if have sudo; then sudo pacman -Sy --noconfirm "$pkg"; else pacman -Sy --noconfirm "$pkg"; fi
      ;;
    brew)
      brew install "$pkg"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_basic_tools() {
  mkdir -p "$SHELBY_DIR" "$ACCOUNTS_DIR"

  if ! have curl; then
    c_yellow "未检测到 curl，尝试自动安装..."
    install_with_pkg curl || { c_red "无法自动安装 curl，请手动安装后重试。"; exit 1; }
  fi

  if ! have git; then
    c_yellow "未检测到 git，尝试自动安装..."
    install_with_pkg git || { c_red "无法自动安装 git，请手动安装后重试。"; exit 1; }
  fi
}

# -------------------------
# Node/NPM 安装（优先 nvm）
# -------------------------
load_nvm_if_exists() {
  # shellcheck disable=SC1090
  [[ -s "${HOME}/.nvm/nvm.sh" ]] && source "${HOME}/.nvm/nvm.sh"
}

install_node_via_nvm() {
  # Linux / macOS 都可，但 macOS 更推荐 brew node
  c_blue "尝试用 nvm 安装 Node.js (LTS)..."
  if [[ ! -d "${HOME}/.nvm" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  load_nvm_if_exists

  if ! have nvm; then
    c_red "nvm 安装失败或未生效，请重新打开终端或手动安装 Node.js。"
    exit 1
  fi

  nvm install --lts
  nvm use --lts

  c_green "Node.js 安装完成：$(node -v) / npm：$(npm -v)"
}

ensure_node_npm() {
  if have node && have npm; then
    return
  fi

  c_yellow "未检测到 node/npm，准备自动安装..."

  # macOS：优先 brew
  if [[ "$OS" == "darwin" ]]; then
    if have brew; then
      c_blue "macOS 检测到 brew，尝试 brew install node"
      brew install node || true
    fi
    if have node && have npm; then return; fi
    # fallback nvm
    install_node_via_nvm
    return
  fi

  # Linux：优先 nvm
  install_node_via_nvm
}

# -------------------------
# Shelby CLI 安装
# -------------------------
ensure_shelby_cli() {
  if have shelby; then
    c_green "Shelby CLI 已安装：$(shelby --version 2>/dev/null || echo "unknown")"
    return
  fi

  c_blue "安装 Shelby CLI：npm i -g @shelby-protocol/cli"
  npm i -g @shelby-protocol/cli

  # 确保 npm global bin 在 PATH
  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "${npm_prefix}" ]]; then
    export PATH="${npm_prefix}/bin:${PATH}"
  fi

  if ! have shelby; then
    c_red "Shelby CLI 安装后仍未找到 shelby 命令。"
    c_yellow "请检查 npm global bin 是否在 PATH：npm config get prefix"
    exit 1
  fi

  c_green "Shelby CLI 安装完成：$(shelby --version 2>/dev/null || echo "unknown")"
}

# -------------------------
# 账户管理：我们用文件保存私钥，避免 YAML 编辑复杂度
# 每个账户保存为：~/.shelby/accounts/<name>.env
# 内容包含 ADDRESS / PRIVATE_KEY
# -------------------------
account_file_path() {
  local name="$1"
  echo "${ACCOUNTS_DIR}/${name}.env"
}

get_active_account_name() {
  if [[ -f "$ACTIVE_ACCOUNT_FILE" ]]; then
    cat "$ACTIVE_ACCOUNT_FILE"
  else
    echo "alice"
  fi
}

set_active_account_name() {
  local name="$1"
  echo "$name" > "$ACTIVE_ACCOUNT_FILE"
}

read_account_env() {
  local name="$1"
  local f
  f="$(account_file_path "$name")"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$f"
  [[ -n "${ADDRESS:-}" && -n "${PRIVATE_KEY:-}" ]]
}

write_account_env() {
  local name="$1"
  local address="$2"
  local priv="$3"
  local f
  f="$(account_file_path "$name")"

  umask 077
  cat > "$f" <<EOF
# Shelby wallet: $name
ADDRESS="$address"
PRIVATE_KEY="$priv"
EOF
  chmod 600 "$f"
}

# -------------------------
# 生成 Aptos ed25519 钱包（用 @aptos-labs/ts-sdk）
# 依赖 node/npm
# -------------------------
ensure_ts_sdk() {
  local deps_dir="${SHELBY_DIR}/_deps"
  mkdir -p "$deps_dir"
  if [[ ! -d "${deps_dir}/node_modules/@aptos-labs/ts-sdk" ]]; then
    c_blue "安装 @aptos-labs/ts-sdk（仅用于本地生成钱包）..."
    npm i --prefix "$deps_dir" @aptos-labs/ts-sdk >/dev/null
  fi
}

generate_aptos_account_json() {
  local deps_dir="${SHELBY_DIR}/_deps"
  node - <<'NODE'
const path = require("path");
const os = require("os");
const deps = path.join(os.homedir(), ".shelby", "_deps", "node_modules");
const { Account } = require(path.join(deps, "@aptos-labs", "ts-sdk"));

const acct = Account.generate();
const address = acct.accountAddress.toString(); // 0x...
const pkHex = Buffer.from(acct.privateKey.toUint8Array()).toString("hex");
const out = { address, private_key: `ed25519-priv-0x${pkHex}` };
process.stdout.write(JSON.stringify(out));
NODE
}

# -------------------------
# 写入 ~/.shelby/config.yaml（根据当前激活账户重建）
# -------------------------
write_config_yaml() {
  local account_name="$1"
  local address="$2"
  local priv="$3"

  mkdir -p "$SHELBY_DIR"
  umask 077

  {
    echo "contexts:"
    echo "  local:"
    echo "    aptos_network:"
    echo "      name: local"
    echo "      fullnode: http://127.0.0.1:8080/v1"
    echo "      faucet: http://127.0.0.1:8081"
    echo "      indexer: http://127.0.0.1:8090/v1/graphql"
    echo "      pepper: https://api.devnet.aptoslabs.com/keyless/pepper/v0"
    echo "      prover: https://api.devnet.aptoslabs.com/keyless/prover/v0"
    [[ -n "$APTOS_API_KEY" ]] && echo "      api_key: \"$APTOS_API_KEY\""
    echo "    shelby_network:"
    echo "      rpc_endpoint: http://localhost:9090/"
    [[ -n "$SHELBY_RPC_API_KEY" ]] && echo "      rpc_api_key: \"$SHELBY_RPC_API_KEY\""

    echo "  shelbynet:"
    echo "    aptos_network:"
    echo "      name: shelbynet"
    echo "      fullnode: https://api.shelbynet.shelby.xyz/v1"
    echo "      faucet: https://faucet.shelbynet.shelby.xyz"
    echo "      indexer: https://api.shelbynet.shelby.xyz/v1/graphql"
    echo "      pepper: https://api.devnet.aptoslabs.com/keyless/pepper/v0"
    echo "      prover: https://api.devnet.aptoslabs.com/keyless/prover/v0"
    [[ -n "$APTOS_API_KEY" ]] && echo "      api_key: \"$APTOS_API_KEY\""
    echo "    shelby_network:"
    echo "      rpc_endpoint: https://api.shelbynet.shelby.xyz/shelby"
    [[ -n "$SHELBY_RPC_API_KEY" ]] && echo "      rpc_api_key: \"$SHELBY_RPC_API_KEY\""
    [[ -n "$SHELBY_INDEXER_API_KEY" ]] && echo "      indexer_api_key: \"$SHELBY_INDEXER_API_KEY\""

    echo "accounts:"
    echo "  ${account_name}:"
    echo "    private_key: ${priv}"
    echo "    address: \"${address}\""
    echo "default_context: ${DEFAULT_CONTEXT}"
    echo "default_account: ${account_name}"
  } > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"
}

ensure_config_exists() {
  local name
  name="$(get_active_account_name)"

  if read_account_env "$name"; then
    : "${ADDRESS:?}" "${PRIVATE_KEY:?}"
    write_config_yaml "$name" "$ADDRESS" "$PRIVATE_KEY"
  else
    # 没有账户就自动创建一个 alice
    action_create_wallet "alice" "quiet"
  fi
}

# -------------------------
# 菜单动作：1 创建新钱包
# -------------------------
action_create_wallet() {
  local name="${1:-}"
  local mode="${2:-}"

  if [[ -z "$name" ]]; then
    echo -n "请输入钱包名称（默认 alice）："
    read -r name
    name="${name:-alice}"
  fi

  local f
  f="$(account_file_path "$name")"
  if [[ -f "$f" ]]; then
    c_yellow "钱包 ${name} 已存在：$f"
    echo -n "是否覆盖并重新生成？(y/N)："
    read -r yn
    yn="${yn:-N}"
    [[ "$yn" =~ ^[Yy]$ ]] || { c_yellow "已取消。"; return; }
  fi

  ensure_ts_sdk
  local acct_json
  acct_json="$(generate_aptos_account_json)"
  local address priv
  address="$(echo "$acct_json" | node -e 'const s=require("fs").readFileSync(0,"utf8"); console.log(JSON.parse(s).address)')"
  priv="$(echo "$acct_json" | node -e 'const s=require("fs").readFileSync(0,"utf8"); console.log(JSON.parse(s).private_key)')"

  write_account_env "$name" "$address" "$priv"
  set_active_account_name "$name"
  write_config_yaml "$name" "$address" "$priv"

  [[ "$mode" == "quiet" ]] || {
    c_green "✅ 已创建新钱包：$name"
    echo "地址：$address"
    echo "配置已写入：$CONFIG_FILE"
  }
}

# -------------------------
# 菜单动作：2 查看钱包地址
# -------------------------
action_show_address() {
  local name
  name="$(get_active_account_name)"

  if ! read_account_env "$name"; then
    c_red "未找到钱包 ${name}，请先创建新钱包。"
    return
  fi

  c_green "当前钱包：${name}"
  echo "地址：${ADDRESS}"
  echo "配置文件：${CONFIG_FILE}"
}

# -------------------------
# 菜单动作：3 领水（ShelbyUSD + APT 提示）
# -------------------------
action_faucet() {
  local name
  name="$(get_active_account_name)"

  if ! read_account_env "$name"; then
    c_red "未找到钱包 ${name}，请先创建新钱包。"
    return
  fi

  c_blue "====== 领水指引 ======"
  echo "当前地址：${ADDRESS}"
  echo
  echo "（1）领 ShelbyUSD（用于上传等操作）"
  echo "执行命令："
  echo "  shelby faucet --no-open"
  echo
  echo "（2）APT（Gas）"
  echo "你需要在 Aptos faucet / aptos cli 侧给该地址注入 APT。"
  echo "（不同环境/网络的 APT faucet 不同，脚本不强行自动化这一步。）"
  echo "======================"

  echo
  echo -n "是否现在执行 'shelby faucet --no-open' 并显示链接？(Y/n)："
  read -r yn
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    set +e
    shelby faucet --no-open
    set -e
    echo
    echo -n "若上面输出了 URL，是否尝试自动打开浏览器？(y/N)："
    read -r openyn
    openyn="${openyn:-N}"
    if [[ "$openyn" =~ ^[Yy]$ ]]; then
      c_yellow "提示：Shelby CLI 输出的链接请自行复制；脚本无法可靠解析所有格式。"
      c_yellow "如果你能复制到 URL，可手动打开。"
      # 如果你想做更强的自动打开，可把 CLI 输出重定向到变量后正则提取 URL
    fi
  fi
}

# -------------------------
# 菜单动作：4 选择需要上传的文件
# -------------------------
action_upload_file() {
  local name
  name="$(get_active_account_name)"
  if ! read_account_env "$name"; then
    c_red "未找到钱包 ${name}，请先创建新钱包。"
    return
  fi

  echo -n "请输入本地文件路径："
  read -r src
  if [[ -z "$src" || ! -f "$src" ]]; then
    c_red "文件不存在：$src"
    return
  fi

  local base dst exp
  base="$(basename "$src")"
  echo -n "请输入远端目标路径（默认 files/${base}）："
  read -r dst
  dst="${dst:-files/${base}}"

  echo -n "请输入过期时间（默认 '${DEFAULT_EXPIRATION}'，例如 'in 2 days'）："
  read -r exp
  exp="${exp:-$DEFAULT_EXPIRATION}"

  c_blue "开始上传："
  echo "  src: $src"
  echo "  dst: $dst"
  echo "  exp: $exp"
  echo

  # --assume-yes：跳过确认，适合脚本
  shelby upload "$src" "$dst" --expiration "$exp" --assume-yes

  c_green "✅ 上传完成。"
  echo
  echo -n "是否下载回本地进行校验？(Y/n)："
  read -r yn
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    local dl_dir="/tmp/shelby_download_$$"
    mkdir -p "$dl_dir"
    local dl_path="${dl_dir}/${base}"
    c_blue "下载中：$dst -> $dl_path"
    shelby download "$dst" "$dl_path" --force

    if have shasum; then
      c_blue "sha256 对比："
      shasum -a 256 "$src" "$dl_path" || true
    elif have sha256sum; then
      c_blue "sha256 对比："
      sha256sum "$src" "$dl_path" || true
    else
      c_yellow "未找到 shasum/sha256sum，已下载到：$dl_path"
    fi
  fi
}

# -------------------------
# 菜单动作：5 导出钱包私钥（强警告）
# -------------------------
action_export_private_key() {
  local name
  name="$(get_active_account_name)"
  if ! read_account_env "$name"; then
    c_red "未找到钱包 ${name}，请先创建新钱包。"
    return
  fi

  c_red "⚠️ 警告：导出私钥非常危险！"
  c_red "任何获得私钥的人都可以完全控制你的资产与权限。"
  echo -n "请输入 'EXPORT' 继续："
  read -r confirm
  if [[ "$confirm" != "EXPORT" ]]; then
    c_yellow "已取消。"
    return
  fi

  echo -n "再次确认：请输入钱包名称 '${name}' 继续："
  read -r confirm2
  if [[ "$confirm2" != "$name" ]]; then
    c_yellow "已取消。"
    return
  fi

  c_green "钱包：$name"
  echo "地址：$ADDRESS"
  echo "私钥：$PRIVATE_KEY"
  c_yellow "提示：请不要把私钥发给任何人，也不要上传到网盘/聊天群。"
}

# -------------------------
# 初始化：检测安装依赖 + CLI + 配置
# -------------------------
bootstrap() {
  c_blue "==> 环境检测与自动安装（尽力而为）"
  ensure_basic_tools
  ensure_node_npm
  ensure_shelby_cli
  ensure_config_exists

  # 简单 sanity 输出
  c_green "==> Shelby 初始化完成"
  echo "配置：$CONFIG_FILE"
  echo "当前钱包：$(get_active_account_name)"
}

# -------------------------
# 主菜单
# -------------------------
main_menu() {
  while true; do
    echo
    echo "=============================="
    echo " Shelby CLI 教程 - 中文菜单向导"
    echo " 当前 context: ${DEFAULT_CONTEXT}"
    echo " 当前钱包: $(get_active_account_name)"
    echo "=============================="
    echo "1) 创建新钱包"
    echo "2) 查看钱包地址"
    echo "3) 通过钱包地址进行领水（提示/入口）"
    echo "4) 选择需要上传的文件（并上传）"
    echo "5) 导出钱包私钥（⚠️危险）"
    echo "0) 退出"
    echo "------------------------------"
    echo -n "请输入选项: "
    read -r choice

    case "$choice" in
      1) action_create_wallet ;;
      2) action_show_address ;;
      3) action_faucet ;;
      4) action_upload_file ;;
      5) action_export_private_key ;;
      0) c_green "已退出。"; exit 0 ;;
      *) c_yellow "无效选项：$choice" ;;
    esac
  done
}

# -------------------------
# 入口
# -------------------------
bootstrap
main_menu
