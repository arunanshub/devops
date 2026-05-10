#!/usr/bin/env python3
"""OpenTofu output-backed dynamic inventory for the Hetzner k3s cluster."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TOFU_CHDIR = REPO_ROOT / "infra"
DEFAULT_CLUSTER_NAME = "hetzner-k3s"
KNOWN_HOSTS_FILE = REPO_ROOT / "infra" / ".ssh_known_hosts"


def output_value(outputs: dict[str, Any], name: str, default: Any) -> Any:
    entry = outputs.get(name)
    if isinstance(entry, dict) and "value" in entry:
        return entry["value"]
    return default


def load_outputs() -> dict[str, Any]:
    outputs_path = os.environ.get("ANSIBLE_TOFU_OUTPUTS")
    if outputs_path:
        with open(outputs_path, encoding="utf-8") as handle:
            return json.load(handle)

    tofu_chdir = os.environ.get("TOFU_CHDIR", str(DEFAULT_TOFU_CHDIR))
    result = subprocess.run(
        ["tofu", f"-chdir={tofu_chdir}", "output", "-json"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return json.loads(result.stdout)


def build_inventory(outputs: dict[str, Any]) -> dict[str, Any]:
    cluster_name = output_value(outputs, "cluster_name", DEFAULT_CLUSTER_NAME)
    api_lb_private_ip = output_value(outputs, "api_lb_private_ip", "")
    ssh_private_key_path = os.environ.get(
        "ANSIBLE_SSH_PRIVATE_KEY_FILE",
        output_value(outputs, "ssh_private_key_path", "~/.ssh/id_ed25519"),
    )
    node_ipv6_addresses = output_value(outputs, "node_ipv6_addresses", {})
    node_private_ips = output_value(outputs, "node_private_ips", {})
    node_roles = output_value(outputs, "node_roles", {})

    inventory: dict[str, Any] = {
        "_meta": {"hostvars": {}},
        "k3s_nodes": {"hosts": []},
        "control_planes": {"hosts": []},
        "workers": {"hosts": []},
    }

    for node_key in sorted(node_ipv6_addresses):
        hostname = f"{cluster_name}-{node_key}"
        role = node_roles.get(node_key, inferred_role(node_key))

        inventory["k3s_nodes"]["hosts"].append(hostname)
        if role in {"cp_only", "cp_worker"}:
            inventory["control_planes"]["hosts"].append(hostname)
        elif role == "worker":
            inventory["workers"]["hosts"].append(hostname)

        inventory["_meta"]["hostvars"][hostname] = {
            "ansible_host": node_ipv6_addresses[node_key],
            "ansible_user": "root",
            "ansible_private_key_file": expand_home(ssh_private_key_path),
            "ansible_ssh_common_args": (
                "-o StrictHostKeyChecking=accept-new "
                f"-o UserKnownHostsFile={KNOWN_HOSTS_FILE}"
            ),
            "node_key": node_key,
            "node_role": role,
            "node_private_ip": node_private_ips.get(node_key, ""),
            "kubernetes_node_name": hostname,
            "api_lb_private_ip": api_lb_private_ip,
        }

    return inventory


def inferred_role(node_key: str) -> str:
    if node_key.startswith("cp-"):
        return "cp_worker"
    if node_key.startswith("worker-"):
        return "worker"
    return "unknown"


def expand_home(path: str) -> str:
    return str(Path(path).expanduser())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="Print full inventory")
    parser.add_argument("--host", help="Print host variables for one host")
    args = parser.parse_args()

    inventory = build_inventory(load_outputs())

    if args.host:
        hostvars = inventory["_meta"]["hostvars"].get(args.host, {})
        print(json.dumps(hostvars, indent=2, sort_keys=True))
        return 0

    if args.list:
        print(json.dumps(inventory, indent=2, sort_keys=True))
        return 0

    parser.print_help(sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
