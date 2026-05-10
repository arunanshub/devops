#!/usr/bin/env python3
"""Tests for the OpenTofu-backed Ansible inventory."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("tofu_inventory.py")


def tofu_outputs(nodes: dict[str, dict[str, str]]) -> dict[str, object]:
    return {
        "cluster_name": {
            "sensitive": False,
            "type": "string",
            "value": "hetzner-k3s",
        },
        "api_lb_private_ip": {
            "sensitive": False,
            "type": "string",
            "value": "10.0.0.100",
        },
        "node_ipv6_addresses": {
            "sensitive": False,
            "type": ["object"],
            "value": {key: node["ipv6"] for key, node in nodes.items()},
        },
        "node_private_ips": {
            "sensitive": False,
            "type": ["object"],
            "value": {key: node["private_ip"] for key, node in nodes.items()},
        },
        "node_roles": {
            "sensitive": False,
            "type": ["object"],
            "value": {key: node["role"] for key, node in nodes.items()},
        },
        "ssh_private_key_path": {
            "sensitive": False,
            "type": "string",
            "value": "~/.ssh/id_ed25519",
        },
    }


def tofu_outputs_without_roles(nodes: dict[str, dict[str, str]]) -> dict[str, object]:
    outputs = tofu_outputs(nodes)
    del outputs["node_roles"]
    return outputs


def render_inventory(outputs: dict[str, object]) -> dict[str, object]:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8") as handle:
        json.dump(outputs, handle)
        handle.flush()

        env = os.environ.copy()
        env["ANSIBLE_TOFU_OUTPUTS"] = handle.name

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--list"],
            check=True,
            env=env,
            stdout=subprocess.PIPE,
            text=True,
        )

    return json.loads(result.stdout)


class TofuInventoryTest(unittest.TestCase):
    def test_groups_nodes_by_role_and_sets_hostvars(self) -> None:
        inventory = render_inventory(
            tofu_outputs(
                {
                    "cp-1": {
                        "ipv6": "2a01:4f8:1::1",
                        "private_ip": "10.0.0.2",
                        "role": "cp_worker",
                    },
                    "cp-2": {
                        "ipv6": "2a01:4f8:1::2",
                        "private_ip": "10.0.0.3",
                        "role": "cp_only",
                    },
                    "worker-1": {
                        "ipv6": "2a01:4f8:1::10",
                        "private_ip": "10.0.0.10",
                        "role": "worker",
                    },
                }
            )
        )

        self.assertEqual(
            inventory["k3s_nodes"]["hosts"],
            ["hetzner-k3s-cp-1", "hetzner-k3s-cp-2", "hetzner-k3s-worker-1"],
        )
        self.assertEqual(
            inventory["control_planes"]["hosts"],
            ["hetzner-k3s-cp-1", "hetzner-k3s-cp-2"],
        )
        self.assertEqual(inventory["workers"]["hosts"], ["hetzner-k3s-worker-1"])

        hostvars = inventory["_meta"]["hostvars"]["hetzner-k3s-cp-1"]
        self.assertEqual(hostvars["ansible_host"], "2a01:4f8:1::1")
        self.assertEqual(hostvars["ansible_user"], "root")
        self.assertEqual(hostvars["node_key"], "cp-1")
        self.assertEqual(hostvars["node_role"], "cp_worker")
        self.assertEqual(hostvars["node_private_ip"], "10.0.0.2")
        self.assertEqual(hostvars["kubernetes_node_name"], "hetzner-k3s-cp-1")
        self.assertEqual(hostvars["api_lb_private_ip"], "10.0.0.100")
        self.assertTrue(hostvars["ansible_private_key_file"].endswith("/.ssh/id_ed25519"))

    def test_removed_nodes_disappear_when_outputs_change(self) -> None:
        inventory = render_inventory(
            tofu_outputs(
                {
                    "cp-1": {
                        "ipv6": "2a01:4f8:1::1",
                        "private_ip": "10.0.0.2",
                        "role": "cp_worker",
                    },
                    "cp-3": {
                        "ipv6": "2a01:4f8:1::3",
                        "private_ip": "10.0.0.4",
                        "role": "cp_worker",
                    },
                }
            )
        )

        self.assertEqual(
            inventory["k3s_nodes"]["hosts"],
            ["hetzner-k3s-cp-1", "hetzner-k3s-cp-3"],
        )
        self.assertNotIn("hetzner-k3s-cp-2", inventory["_meta"]["hostvars"])

    def test_infers_groups_during_transition_before_node_roles_output_exists(self) -> None:
        inventory = render_inventory(
            tofu_outputs_without_roles(
                {
                    "cp-1": {
                        "ipv6": "2a01:4f8:1::1",
                        "private_ip": "10.0.0.2",
                        "role": "cp_worker",
                    },
                    "worker-1": {
                        "ipv6": "2a01:4f8:1::10",
                        "private_ip": "10.0.0.10",
                        "role": "worker",
                    },
                }
            )
        )

        self.assertEqual(inventory["control_planes"]["hosts"], ["hetzner-k3s-cp-1"])
        self.assertEqual(inventory["workers"]["hosts"], ["hetzner-k3s-worker-1"])
        self.assertEqual(
            inventory["_meta"]["hostvars"]["hetzner-k3s-cp-1"]["node_role"],
            "cp_worker",
        )


if __name__ == "__main__":
    unittest.main()
