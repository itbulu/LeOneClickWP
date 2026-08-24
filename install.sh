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

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ── 随机密码 ──────────────────────────────────────────────────
rand_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; echo; }

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

# ── 安装依赖 (Debian/Ubuntu) ──────────────────────────────────
install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip mariadb-server nginx \
        php-fpm php-mysql php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache php-imagick \
        certbot python3-certbot-nginx 2>/dev/null || \
    apt-get install -y curl wget unzip mariadb-server nginx \
        php-fpm php-mysql php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache
    systemctl enable --now mariadb nginx 2>/dev/null || true
}

# ── 安装依赖 (RHEL 系) ────────────────────────────────────────
install_rhel() {
    $PKG_MGR install -y epel-release 2>/dev/null || true
    $PKG_MGR install -y curl wget unzip mariadb-server nginx \
        php-fpm php-mysqlnd php-curl php-gd php-intl php-mbstring \
        php-xml php-zip php-opcache
    systemctl enable --now mariadb nginx php-fpm
}

# ── 检测 PHP-FPM socket ─────────────────────────────────────
detect_php_fpm() {
    local sock=""
    sock=$(find /var/run/php /run/php-fpm -name '*.sock' 2>/dev/null | grep -E 'fpm|php' | sort -V | tail -1)
    [[ -n "$sock" ]] || sock="/run/php-fpm/www.sock"
    [[ -S "$sock" ]] || die "未找到 PHP-FPM socket，请确认 php-fpm 已安装并运行"
    echo "$sock"
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
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
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

restart_php_fpm() {
    local ver
    ver="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    systemctl restart "php${ver}-fpm" 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
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

    # 安装默认测试页面（方便确认站点正常）
    wp post create \
        --post_title="Speed Test Page" \
        --post_content="WordPress 已成功安装。此页面用于测试服务器打开 WP 的速度。" \
        --post_status=publish \
        --allow-root >/dev/null

    # 禁用评论/pingback 减少干扰
    wp option update default_comment_status closed --allow-root
    wp option update default_ping_status closed --allow-root

    # 删除无用插件（保留 Akismet/Hello Dolly 也可，测速时建议禁用）
    wp plugin deactivate --all --allow-root 2>/dev/null || true

    ok "WordPress 安装完成"
}

# ── 保存安装信息 ──────────────────────────────────────────────
save_credentials() {
    local file="/root/leoneclickwp-credentials.txt"
    cat > "$file" <<CREDS
========================================
  leoneclickwp 安装信息
  安装时间: $(date '+%Y-%m-%d %H:%M:%S')
========================================
网站地址:   http://${SERVER_IP}/
后台地址:   http://${SERVER_IP}/wp-admin/
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
    echo -e "  ${CYAN}网站首页${NC}   http://${SERVER_IP}/"
    echo -e "  ${CYAN}后台登录${NC}   http://${SERVER_IP}/wp-admin/"
    echo -e "  ${CYAN}管理员${NC}     ${WP_ADMIN_USER}"
    echo -e "  ${CYAN}密码${NC}       ${WP_ADMIN_PASS}"
    echo ""
    echo -e "  凭据已保存至: ${cred_file}"
    echo ""
    echo -e "  ${YELLOW}提示:${NC} 在浏览器打开 http://${SERVER_IP}/ 即可测试 WP 加载速度"
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
    SITE_URL="http://${SERVER_IP}"

    info "服务器 IP: ${SERVER_IP}"

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
    open_firewall

    # 重启服务确保一切生效
    systemctl restart nginx
    restart_php_fpm

    CRED_FILE="$(save_credentials)"
    print_summary "$CRED_FILE"
}

main "$@"
