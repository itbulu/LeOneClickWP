#!/usr/bin/env bash
# leoneclickwp - Linux VPS 一键安装 WordPress（用于测速测试）
# 用法: curl -fsSL <url> | bash   或   bash install.sh

set -euo pipefail

# ── 可自定义变量（也可通过环境变量覆盖）────────────────────────
WP_DIR="${WP_DIR:-/var/www/wordpress}"
WP_TITLE="${WP_TITLE:-WordPress Speed Test}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.com}"
WP_LANG="${WP_LANG:-zh_CN}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wpuser}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
# 访问方式: ip | domain（也可通过交互选择；设 WP_DOMAIN 则自动用域名模式）
SITE_MODE="${SITE_MODE:-}"
WP_DOMAIN="${WP_DOMAIN:-}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
# 是否导入 WP Test 测试数据: 0 | 1（空则交互询问）
# 数据来源: https://github.com/poststatus/wptest
IMPORT_TESTDATA="${IMPORT_TESTDATA:-}"
WTEST_XML_URL="${WTEST_XML_URL:-https://raw.githubusercontent.com/poststatus/wptest/master/wptest.xml}"

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ── 随机密码 ──────────────────────────────────────────────────
rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; echo; }

# ── 是否可交互提问（curl|bash 时 stdin 非 TTY，改从 /dev/tty 读）──
can_prompt() {
    [[ "$NONINTERACTIVE" != "1" ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]
}

# 从终端读入（兼容 curl | bash）
ask() {
    # $1 = 提示文案；结果写入 REPLY 风格变量名由调用方用 read 赋值
    local prompt="$1"
    local __ans=""
    # -r 禁用反斜杠转义；从真实终端读，避免被管道占用
    read -r -p "$prompt" __ans </dev/tty || true
    printf '%s' "$__ans"
}

# ── 检测 root ─────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "请使用 root 运行: sudo bash install.sh"

# ── 检测操作系统 ──────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_VER="${VERSION_ID:-}"
    else
        die "无法识别操作系统，仅支持 Ubuntu / Debian / CentOS / Rocky / AlmaLinux"
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MGR="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf"
            ;;
        *)
            die "不支持的操作系统: $OS_ID"
            ;;
    esac
    info "系统: ${PRETTY_NAME:-$OS_ID}  包管理器: $PKG_MGR"
}

# ── 获取公网 IP ───────────────────────────────────────────────
get_server_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -fsSL --connect-timeout 3 "$url" 2>/dev/null || true)
        [[ -n "$ip" ]] && break
    done
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    [[ -n "$ip" ]] || die "无法获取服务器 IP"
    echo "$ip"
}

# ── 校验域名格式 ──────────────────────────────────────────────
validate_domain() {
    local d="$1"
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# ── 规范化域名（去协议、路径、末尾斜杠）──────────────────────
normalize_domain() {
    local d="$1"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    d="${d%/}"
    echo "${d,,}"
}

# ── 根据域名生成 Nginx server_name ───────────────────────────
domain_server_names() {
    local d="$1"
    if [[ "$d" == www.* ]]; then
        echo "${d} ${d#www.}"
    else
        echo "${d} www.${d}"
    fi
}

# ── 选择 IP 或域名访问 ────────────────────────────────────────
# 设置全局: ACCESS_MODE, SITE_HOST, SITE_URL, NGINX_SERVER_NAME, NGINX_DEFAULT
prompt_site_access() {
    local choice domain

    # 已指定域名 → 域名模式
    if [[ -n "$WP_DOMAIN" ]]; then
        WP_DOMAIN="$(normalize_domain "$WP_DOMAIN")"
        validate_domain "$WP_DOMAIN" || die "域名格式无效: ${WP_DOMAIN}"
        ACCESS_MODE="domain"
        SITE_HOST="$WP_DOMAIN"
        NGINX_SERVER_NAME="$(domain_server_names "$WP_DOMAIN")"
        NGINX_DEFAULT=""
        SITE_URL="http://${SITE_HOST}"
        info "访问方式: 域名 → ${SITE_URL}"
        warn "请确保域名 DNS 已添加 A 记录指向 ${SERVER_IP}"
        return
    fi

    # 已指定模式
    if [[ -n "$SITE_MODE" ]]; then
        SITE_MODE="${SITE_MODE,,}"
        case "$SITE_MODE" in
            ip)
                ACCESS_MODE="ip"
                SITE_HOST="$SERVER_IP"
                NGINX_SERVER_NAME="_"
                NGINX_DEFAULT="default_server"
                SITE_URL="http://${SITE_HOST}"
                info "访问方式: IP → ${SITE_URL}"
                return
                ;;
            domain)
                die "域名模式请设置环境变量 WP_DOMAIN，例如: WP_DOMAIN=wp.example.com bash install.sh"
                ;;
            *)
                die "SITE_MODE 仅支持 ip 或 domain，当前: ${SITE_MODE}"
                ;;
        esac
    fi

    # 仅在明确关闭交互，或没有可用终端时跳过提问
    if ! can_prompt; then
        ACCESS_MODE="ip"
        SITE_HOST="$SERVER_IP"
        NGINX_SERVER_NAME="_"
        NGINX_DEFAULT="default_server"
        SITE_URL="http://${SITE_HOST}"
        info "非交互模式，默认使用 IP 访问: ${SITE_URL}"
        info "提示: 设置 WP_DOMAIN=域名 或下载脚本后运行可选择域名"
        return
    fi

    echo ""
    echo -e "${CYAN}请选择网站访问方式:${NC}"
    echo "  1) 仅 IP 访问    → http://${SERVER_IP}/"
    echo "  2) 绑定域名访问  → http://你的域名/"
    echo ""
    choice="$(ask "请输入选项 [1/2] (默认 1): ")"
    choice="${choice:-1}"

    case "$choice" in
        1|"")
            ACCESS_MODE="ip"
            SITE_HOST="$SERVER_IP"
            NGINX_SERVER_NAME="_"
            NGINX_DEFAULT="default_server"
            SITE_URL="http://${SITE_HOST}"
            ok "将使用 IP 访问: ${SITE_URL}"
            ;;
        2)
            while true; do
                domain="$(ask "请输入域名 (例如 wp.example.com): ")"
                domain="$(normalize_domain "$domain")"
                if [[ -z "$domain" ]]; then
                    warn "域名不能为空"
                    continue
                fi
                if ! validate_domain "$domain"; then
                    warn "域名格式无效，请重新输入"
                    continue
                fi
                break
            done
            ACCESS_MODE="domain"
            SITE_HOST="$domain"
            NGINX_SERVER_NAME="$(domain_server_names "$domain")"
            NGINX_DEFAULT=""
            SITE_URL="http://${SITE_HOST}"
            ok "将使用域名访问: ${SITE_URL}"
            echo ""
            warn "安装前请确认: 域名 ${domain} 的 DNS A 记录已指向 ${SERVER_IP}"
            ask "DNS 已配置好? 按 Enter 继续，Ctrl+C 取消..." >/dev/null
            ;;
        *)
            die "无效选项: ${choice}"
            ;;
    esac
}

# ── 选择是否导入 WP Test 测试数据 ─────────────────────────────
# 设置全局: IMPORT_TESTDATA_FLAG (0|1)
prompt_import_testdata() {
    local choice

    if [[ -n "$IMPORT_TESTDATA" ]]; then
        case "${IMPORT_TESTDATA,,}" in
            1|yes|y|true)
                IMPORT_TESTDATA_FLAG=1
                info "已指定导入 WP Test 测试数据"
                ;;
            0|no|n|false)
                IMPORT_TESTDATA_FLAG=0
                info "已指定跳过测试数据导入"
                ;;
            *)
                die "IMPORT_TESTDATA 仅支持 0 或 1，当前: ${IMPORT_TESTDATA}"
                ;;
        esac
        return
    fi

    if ! can_prompt; then
        IMPORT_TESTDATA_FLAG=0
        info "非交互模式，默认不导入测试数据"
        info "提示: 设置 IMPORT_TESTDATA=1 可启用导入"
        return
    fi

    echo ""
    echo -e "${CYAN}是否导入 WP Test 测试数据包?${NC}"
    echo "  来源: https://github.com/poststatus/wptest"
    echo "  说明: 含大量文章/页面/媒体，更接近真实站点，便于测速与主题测试"
    echo "  注意: 导入含附件，可能需要几分钟"
    echo ""
    echo "  1) 不导入（干净默认站点，推荐纯测速）"
    echo "  2) 导入 WP Test 测试数据"
    echo ""
    choice="$(ask "请输入选项 [1/2] (默认 1): ")"
    choice="${choice:-1}"

    case "$choice" in
        1|"")
            IMPORT_TESTDATA_FLAG=0
            ok "将安装干净 WordPress 站点"
            ;;
        2)
            IMPORT_TESTDATA_FLAG=1
            ok "安装完成后将导入 WP Test 测试数据"
            ;;
        *)
            die "无效选项: ${choice}"
            ;;
    esac
}

# ── 安装依赖 (Debian/Ubuntu) ──────────────────────────────────
install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    # 避免 needrestart 交互打断静默安装
    export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
    export NEEDRESTART_SUSPEND="${NEEDRESTART_SUSPEND:-1}"

    apt-get update -qq
    apt-get install -y -qq curl wget unzip mariadb-server nginx \
        php-fpm php-mysql php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache php-imagick \
        certbot python3-certbot-nginx 2>/dev/null || \
    apt-get install -y curl wget unzip mariadb-server nginx \
        php-fpm php-mysql php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache

    systemctl enable --now mariadb 2>/dev/null || true
    systemctl enable --now nginx 2>/dev/null || true
    start_php_fpm
}

# ── 安装依赖 (RHEL 系) ────────────────────────────────────────
install_rhel() {
    $PKG_MGR install -y epel-release 2>/dev/null || true
    $PKG_MGR install -y curl wget unzip mariadb-server nginx \
        php-fpm php-mysqlnd php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache
    systemctl enable --now mariadb nginx 2>/dev/null || true
    start_php_fpm
}

# ── 启动 PHP-FPM（兼容 php8.x-fpm / php-fpm）─────────────────
start_php_fpm() {
    local ver="" unit
    if command -v php &>/dev/null; then
        ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi

    if [[ -n "$ver" ]]; then
        systemctl enable --now "php${ver}-fpm" 2>/dev/null || true
    fi
    systemctl enable --now php-fpm 2>/dev/null || true

    # 扫描并启动所有已安装的 php*-fpm 单元
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        systemctl enable --now "$unit" 2>/dev/null || true
    done < <(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}')
}

# ── 检测 PHP-FPM socket ─────────────────────────────────────
detect_php_fpm() {
    local sock="" candidate ver="" i

    start_php_fpm

    if command -v php &>/dev/null; then
        ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi

    # 等待 socket 出现（部分系统启动稍慢）
    for i in $(seq 1 15); do
        if [[ -n "$ver" ]]; then
            for candidate in \
                "/run/php/php${ver}-fpm.sock" \
                "/var/run/php/php${ver}-fpm.sock" \
                "/run/php-fpm/www.sock" \
                "/var/run/php-fpm/www.sock"
            do
                if [[ -S "$candidate" ]]; then
                    echo "$candidate"
                    return 0
                fi
            done
        fi

        sock="$(find /run/php /var/run/php /run/php-fpm /var/run/php-fpm \
            -type s \( -name '*fpm*.sock' -o -name 'php*.sock' -o -name 'www.sock' \) \
            2>/dev/null | sort -V | tail -1 || true)"
        if [[ -n "$sock" && -S "$sock" ]]; then
            echo "$sock"
            return 0
        fi

        sleep 1
    done

    warn "PHP-FPM 状态:"
    systemctl status "php${ver}-fpm" --no-pager 2>/dev/null || systemctl status php-fpm --no-pager 2>/dev/null || true
    ls -la /run/php /var/run/php 2>/dev/null || true
    die "未找到 PHP-FPM socket。请手动执行: systemctl start php${ver:-}-fpm 或 systemctl start php-fpm"
}

restart_php_fpm() {
    local ver=""
    if command -v php &>/dev/null; then
        ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
    if [[ -n "$ver" ]]; then
        systemctl restart "php${ver}-fpm" 2>/dev/null && return 0
    fi
    systemctl restart php-fpm 2>/dev/null || true
    start_php_fpm
}

# ── MariaDB 执行 SQL ──────────────────────────────────────────
mysql_exec() {
    local sql="$1"
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        mysql -u root -e "$sql"
    elif mysql -u root -p"${DB_ROOT_PASS}" -e "SELECT 1" &>/dev/null; then
        mysql -u root -p"${DB_ROOT_PASS}" -e "$sql"
    else
        die "无法连接 MariaDB，请检查服务状态: systemctl status mariadb"
    fi
}

# ── 配置 MariaDB ──────────────────────────────────────────────
setup_database() {
    info "配置 MariaDB 数据库..."

    systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || true

    # 新装 MariaDB 通常允许 unix_socket 免密登录 root
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        mysql -u root -e "
            ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
            FLUSH PRIVILEGES;
        " 2>/dev/null || true
    fi

    mysql_exec "
        CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        DROP USER IF EXISTS '${DB_USER}'@'localhost';
        CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
        GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
    "
    ok "数据库 ${DB_NAME} 已就绪"
}

# ── 下载 WordPress ────────────────────────────────────────────
install_wordpress_files() {
    info "下载 WordPress 最新版..."
    local tmp="/tmp/wordpress-$RANDOM"
    mkdir -p "$tmp"
    curl -fsSL "https://wordpress.org/latest.tar.gz" -o "$tmp/wp.tar.gz"
    rm -rf "$WP_DIR"
    mkdir -p "$WP_DIR"
    tar -xzf "$tmp/wp.tar.gz" -C "$tmp"
    cp -a "$tmp/wordpress/." "$WP_DIR/"
    rm -rf "$tmp"
    ok "WordPress 文件已部署到 ${WP_DIR}"
}

# ── 安装 WP-CLI ───────────────────────────────────────────────
install_wpcli() {
    if command -v wp &>/dev/null; then
        ok "WP-CLI 已存在"
        return
    fi
    info "安装 WP-CLI..."
    curl -fsSL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" \
        -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
    ok "WP-CLI 安装完成"
}

# ── 生成 Nginx 站点配置内容 ───────────────────────────────────
nginx_site_config() {
    local php_sock="$1"
    cat <<NGINX
server {
    listen 80 ${NGINX_DEFAULT};
    listen [::]:80 ${NGINX_DEFAULT};
    server_name ${NGINX_SERVER_NAME};
    root ${WP_DIR};
    index index.php index.html;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:${php_sock};
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)\$ {
        expires 7d;
        access_log off;
    }

    location ~ /\. {
        deny all;
    }
}
NGINX
}

# ── 配置 Nginx ────────────────────────────────────────────────
setup_nginx() {
    local php_sock="$1"
    info "配置 Nginx..."

    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

    if [[ -d /etc/nginx/sites-available ]]; then
        nginx_site_config "$php_sock" > /etc/nginx/sites-available/wordpress
        ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/wordpress
    else
        nginx_site_config "$php_sock" > /etc/nginx/conf.d/wordpress.conf
    fi

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    ok "Nginx 已配置并启动"
}

# ── PHP 优化（测速友好）──────────────────────────────────────
tune_php() {
    local ini_dir
    if [[ "$PKG_MGR" == "apt" ]]; then
        ini_dir="/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/fpm/conf.d"
    else
        ini_dir="/etc/php.d"
    fi
    mkdir -p "$ini_dir"
    cat > "${ini_dir}/99-leoneclickwp.ini" <<'PHPINI'
; leoneclickwp 测速优化
opcache.enable=1
opcache.memory_consumption=128
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
realpath_cache_size=4096K
realpath_cache_ttl=600
PHPINI
    restart_php_fpm
}

# ── 防火墙放行 80 ─────────────────────────────────────────────
open_firewall() {
    [[ "$SKIP_FIREWALL" == "1" ]] && { warn "已跳过防火墙配置"; return; }
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp
        ok "UFW 已放行 80 端口"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=http 2>/dev/null || firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --reload
        ok "firewalld 已放行 80 端口"
    else
        warn "未检测到活跃防火墙，跳过"
    fi
}

# ── 文件权限 ──────────────────────────────────────────────────
fix_permissions() {
    local web_user="www-data"
    id nginx &>/dev/null && web_user="nginx"
    chown -R "${web_user}:${web_user}" "$WP_DIR"
    find "$WP_DIR" -type d -exec chmod 755 {} \;
    find "$WP_DIR" -type f -exec chmod 644 {} \;
}

# ── WordPress 初始化 ──────────────────────────────────────────
setup_wordpress() {
    local db_pass="$1" admin_pass="$2" site_url="$3"
    info "初始化 WordPress..."

    cd "$WP_DIR"

    # 创建 wp-config.php
    wp config create \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$db_pass" \
        --dbhost="localhost" \
        --dbcharset="utf8mb4" \
        --allow-root \
        --force 2>/dev/null || true

    # 追加安全密钥
    wp config shuffle-salts --allow-root 2>/dev/null || true

    # 禁用 WP-Cron 外部触发（可选，减少测速干扰）
    wp config set DISABLE_WP_CRON true --raw --allow-root 2>/dev/null || true

    # 执行安装
    wp core install \
        --url="$site_url" \
        --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$admin_pass" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --skip-email \
        --allow-root

    # 安装中文语言包（可选）
    if [[ "$WP_LANG" != "en_US" ]]; then
        wp language core install "$WP_LANG" --activate --allow-root 2>/dev/null || \
            warn "语言包 ${WP_LANG} 安装失败，使用默认英文"
    fi

    # 删除示例内容，保留全新默认站点
    wp post delete 1 --force --allow-root 2>/dev/null || true   # Hello World 文章
    wp post delete 2 --force --allow-root 2>/dev/null || true   # 示例页面
    wp comment delete 1 --force --allow-root 2>/dev/null || true

    # 未导入测试包时创建测速页；导入测试包时由 WP Test 提供丰富内容
    if [[ "${IMPORT_TESTDATA_FLAG:-0}" != "1" ]]; then
        wp post create \
            --post_title="Speed Test Page" \
            --post_content="WordPress 已成功安装。此页面用于测试服务器打开 WP 的速度。" \
            --post_status=publish \
            --allow-root >/dev/null
    fi

    # 禁用评论/pingback 减少干扰（已发布内容不受影响）
    wp option update default_comment_status closed --allow-root
    wp option update default_ping_status closed --allow-root

    ok "WordPress 安装完成"
}

# ── 导入 WP Test 测试数据 ─────────────────────────────────────
# 参考官方 CLI: https://github.com/poststatus/wptest/blob/master/wptest-cli-install.sh
import_wptest() {
    info "导入 WP Test 测试数据..."
    warn "将下载并导入文章、页面与媒体附件，可能需要几分钟，请耐心等待"

    cd "$WP_DIR"

    wp plugin install wordpress-importer --activate --allow-root

    local xml="/tmp/leoneclickwp-wptest-$$.xml"
    if ! curl -fsSL "$WTEST_XML_URL" -o "$xml"; then
        warn "无法下载测试数据 XML，已跳过导入"
        wp plugin deactivate wordpress-importer --allow-root 2>/dev/null || true
        return 0
    fi

    # 与官方脚本一致：创建作者并导入附件
    if wp import "$xml" --authors=create --allow-root; then
        ok "WP Test 测试数据导入完成"
    else
        warn "测试数据导入过程中出现错误，站点仍可使用，请检查后台内容"
    fi
    rm -f "$xml"

    # 导入完成后停用并移除导入插件，再统一停用其他默认插件
    wp plugin deactivate wordpress-importer --allow-root 2>/dev/null || true
    wp plugin delete wordpress-importer --allow-root 2>/dev/null || true

    fix_permissions
}

# ── 停用默认插件（测速时减少干扰）────────────────────────────
deactivate_default_plugins() {
    cd "$WP_DIR"
    wp plugin deactivate --all --allow-root 2>/dev/null || true
}

# ── 保存安装信息 ──────────────────────────────────────────────
save_credentials() {
    local file="/root/leoneclickwp-credentials.txt"
    cat > "$file" <<CREDS
========================================
  leoneclickwp 安装信息
  安装时间: $(date '+%Y-%m-%d %H:%M:%S')
========================================
访问方式:   ${ACCESS_MODE} ($([ "$ACCESS_MODE" = "domain" ] && echo "域名" || echo "IP"))
网站地址:   ${SITE_URL}/
后台地址:   ${SITE_URL}/wp-admin/
服务器 IP:  ${SERVER_IP}
$([ "$ACCESS_MODE" = "domain" ] && echo "绑定域名:   ${SITE_HOST}")
测试数据:   $([ "${IMPORT_TESTDATA_FLAG:-0}" = "1" ] && echo "已导入 WP Test (wptest)" || echo "未导入")
管理员账号: ${WP_ADMIN_USER}
管理员密码: ${WP_ADMIN_PASS}
数据库名:   ${DB_NAME}
数据库用户: ${DB_USER}
数据库密码: ${DB_PASS}
MariaDB root: ${DB_ROOT_PASS}
WordPress目录: ${WP_DIR}
========================================
CREDS
    chmod 600 "$file"
    echo "$file"
}

# ── 打印摘要 ──────────────────────────────────────────────────
print_summary() {
    local cred_file="$1"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       WordPress 一键安装成功！                       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}访问方式${NC}   $([ "$ACCESS_MODE" = "domain" ] && echo "域名 (${SITE_HOST})" || echo "IP (${SERVER_IP})")"
    echo -e "  ${CYAN}网站首页${NC}   ${SITE_URL}/"
    echo -e "  ${CYAN}后台登录${NC}   ${SITE_URL}/wp-admin/"
    echo -e "  ${CYAN}服务器 IP${NC}  ${SERVER_IP}"
    echo -e "  ${CYAN}测试数据${NC}   $([ "${IMPORT_TESTDATA_FLAG:-0}" = "1" ] && echo "已导入 WP Test" || echo "未导入")"
    echo -e "  ${CYAN}管理员${NC}     ${WP_ADMIN_USER}"
    echo -e "  ${CYAN}密码${NC}       ${WP_ADMIN_PASS}"
    echo ""
    echo -e "  凭据已保存至: ${cred_file}"
    echo ""
    if [[ "$ACCESS_MODE" = "domain" ]]; then
        echo -e "  ${YELLOW}提示:${NC} 请确认域名 ${SITE_HOST} 的 DNS A 记录指向 ${SERVER_IP}"
    else
        echo -e "  ${YELLOW}提示:${NC} 在浏览器打开 ${SITE_URL}/ 即可测试 WP 加载速度"
    fi
    echo -e "  ${YELLOW}卸载:${NC} bash uninstall.sh"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   leoneclickwp - WordPress 一键安装（测速专用）      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_os

    DB_ROOT_PASS="${DB_ROOT_PASS:-$(rand_pass 20)}"
    DB_PASS="${DB_PASS:-$(rand_pass 20)}"
    WP_ADMIN_PASS="${WP_ADMIN_PASS:-$(rand_pass 16)}"
    SERVER_IP="$(get_server_ip)"
    info "服务器 IP: ${SERVER_IP}"

    prompt_site_access
    prompt_import_testdata

    info "安装系统依赖..."
    if [[ "$PKG_MGR" == "apt" ]]; then
        install_debian
    else
        install_rhel
    fi

    PHP_SOCK="$(detect_php_fpm)"
    info "PHP-FPM: ${PHP_SOCK}"

    setup_database
    install_wordpress_files
    install_wpcli
    setup_nginx "$PHP_SOCK"
    tune_php
    fix_permissions
    setup_wordpress "$DB_PASS" "$WP_ADMIN_PASS" "$SITE_URL"

    if [[ "${IMPORT_TESTDATA_FLAG:-0}" == "1" ]]; then
        import_wptest
    fi
    deactivate_default_plugins

    open_firewall

    # 重启服务确保一切生效
    systemctl restart nginx
    restart_php_fpm

    CRED_FILE="$(save_credentials)"
    print_summary "$CRED_FILE"
}

main "$@"
