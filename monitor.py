#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
轻量级服务器资源监控告警脚本

功能：
  定时采集CPU、内存、磁盘使用率，连续超标后通过飞书自定义机器人发送告警。

核心设计：
  - 事务级文件锁保护状态读写（覆盖整个 load→modify→save 周期）
  - 原地写入状态文件（truncate + write + fsync），避免 rename 导致锁失效
  - 只有飞书发送成功才标记 alerted=True，防止告警丢失
  - 严格的配置校验，启动时发现配置错误立即退出
  - 跨平台文件锁：Linux 使用 fcntl.flock，Windows 使用 msvcrt.locking

用法：
  python monitor.py              # 正常执行监控
  python monitor.py --test       # 发送测试消息到飞书
  python monitor.py --check      # 仅校验配置文件，不采集不发送
"""

import sys

MIN_PYTHON = (3, 6)
if sys.version_info < MIN_PYTHON:
    sys.stderr.write(
        "ERROR: 需要 Python {maj}.{min} 或更高版本，当前: {ver}\n".format(
            maj=MIN_PYTHON[0],
            min=MIN_PYTHON[1],
            ver=sys.version.split()[0],
        )
    )
    sys.exit(1)

import os
import json
import time
import socket
import hashlib
import base64
import hmac
import logging
import argparse
import platform
from datetime import datetime

import psutil
import requests
import yaml

# ============ 跨平台文件锁适配 ============

_IS_WINDOWS = platform.system() == "Windows"

if _IS_WINDOWS:
    import msvcrt

    def _flock_ex(fd):
        """Windows: 通过 msvcrt.locking 获取排他锁，阻塞直到获得锁。"""
        # msvcrt.locking 只锁当前偏移处的 1 字节，加锁/解锁必须在同一位置
        fd.seek(0)
        msvcrt.locking(fd.fileno(), msvcrt.LK_LOCK, 1)

    def _flock_un(fd):
        """Windows: 释放锁。"""
        try:
            fd.seek(0)
            msvcrt.locking(fd.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError as e:
            logger.warning(f"释放状态文件锁失败（可忽略）: {e}")

    def _fsync_fd(fd):
        """Windows: fsync 等价于 flush + os.fsync。"""
        fd.flush()
        os.fsync(fd.fileno())

else:
    import fcntl

    def _flock_ex(fd):
        """Linux: 通过 fcntl.flock 获取排他锁。"""
        fcntl.flock(fd, fcntl.LOCK_EX)

    def _flock_un(fd):
        """Linux: 释放锁。"""
        fcntl.flock(fd, fcntl.LOCK_UN)

    def _fsync_fd(fd):
        fd.flush()
        os.fsync(fd.fileno())


# ============ 常量 ============

INSTALL_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(INSTALL_DIR, "config.yaml")
STATE_FILE = os.path.join(INSTALL_DIR, "state.json")
SCRIPT_NAME = "srvpulse"

VALID_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR"}

# 自动发现磁盘时默认排除的虚拟/容器文件系统（Docker overlay 等常显示 100%）
DEFAULT_EXCLUDE_FSTYPES = {
    "overlay", "aufs", "tmpfs", "devtmpfs", "sysfs", "proc",
    "cgroup", "cgroup2", "squashfs", "devpts", "mqueue",
    "hugetlbfs", "debugfs", "tracefs", "fusectl", "securityfs",
    "pstore", "bpf", "autofs", "configfs", "rpc_pipefs", "nsfs",
    "binfmt_misc", "efivarfs",
}

# 路径包含以下片段的挂载点视为容器层，跳过监控
DEFAULT_EXCLUDE_PATH_CONTAINS = (
    "/docker/",
    "/containers/",
    "/kubelet/",
    "/overlay2/",
    "/merged",
    "/var/lib/docker",
)

# ============ 配置加载与校验 ============


def load_config():
    """加载并校验配置文件，失败时打印错误并 exit(1)"""
    if not os.path.exists(CONFIG_FILE):
        print(f"ERROR: 配置文件不存在: {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)

    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"ERROR: 配置文件格式错误: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: 读取配置文件失败: {e}", file=sys.stderr)
        sys.exit(1)

    if config is None:
        print("ERROR: 配置文件为空", file=sys.stderr)
        sys.exit(1)

    validate_config(config)
    return config


def validate_config(config):
    """
    校验配置项完整性和合法性。

    校验失败时打印所有错误并 exit(1)。
    """
    errors = []

    # ---- 基础配置 ----
    if "consecutive_count" not in config:
        config["consecutive_count"] = 3
    elif not isinstance(config["consecutive_count"], int) or config["consecutive_count"] < 1:
        errors.append("consecutive_count 必须是正整数")

    if "log_level" not in config:
        config["log_level"] = "INFO"
    elif str(config["log_level"]).upper() not in VALID_LOG_LEVELS:
        errors.append(
            f"log_level 必须为 {' / '.join(sorted(VALID_LOG_LEVELS))} 之一，"
            f"当前值: {config['log_level']}"
        )

    # ---- 监控项配置 ----
    if "monitors" not in config:
        errors.append("缺少 monitors 配置节")
    else:
        monitors = config["monitors"]
        for name in ["cpu", "memory", "disk"]:
            if name not in monitors:
                errors.append(f"缺少 monitors.{name} 配置节")
                continue

            m = monitors[name]
            if not isinstance(m.get("enabled", True), bool):
                errors.append(f"monitors.{name}.enabled 必须是布尔值")

            if name == "disk":
                if "auto_discover" not in m:
                    m["auto_discover"] = False
                elif not isinstance(m["auto_discover"], bool):
                    errors.append("monitors.disk.auto_discover 必须是布尔值")

                if "default_threshold" not in m:
                    m["default_threshold"] = 90
                elif (
                    not isinstance(m["default_threshold"], (int, float))
                    or not (1 <= m["default_threshold"] <= 100)
                ):
                    errors.append(
                        "monitors.disk.default_threshold "
                        f"必须在 1-100 之间，当前值: {m['default_threshold']}"
                    )

                if "paths" not in m:
                    m["paths"] = []
                elif not isinstance(m["paths"], list):
                    errors.append("monitors.disk.paths 必须配置为列表")
                else:
                    for i, p in enumerate(m["paths"]):
                        if not isinstance(p, dict):
                            errors.append(f"monitors.disk.paths[{i}] 必须为字典")
                            continue
                        if "path" not in p:
                            errors.append(f"monitors.disk.paths[{i}] 缺少 path")
                        if "threshold" not in p:
                            errors.append(f"monitors.disk.paths[{i}] 缺少 threshold")
                        elif (
                            not isinstance(p["threshold"], (int, float))
                            or not (1 <= p["threshold"] <= 100)
                        ):
                            errors.append(
                                f"monitors.disk.paths[{i}].threshold "
                                f"必须在 1-100 之间，当前值: {p['threshold']}"
                            )

                if not m.get("auto_discover") and not m.get("paths"):
                    errors.append(
                        "monitors.disk 需启用 auto_discover，"
                        "或至少手动配置一个 paths 项"
                    )

                if "exclude_fstypes" in m:
                    if not isinstance(m["exclude_fstypes"], list):
                        errors.append("monitors.disk.exclude_fstypes 必须为列表")
                    else:
                        for i, fstype in enumerate(m["exclude_fstypes"]):
                            if not isinstance(fstype, str) or not fstype.strip():
                                errors.append(
                                    f"monitors.disk.exclude_fstypes[{i}] 必须为非空字符串"
                                )

                if "exclude_path_contains" in m:
                    if not isinstance(m["exclude_path_contains"], list):
                        errors.append("monitors.disk.exclude_path_contains 必须为列表")
                    else:
                        for i, pattern in enumerate(m["exclude_path_contains"]):
                            if not isinstance(pattern, str) or not pattern.strip():
                                errors.append(
                                    "monitors.disk.exclude_path_contains"
                                    f"[{i}] 必须为非空字符串"
                                )
            else:
                if "threshold" not in m:
                    errors.append(f"monitors.{name} 缺少 threshold")
                elif not isinstance(m["threshold"], (int, float)) or not (1 <= m["threshold"] <= 100):
                    errors.append(
                        f"monitors.{name}.threshold "
                        f"必须在 1-100 之间，当前值: {m['threshold']}"
                    )

    # ---- 飞书配置 ----
    if "feishu" not in config:
        errors.append("缺少 feishu 配置节")
    else:
        feishu = config["feishu"]
        if not isinstance(feishu, dict):
            errors.append("feishu 配置必须为字典")
        else:
            if not feishu.get("webhook_url"):
                errors.append("feishu.webhook_url 不能为空")
            elif not feishu["webhook_url"].startswith("https://open.feishu.cn/"):
                errors.append(
                    "feishu.webhook_url 格式不正确，"
                    "应以 https://open.feishu.cn/ 开头"
                )
            if not feishu.get("secret"):
                errors.append("feishu.secret 不能为空")

            if "timeout" in feishu:
                if not isinstance(feishu["timeout"], (int, float)) or feishu["timeout"] <= 0:
                    errors.append(
                        f"feishu.timeout 必须为正数，当前值: {feishu['timeout']}"
                    )
            else:
                feishu["timeout"] = 5

            if "max_retries" in feishu:
                if not isinstance(feishu["max_retries"], int) or feishu["max_retries"] < 0:
                    errors.append(
                        f"feishu.max_retries 必须为非负整数，当前值: {feishu['max_retries']}"
                    )
            else:
                feishu["max_retries"] = 3

    if errors:
        print("ERROR: 配置校验失败:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)


# ============ 日志配置 ============


def setup_logging(config):
    """根据配置设置日志级别和格式"""
    log_level_str = str(config.get("log_level", "INFO")).upper()
    log_level = getattr(logging, log_level_str, logging.INFO)
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)]
    )
    return logging.getLogger(SCRIPT_NAME)


# ============ 状态管理 ============


def get_default_state():
    """返回默认空状态"""
    return {}


def _ensure_metric_state(state, metric_key):
    """确保状态字典中存在指定指标的状态项"""
    if metric_key not in state:
        state[metric_key] = {
            "count": 0,
            "alerted": False
        }
    return state[metric_key]


class StateManager:
    """
    状态管理器：事务级文件锁保护「读取 -> 修改 -> 写入」全流程。

    关键设计决策：
      - 使用跨平台排他锁锁住整个事务，而非分别锁 load 和 save
      - 在持有锁期间原地写入（truncate + write + fsync），
        避免 atomic rename 导致锁住旧 inode 而新文件未受保护的问题
      - 退出时设置文件权限为 600（Unix）或仅保留（Windows）

    用法:
        with StateManager(STATE_FILE) as state:
            state["cpu"]["count"] += 1
            # __exit__ 自动保存
    """

    def __init__(self, state_file):
        self.state_file = state_file
        self._fd = None
        self.state = None

    def __enter__(self):
        state_dir = os.path.dirname(self.state_file)
        os.makedirs(state_dir, exist_ok=True)

        # 打开文件并获取排他锁
        self._fd = open(self.state_file, "a+")
        _flock_ex(self._fd)

        # 读取状态
        try:
            self._fd.seek(0)
            content = self._fd.read()
            if content.strip():
                self.state = json.loads(content)
            else:
                logger.debug("状态文件为空，使用默认状态")
                self.state = get_default_state()
        except json.JSONDecodeError as e:
            logger.warning(f"状态文件损坏，自动重置: {e}")
            self.state = get_default_state()
        except Exception as e:
            logger.error(f"读取状态文件失败，使用默认状态: {e}")
            self.state = get_default_state()

        return self.state

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if self.state is not None:
                # 在持有锁的情况下原地写入（避免 rename 导致锁失效）
                self._fd.seek(0)
                self._fd.truncate()
                json.dump(self.state, self._fd, indent=2, ensure_ascii=False)
                self._fd.flush()
                _fsync_fd(self._fd)
                logger.debug("状态文件已保存")
        except Exception as e:
            logger.error(f"保存状态文件失败: {e}")
        finally:
            if self._fd:
                _flock_un(self._fd)
                self._fd.close()

        # 设置权限为 600（Unix only）
        if not _IS_WINDOWS:
            try:
                os.chmod(self.state_file, 0o600)
            except Exception:
                pass

        return False  # 不抑制 with 块内部的异常


# ============ 资源采集 ============


def get_cpu_usage():
    """获取CPU使用率（1秒采样平均值）"""
    try:
        return psutil.cpu_percent(interval=1)
    except Exception as e:
        logger.error(f"采集CPU数据失败: {e}")
        return None


def get_memory_usage():
    """获取内存使用率"""
    try:
        return psutil.virtual_memory().percent
    except Exception as e:
        logger.error(f"采集内存数据失败: {e}")
        return None


def get_disk_usage(path):
    """获取指定路径的磁盘使用率"""
    try:
        return psutil.disk_usage(path).percent
    except FileNotFoundError:
        logger.warning(f"磁盘路径不存在，跳过: {path}")
        return None
    except PermissionError:
        logger.warning(f"无权限访问磁盘路径，跳过: {path}")
        return None
    except Exception as e:
        logger.error(f"采集磁盘数据失败 ({path}): {e}")
        return None


def _normalize_mount_path(path):
    """统一挂载点路径格式，便于比较"""
    return os.path.normcase(os.path.normpath(path))


def _should_skip_disk_partition(partition, exclude_fstypes, exclude_path_contains):
    """判断挂载点是否应跳过（Docker overlay、tmpfs 等虚挂载）"""
    fstype = (partition.fstype or "").lower()
    if fstype in exclude_fstypes:
        return True, f"虚拟/容器文件系统 ({fstype})"

    mountpoint = partition.mountpoint.replace("\\", "/")
    mount_lower = mountpoint.lower()
    for pattern in exclude_path_contains:
        pattern_norm = pattern.replace("\\", "/").lower()
        if pattern_norm in mount_lower:
            return True, f"路径匹配排除规则 ({pattern})"

    return False, None


def _find_partition_for_path(path):
    """根据挂载路径查找对应分区信息"""
    path_norm = _normalize_mount_path(path)
    for part in psutil.disk_partitions(all=False):
        if _normalize_mount_path(part.mountpoint) == path_norm:
            return part
    return None


def resolve_disk_targets(disk_config):
    """
    解析磁盘监控目标：支持自动发现真实磁盘 + 手动补充。

    自动发现时会排除 Docker overlay 等常显示 100% 的虚挂载，
    并按物理设备去重，避免同一硬盘重复告警。
    """
    default_threshold = disk_config.get("default_threshold", 90)
    exclude_fstypes = {
        item.lower()
        for item in disk_config.get("exclude_fstypes", DEFAULT_EXCLUDE_FSTYPES)
    }
    exclude_path_contains = disk_config.get(
        "exclude_path_contains", DEFAULT_EXCLUDE_PATH_CONTAINS
    )

    targets = {}
    devices_seen = set()

    for item in disk_config.get("paths", []):
        path = item["path"]
        targets[path] = {
            "path": path,
            "threshold": item.get("threshold", default_threshold),
            "name": f"磁盘({path})",
        }
        part = _find_partition_for_path(path)
        if part:
            devices_seen.add(part.device)

    if disk_config.get("auto_discover", False):
        for part in psutil.disk_partitions(all=False):
            skip, reason = _should_skip_disk_partition(
                part, exclude_fstypes, exclude_path_contains
            )
            if skip:
                logger.debug(f"跳过挂载 {part.mountpoint}: {reason}")
                continue

            mountpoint = part.mountpoint
            if mountpoint in targets:
                continue

            if part.device in devices_seen:
                logger.debug(
                    f"跳过挂载 {mountpoint}: 设备 {part.device} 已由其他挂载点监控"
                )
                continue

            devices_seen.add(part.device)
            fstype = part.fstype or "unknown"
            targets[mountpoint] = {
                "path": mountpoint,
                "threshold": default_threshold,
                "name": f"磁盘({mountpoint}) [{fstype}]",
            }

    return list(targets.values())


def get_server_ip():
    """获取服务器主IP地址，失败返回 'unknown'"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        except Exception:
            ip = socket.gethostbyname(socket.gethostname())
        finally:
            s.close()
        return ip
    except Exception:
        return "unknown"


# ============ 飞书告警 ============


def gen_feishu_sign(timestamp: int, secret: str) -> str:
    """
    生成飞书机器人签名。

    算法：对 "{timestamp}\n{secret}" 做 HMAC-SHA256，结果 Base64 编码。
    参考：https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot
    """
    string_to_sign = f"{timestamp}\n{secret}"
    hmac_code = hmac.new(
        string_to_sign.encode("utf-8"),
        msg=b"",
        digestmod=hashlib.sha256
    ).digest()
    return base64.b64encode(hmac_code).decode("utf-8")


def send_feishu_alert(alerts: list, hostname: str, ip: str, config: dict) -> bool:
    """
    发送告警消息到飞书，支持重试。

    参数:
        alerts: 告警指标列表，每项包含 name/value/threshold
        hostname: 服务器主机名
        config: 完整配置字典

    返回:
        True:  发送成功
        False: 发送失败（调用方不应标记 alerted=True）
    """
    if not alerts:
        return True

    feishu_config = config["feishu"]
    max_retries = feishu_config.get("max_retries", 3)
    timeout = feishu_config.get("timeout", 5)

    timestamp = int(time.time())
    sign = gen_feishu_sign(timestamp, feishu_config["secret"])

    # 构建消息
    lines = [f"⚠️ 服务器资源告警 - {hostname} ({ip})"]
    for alert in alerts:
        lines.append(
            f"• {alert['name']}: {alert['value']:.1f}% "
            f"(阈值 {alert['threshold']}%)"
        )
    lines.append(f"⏰ 时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    payload = {
        "timestamp": str(timestamp),
        "sign": sign,
        "msg_type": "text",
        "content": {"text": "\n".join(lines)}
    }

    for attempt in range(max_retries):
        try:
            resp = requests.post(
                feishu_config["webhook_url"],
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=timeout
            )

            # 先检查 HTTP 状态码
            try:
                resp.raise_for_status()
            except requests.exceptions.HTTPError:
                logger.warning(
                    f"飞书返回 HTTP {resp.status_code} "
                    f"(第 {attempt + 1}/{max_retries} 次尝试)"
                )
                if attempt < max_retries - 1:
                    time.sleep(1)
                continue

            # 再解析 JSON 业务响应
            try:
                result = resp.json()
            except ValueError:
                logger.warning(
                    f"飞书返回非 JSON 响应 "
                    f"(第 {attempt + 1}/{max_retries} 次尝试)"
                )
                if attempt < max_retries - 1:
                    time.sleep(1)
                continue

            # 检查业务状态码
            if result.get("code") == 0:
                logger.info(f"告警发送成功: {len(alerts)} 个指标")
                return True
            else:
                logger.warning(
                    f"飞书返回业务错误: code={result.get('code')}, "
                    f"msg={result.get('msg')} "
                    f"(第 {attempt + 1}/{max_retries} 次尝试)"
                )

        except requests.exceptions.Timeout:
            logger.warning(
                f"发送告警超时 ({timeout}s) "
                f"(第 {attempt + 1}/{max_retries} 次尝试)"
            )
        except requests.exceptions.ConnectionError as e:
            logger.warning(
                f"连接飞书失败: {e} "
                f"(第 {attempt + 1}/{max_retries} 次尝试)"
            )
        except requests.exceptions.RequestException as e:
            logger.warning(
                f"发送告警请求异常: {e} "
                f"(第 {attempt + 1}/{max_retries} 次尝试)"
            )

        if attempt < max_retries - 1:
            time.sleep(1)

    logger.error(f"发送告警最终失败，已重试 {max_retries} 次")
    return False


def send_test_message(config):
    """
    发送测试消息到飞书，用于验证配置是否正确。

    返回:
        True:  发送成功
        False: 发送失败
    """
    feishu_config = config["feishu"]
    hostname = socket.gethostname()
    ip = get_server_ip()
    timestamp = int(time.time())
    sign = gen_feishu_sign(timestamp, feishu_config["secret"])

    payload = {
        "timestamp": str(timestamp),
        "sign": sign,
        "msg_type": "text",
        "content": {
            "text": (
                f"✅ 监控系统测试消息\n"
                f"服务器: {hostname} ({ip})\n"
                f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
                f"配置正常，告警通道畅通"
            )
        }
    }

    try:
        resp = requests.post(
            feishu_config["webhook_url"],
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=feishu_config.get("timeout", 5)
        )

        try:
            resp.raise_for_status()
        except requests.exceptions.HTTPError:
            print(f"[FAIL] HTTP 错误: {resp.status_code}")
            return False

        try:
            result = resp.json()
        except ValueError:
            print("[FAIL] 飞书返回非 JSON 响应")
            return False

        if result.get("code") == 0:
            print("[OK] 测试消息发送成功！")
            return True
        else:
            print(
                f"[FAIL] 飞书返回业务错误: "
                f"code={result.get('code')}, msg={result.get('msg')}"
            )
            return False

    except requests.exceptions.Timeout:
        print(f"[FAIL] 请求超时 ({feishu_config.get('timeout', 5)}s)")
        return False
    except requests.exceptions.ConnectionError as e:
        print(f"[FAIL] 连接失败: {e}")
        return False
    except Exception as e:
        print(f"[FAIL] 发送失败: {e}")
        return False


# ============ 主逻辑 ============


def collect_metrics(config):
    """
    采集所有已启用的监控指标。

    返回:
        dict: 采集失败或未启用的指标不会出现在结果中。
    """
    metrics = {}
    monitors = config.get("monitors", {})

    # CPU
    cpu_config = monitors.get("cpu", {})
    if cpu_config.get("enabled", True):
        cpu_value = get_cpu_usage()
        if cpu_value is not None:
            metrics["cpu"] = {
                "value": cpu_value,
                "threshold": cpu_config.get("threshold", 90),
                "name": "CPU"
            }

    # 内存
    mem_config = monitors.get("memory", {})
    if mem_config.get("enabled", True):
        mem_value = get_memory_usage()
        if mem_value is not None:
            metrics["memory"] = {
                "value": mem_value,
                "threshold": mem_config.get("threshold", 85),
                "name": "内存"
            }

    # 磁盘（自动发现 + 手动配置）
    disk_config = monitors.get("disk", {})
    if disk_config.get("enabled", True):
        disk_targets = resolve_disk_targets(disk_config)
        logger.debug(f"磁盘监控目标共 {len(disk_targets)} 个")
        for disk_item in disk_targets:
            disk_path = disk_item["path"]
            disk_value = get_disk_usage(disk_path)
            if disk_value is not None:
                key = f"disk_{disk_path}"
                metrics[key] = {
                    "value": disk_value,
                    "threshold": disk_item["threshold"],
                    "name": disk_item["name"],
                }

    return metrics


def evaluate_alerts(metrics, state, config):
    """
    评估哪些指标满足告警条件。

    对每个指标：
      - 如果超标：count += 1
      - 如果 count >= consecutive_count 且 alerted == False：
        加入候选列表（准备发送告警）
      - 如果恢复正常：count = 0, alerted = False

    注意：此函数只更新 count，不修改 alerted。
    alerted 由调用方在发送成功后设置。

    返回:
        list: 需要尝试发送告警的指标列表
    """
    consecutive_required = config.get("consecutive_count", 3)
    candidates = []

    for metric_key, metric_info in metrics.items():
        value = metric_info["value"]
        threshold = metric_info["threshold"]
        metric_state = _ensure_metric_state(state, metric_key)

        if value > threshold:
            metric_state["count"] += 1
            logger.debug(
                f"{metric_info['name']}: {value:.1f}% > {threshold}% "
                f"(连续超标 {metric_state['count']}/{consecutive_required})"
            )

            if (
                metric_state["count"] >= consecutive_required
                and not metric_state["alerted"]
            ):
                candidates.append({
                    "key": metric_key,
                    "name": metric_info["name"],
                    "value": value,
                    "threshold": threshold,
                })
        else:
            # 恢复正常
            if metric_state["count"] > 0 or metric_state["alerted"]:
                logger.info(
                    f"{metric_info['name']} 已恢复正常 "
                    f"({value:.1f}%)，重置状态"
                )
            metric_state["count"] = 0
            metric_state["alerted"] = False

    return candidates


def main():
    """主入口"""
    parser = argparse.ArgumentParser(
        description="服务器资源监控告警脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  python monitor.py              # 正常执行\n"
            "  python monitor.py --check      # 校验配置\n"
            "  python monitor.py --test       # 发送测试消息"
        )
    )
    parser.add_argument(
        "--test", action="store_true",
        help="发送测试消息到飞书"
    )
    parser.add_argument(
        "--check", action="store_true",
        help="仅校验配置文件，不采集不发送"
    )
    args = parser.parse_args()

    # 加载配置（含校验）
    config = load_config()

    # 配置日志
    global logger
    logger = setup_logging(config)

    # --check 模式
    if args.check:
        print("配置文件校验通过")
        disk_config = config.get("monitors", {}).get("disk", {})
        if disk_config.get("enabled", True):
            disk_targets = resolve_disk_targets(disk_config)
            print(f"磁盘监控目标: {len(disk_targets)} 个")
            for target in disk_targets:
                print(f"  - {target['name']} (阈值 {target['threshold']}%)")
        return

    # --test 模式
    if args.test:
        print("发送测试消息...")
        success = send_test_message(config)
        sys.exit(0 if success else 1)

    # 正常监控模式
    logger.info("=" * 50)
    logger.info("开始执行资源监控")

    # 1. 采集数据
    metrics = collect_metrics(config)
    if not metrics:
        logger.warning("未采集到任何指标数据，跳过本次检查")
        return

    for key, info in metrics.items():
        logger.info(
            f"{info['name']}: {info['value']:.1f}% "
            f"(阈值 {info['threshold']}%)"
        )

    # 2. 事务级文件锁保护状态读写
    with StateManager(STATE_FILE) as state:
        # 3. 评估告警条件
        candidates = evaluate_alerts(metrics, state, config)

        # 4. 发送告警
        if candidates:
            for c in candidates:
                logger.warning(
                    f"{c['name']} 连续超标，尝试发送告警 "
                    f"(当前 {c['value']:.1f}%, 阈值 {c['threshold']}%)"
                )

            hostname = socket.gethostname()
            ip = get_server_ip()
            success = send_feishu_alert(candidates, hostname, ip, config)

            if success:
                # 只有发送成功才标记 alerted
                for c in candidates:
                    state[c["key"]]["alerted"] = True
                logger.info(
                    f"告警已标记: {[c['name'] for c in candidates]}"
                )
            else:
                # 发送失败不标记，下次 Cron 执行时重试
                logger.error(
                    "告警发送失败，状态未标记，下次执行时将重试"
                )
        else:
            logger.info("无需告警")

    # with 块退出时自动保存状态
    logger.info("监控执行完成")


# ============ 入口 ============

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n用户中断", file=sys.stderr)
        sys.exit(0)
    except Exception as e:
        try:
            logger.error(f"脚本执行异常: {e}", exc_info=True)
        except NameError:
            print(f"ERROR: 脚本执行异常: {e}", file=sys.stderr)
        sys.exit(1)