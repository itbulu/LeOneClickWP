#!/usr/bin/env bash
# leoneclickwp - 卸载 WordPress 及环境（便于重新测速）
# 用法: sudo bash uninstall.sh

set -euo pipefail

WP_DIR="${WP_DIR:-/var/www/wordpress}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wpuser}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }

echo ""
echo -e "${RED}警告: 此操作将删除 WordPress 文件、数据库和 Nginx 配置${NC}"
read -rp "确认卸载? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "已取消"; exit 0; }

info "停止并清理 Nginx 配置..."
rm -f /etc/nginx/conf.d/wordpress.conf
rm -f /etc/nginx/sites-available/wordpress
rm -f /etc/nginx/sites-enabled/wordpress
# 恢复 Debian 默认站点以便 Nginx 仍可运行
if [[ -f /etc/nginx/sites-available/default ]] && [[ ! -L /etc/nginx/sites-enabled/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
fi
systemctl reload nginx 2>/dev/null || true

info "删除 WordPress 文件..."
rm -rf "$WP_DIR"

info "删除数据库..."
mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true

info "删除凭据文件..."
rm -f /root/leoneclickwp-credentials.txt

ok "卸载完成。如需完全移除 Nginx/PHP/MariaDB，请手动执行:"
echo "  apt purge nginx mariadb-server php* -y   # Debian/Ubuntu"
echo "  dnf remove nginx mariadb-server php* -y  # CentOS/RHEL"
