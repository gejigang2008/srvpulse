# srvpulse

> 轻量级服务器资源监控告警工具 — 定时采集 CPU / 内存 / 磁盘使用率，连续超标后通过飞书机器人发送告警。

[![Python](https://img.shields.io/badge/Python-3.6--3.13+-blue.svg)](https://www.python.org/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows-green.svg)](https://kernel.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**srvpulse**（Server Pulse）是一个单文件 Python 监控脚本，配合 Cron 定时运行，无需额外服务。适合开发服务器、测试环境等场景的轻量资源告警。

---

## 功能特性

| 特性 | 说明 |
|------|------|
| **多指标监控** | CPU / 内存 / 磁盘，每个指标独立阈值 |
| **磁盘自动发现** | 自动扫描真实硬盘挂载，排除 Docker overlay 等虚挂载（常显示 100%） |
| **防抖动告警** | 连续超标 N 次才触发，避免瞬时波动误报 |
| **可靠送达** | 飞书 API 返回成功才标记已告警；失败自动重试 |
| **事务级状态** | 跨平台文件锁保护状态读写（Linux / Windows） |
| **Git 部署** | `git clone` 获取代码，`deploy.sh` 负责安装配置 |
| **Python 兼容** | 支持 Python 3.6 - 3.13+ |

---

## 快速开始

### 本地开发（Windows / Linux）

```bash
git clone git@github.com:gejigang2008/srvpulse.git
cd srvpulse

cp config.yaml.example config.yaml
vim config.yaml   # 填入 feishu.webhook_url 和 feishu.secret

pip install -r requirements.txt
python monitor.py --check   # 校验配置，列出磁盘监控目标
python monitor.py --test    # 测试飞书连通性
python monitor.py           # 手动执行一次监控
```

### 服务器部署（推荐 Git 方式）

```bash
# SSH 登录服务器后执行
sudo git clone git@github.com:gejigang2008/srvpulse.git /opt/srvpulse
cd /opt/srvpulse
sudo ./deploy.sh              # 交互式配置飞书 → 校验 → 安装 Cron
```

终端下 `deploy.sh` 会检测飞书配置：若为模板占位符，会提示交互填写；也可强制交互：

```bash
sudo ./deploy.sh --interactive
```

非交互环境（如 CI）需事先准备好 `config.yaml`：

```bash
sudo cp config.yaml.example config.yaml
sudo vim config.yaml
sudo ./deploy.sh
```

部署完成后：

```bash
sudo /opt/srvpulse/venv/bin/python /opt/srvpulse/monitor.py --test
tail -f /var/log/srvpulse.log
```

### 更新版本

```bash
cd /opt/srvpulse
sudo git pull
sudo ./deploy.sh
```

### 卸载

```bash
cd /opt/srvpulse
sudo ./uninstall.sh
```

---

## 配置说明

```yaml
log_level: INFO
consecutive_count: 3

monitors:
  cpu:
    enabled: true
    threshold: 90
  memory:
    enabled: true
    threshold: 85
  disk:
    enabled: true
    auto_discover: true       # 自动发现真实磁盘挂载
    default_threshold: 90
    paths: []                 # 可选：手动补充特定挂载点

feishu:
  webhook_url: "https://open.feishu.cn/open-apis/bot/v2/hook/..."
  secret: "YOUR_SECRET_KEY"
  timeout: 5
  max_retries: 3
```

完整方案见 [srvpulse 完整方案](./开发服务器资源监控告警系统%20—%20完整方案.md)

---

## 命令行用法

| 命令 | 说明 |
|------|------|
| `python monitor.py` | 正常执行监控采集与告警 |
| `python monitor.py --check` | 校验配置，并列出磁盘监控目标 |
| `python monitor.py --test` | 发送测试消息到飞书 |

---

## 安装路径

| 项目 | 路径 |
|------|------|
| 安装目录 | `/opt/srvpulse/` |
| 配置文件 | `/opt/srvpulse/config.yaml` |
| 状态文件 | `/opt/srvpulse/state.json` |
| 日志文件 | `/var/log/srvpulse.log` |
| Cron 配置 | `/etc/cron.d/srvpulse` |

---

## 项目结构

```
srvpulse/
├── monitor.py              # 主监控脚本
├── config.yaml.example     # 配置模板
├── requirements.txt        # Python 依赖
├── deploy.sh               # 安装脚本（venv + 配置 + Cron）
├── uninstall.sh            # 卸载脚本
└── README.md
```

---

## 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（生产部署）/ Windows（开发调试） |
| Python | 3.6 - 3.13+ |
| Git | 服务器部署需要 |
| 网络 | 可访问 `open.feishu.cn` 和 `github.com` |
| 权限 | Linux 部署需 root |

### 运行测试

```bash
python -m unittest discover -s tests -v
```

---

## License

MIT

---

*srvpulse v1.2.0 | [GitHub](https://github.com/gejigang2008/srvpulse)*
