# LeOneClickWP

> Linux VPS 一键安装 WordPress，安装完成后通过服务器 IP 即可访问全新 WordPress 站点，用于测试 VPS 打开 WordPress 的速度。

- **GitHub 仓库**：[https://github.com/itbulu/LeOneClickWP](https://github.com/itbulu/LeOneClickWP)
- **官方网站**：[https://www.itbulu.com/leoneclickwp.html](https://www.itbulu.com/leoneclickwp.html)

---

## 简介

**LeOneClickWP** 是一款面向云服务器 Linux VPS 的 Shell 一键部署脚本。无需手动配置 LAMP/LEMP 环境，也无需在浏览器中逐步完成 WordPress 安装向导——脚本会自动完成全部流程，最终在 `http://你的服务器IP/` 呈现一个可直接访问的 WordPress 默认站点。

适合场景：

- 对比不同 VPS 厂商 / 机房 / 配置下的 WordPress 加载速度
- 快速搭建临时 WordPress 测试环境
- 验证新购服务器的基础 Web 运行能力

## 功能特性

- 自动安装 **Nginx + PHP-FPM + MariaDB**
- 自动下载并部署最新版 **WordPress**
- 使用 **WP-CLI** 静默完成 WordPress 初始化（跳过安装向导）
- 自动配置 Nginx 监听 **80 端口**，支持 **IP 访问** 或 **绑定域名**
- 可选导入 **[WP Test](https://github.com/poststatus/wptest)** 测试数据包（文章/页面/媒体）
- 开启 **PHP OPcache**，利于性能测试
- 自动放行防火墙 **80 端口**（UFW / firewalld）
- 安装完成后输出管理员账号密码，并保存至凭据文件
- 提供 **uninstall.sh** 一键卸载，便于重复测速

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu / Debian / CentOS / Rocky / AlmaLinux / RHEL |
| 权限 | root 或 sudo |
| 内存 | 建议 ≥ 1 GB |
| 网络 | 需能访问 wordpress.org、github.com（导入测试数据时还需拉取 wptest.xml 及附件） |

## 快速安装（推荐）

SSH 登录 VPS 后，执行以下命令：

```bash
curl -fsSL https://raw.githubusercontent.com/itbulu/LeOneClickWP/main/install.sh | bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/itbulu/LeOneClickWP/main/install.sh | bash
```

## 手动安装

```bash
git clone https://github.com/itbulu/LeOneClickWP.git
cd LeOneClickWP
chmod +x install.sh
sudo bash install.sh
```

安装过程中会提示选择访问方式：

1. **仅 IP 访问** — 适合快速测速，安装后通过 `http://服务器IP/` 访问  
2. **绑定域名** — 输入域名后，脚本会配置 Nginx 与 WordPress 站点地址（需提前将域名 A 记录解析到服务器 IP）

随后会询问是否导入测试数据：

1. **不导入** — 干净默认站点（推荐纯测速）  
2. **导入 WP Test** — 使用 [poststatus/wptest](https://github.com/poststatus/wptest) 数据包，含大量文章、页面与媒体附件，更接近真实站点负载

> 通过 `curl | bash` 安装时也会弹出交互选择（从终端读取输入）。若需完全静默安装，请设置 `NONINTERACTIVE=1`。

也可以只下载安装脚本：

```bash
wget https://raw.githubusercontent.com/itbulu/LeOneClickWP/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

## 安装完成后

脚本执行成功后，终端会显示访问信息，同时凭据会保存至：

```
/root/leoneclickwp-credentials.txt
```

| 项目 | 地址 / 说明 |
|------|-------------|
| 网站首页 | `http://你的IP/` 或 `http://你的域名/`（取决于安装时选择） |
| 后台登录 | 首页地址 + `/wp-admin/` |
| 默认管理员 | `admin`（密码由脚本随机生成） |

在浏览器中打开首页，即可看到 WordPress 站点：

- 未导入测试数据时：默认主题 + **Speed Test Page**
- 已导入测试数据时：含 [WP Test](https://github.com/poststatus/wptest) 示例文章、页面与媒体内容

> **注意**：除脚本内的防火墙配置外，还需在云厂商控制台的安全组中放行 **TCP 80** 端口，否则外网无法访问。

## 自定义配置

### 交互式选择（默认）

手动运行 `bash install.sh` 时，脚本会依次询问：

1. 使用 **IP** 还是 **域名**
2. 是否导入 **WP Test** 测试数据

### 环境变量（非交互 / 自动化）

安装前可通过环境变量覆盖默认值：

```bash
# IP 模式（非交互，等同选择 1）
SITE_MODE=ip NONINTERACTIVE=1 sudo bash install.sh

# 域名模式（等同选择 2）
WP_DOMAIN=wp.example.com sudo bash install.sh

# 同时导入 WP Test 测试数据
WP_DOMAIN=wp.example.com IMPORT_TESTDATA=1 sudo bash install.sh
```

```bash
WP_TITLE="我的测速站点" \
WP_ADMIN_USER="admin" \
WP_ADMIN_EMAIL="you@example.com" \
WP_LANG="zh_CN" \
sudo bash install.sh
```

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `SITE_MODE` | （交互选择） | 访问方式：`ip` 或 `domain` |
| `WP_DOMAIN` | — | 绑定域名（设置后自动启用域名模式） |
| `IMPORT_TESTDATA` | （交互选择） | `1` 导入 WP Test，`0` 跳过；非交互默认 `0` |
| `NONINTERACTIVE` | `0` | 设为 `1` 跳过全部交互；默认 IP 且不导入测试数据 |
| `WP_DIR` | `/var/www/wordpress` | WordPress 安装目录 |
| `WP_TITLE` | `WordPress Speed Test` | 站点标题 |
| `WP_ADMIN_USER` | `admin` | 管理员用户名 |
| `WP_ADMIN_PASS` | 随机生成 | 管理员密码（可预设） |
| `WP_ADMIN_EMAIL` | `admin@example.com` | 管理员邮箱 |
| `WP_LANG` | `zh_CN` | 语言包（设为 `en_US` 使用英文） |
| `DB_NAME` | `wordpress` | 数据库名 |
| `DB_USER` | `wpuser` | 数据库用户名 |
| `DB_PASS` | 随机生成 | 数据库密码（可预设） |
| `SKIP_FIREWALL` | `0` | 设为 `1` 跳过防火墙配置 |

示例：使用固定管理员密码：

```bash
WP_ADMIN_PASS="YourSecurePass123" sudo bash install.sh
```

## 卸载

如需清理 WordPress 并重新测试，可执行：

```bash
curl -fsSL https://raw.githubusercontent.com/itbulu/LeOneClickWP/main/uninstall.sh | bash
```

或在本仓库目录下：

```bash
sudo bash uninstall.sh
```

卸载脚本会删除 WordPress 文件、数据库、Nginx 站点配置及凭据文件。Nginx / PHP / MariaDB 等基础软件需手动卸载（脚本结束时会提示对应命令）。

## 测速建议

1. **安全组**：确保云厂商控制台已放行 80 端口
2. **预热**：首次访问可能较慢（OPcache 尚未预热），建议多刷新几次后再测
3. **工具**：可使用浏览器 DevTools Network 面板查看 TTFB，或使用 [WebPageTest](https://www.webpagetest.org/) 等在线工具
4. **对比**：在相同 WordPress 版本、相同脚本配置下对比不同 VPS，结果更具参考价值

## 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本 |
| `uninstall.sh` | 卸载脚本 |
| `README.md` | 项目说明文档 |

## 常见问题

**Q: 安装失败提示无法连接 MariaDB？**

确认 MariaDB 服务已启动：

```bash
systemctl status mariadb
```

**Q: 浏览器无法访问，但脚本显示安装成功？**

检查云厂商安全组是否放行 80 端口，以及服务器本地防火墙。若使用域名，还需确认 DNS A 记录已生效：

```bash
dig +short 你的域名
```

**Q: 域名模式安装后打开域名无法访问？**

1. 确认域名 A 记录指向服务器公网 IP  
2. DNS 生效可能需要几分钟至数小时  
3. 凭据文件中会同时记录域名与服务器 IP 供核对

**Q: 导入测试数据很慢或失败？**

WP Test 含媒体附件，需从外网下载，耗时取决于服务器带宽与 GitHub 连通性。失败时站点仍可正常使用。也可稍后手动导入：

```bash
cd /var/www/wordpress
wp plugin install wordpress-importer --activate --allow-root
curl -fsSL -o /tmp/wptest.xml https://raw.githubusercontent.com/poststatus/wptest/master/wptest.xml
wp import /tmp/wptest.xml --authors=create --allow-root
```

**Q: 如何查看安装凭据？**

```bash
cat /root/leoneclickwp-credentials.txt
```

## 免责声明

本脚本会自动安装系统软件并修改 Nginx、MariaDB 等配置，请在**测试用途的 VPS** 上使用。生产环境部署前请自行评估安全性，并及时修改默认密码、配置 HTTPS 等安全措施。

## 相关链接

- GitHub：[https://github.com/itbulu/LeOneClickWP](https://github.com/itbulu/LeOneClickWP)
- 官网：[https://www.itbulu.com/leoneclickwp.html](https://www.itbulu.com/leoneclickwp.html)

## License

MIT
