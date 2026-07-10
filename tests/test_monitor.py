#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""srvpulse 核心逻辑单元测试（stdlib unittest，无额外依赖）"""

import base64
import hashlib
import hmac
import logging
import os
import sys
import unittest
from collections import namedtuple

# 将项目根目录加入 path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import monitor


class TestFeishuSign(unittest.TestCase):
    def test_gen_feishu_sign_matches_official_algorithm(self):
        timestamp = 1599360473
        secret = "demo-secret"
        string_to_sign = f"{timestamp}\n{secret}"
        expected = base64.b64encode(
            hmac.new(
                string_to_sign.encode("utf-8"),
                msg=b"",
                digestmod=hashlib.sha256,
            ).digest()
        ).decode("utf-8")

        self.assertEqual(monitor.gen_feishu_sign(timestamp, secret), expected)


class TestEvaluateAlerts(unittest.TestCase):
    def setUp(self):
        monitor.logger = logging.getLogger("srvpulse-test")
        self.config = {"consecutive_count": 3}

    def test_not_enough_consecutive_count_no_candidate(self):
        state = {}
        metrics = {"cpu": {"value": 95, "threshold": 90, "name": "CPU"}}
        for _ in range(2):
            candidates = monitor.evaluate_alerts(metrics, state, self.config)
        self.assertEqual(candidates, [])
        self.assertEqual(state["cpu"]["count"], 2)

    def test_triggers_after_consecutive_count(self):
        state = {}
        metrics = {"cpu": {"value": 95, "threshold": 90, "name": "CPU"}}
        candidates = []
        for _ in range(3):
            candidates = monitor.evaluate_alerts(metrics, state, self.config)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["name"], "CPU")
        self.assertFalse(state["cpu"]["alerted"])

    def test_no_repeat_while_already_alerted(self):
        state = {"cpu": {"count": 3, "alerted": True}}
        metrics = {"cpu": {"value": 95, "threshold": 90, "name": "CPU"}}
        candidates = monitor.evaluate_alerts(metrics, state, self.config)
        self.assertEqual(candidates, [])

    def test_recovery_resets_count_and_alerted(self):
        state = {"cpu": {"count": 3, "alerted": True}}
        metrics = {"cpu": {"value": 50, "threshold": 90, "name": "CPU"}}
        monitor.evaluate_alerts(metrics, state, self.config)
        self.assertEqual(state["cpu"]["count"], 0)
        self.assertFalse(state["cpu"]["alerted"])


class TestDiskPartitionFilter(unittest.TestCase):
    Partition = namedtuple("Partition", "device fstype mountpoint")

    def test_skip_overlay_and_tmpfs(self):
        cases = [
            (self.Partition("overlay", "overlay", "/var/lib/docker/overlay2/x/merged"), True),
            (self.Partition("", "tmpfs", "/run"), True),
            (self.Partition("/dev/sda1", "ext4", "/"), False),
            (self.Partition("/dev/sdb1", "xfs", "/data"), False),
        ]
        exclude_fstypes = {x.lower() for x in monitor.DEFAULT_EXCLUDE_FSTYPES}
        for part, should_skip in cases:
            skip, _ = monitor._should_skip_disk_partition(
                part, exclude_fstypes, monitor.DEFAULT_EXCLUDE_PATH_CONTAINS
            )
            self.assertEqual(skip, should_skip, msg=part.mountpoint)


class TestResolveDiskTargets(unittest.TestCase):
    def test_manual_paths_only(self):
        disk_config = {
            "auto_discover": False,
            "default_threshold": 90,
            "paths": [
                {"path": "/data", "threshold": 85},
            ],
        }
        targets = monitor.resolve_disk_targets(disk_config)
        self.assertEqual(len(targets), 1)
        self.assertEqual(targets[0]["path"], "/data")
        self.assertEqual(targets[0]["threshold"], 85)


if __name__ == "__main__":
    unittest.main()
