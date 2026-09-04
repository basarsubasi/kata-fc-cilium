#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=================================================================="
echo " Phase 1: Deploying Kubernetes Cluster (Kubespray + Cilium + Kata)"
echo " Inventory : ${SCRIPT_DIR}/inventory.ini"
echo " Vars      : ${SCRIPT_DIR}/vars.yml"
echo "=================================================================="

cd "${KUBESPRAY_ROOT}"

# Step 1: Run standard Kubespray cluster deployment
ansible-playbook -i "${SCRIPT_DIR}/inventory.ini" cluster.yml -b -e @"${SCRIPT_DIR}/vars.yml" "$@"

echo ""
echo "=================================================================="
echo " Phase 2: Configuring Devmapper Thin-Pool for Firecracker"
echo "=================================================================="

# Step 2: Configure thin-pool and containerd devmapper plugin on all nodes
ansible-playbook -i "${SCRIPT_DIR}/inventory.ini" "${SCRIPT_DIR}/setup-devmapper.yml" "$@"

echo ""
echo "=================================================================="
echo " Phase 3: Applying kata-fc RuntimeClass and Verifying MicroVM Pod"
echo "=================================================================="

# Step 3: Apply manifests and verify
ansible-playbook -i "${SCRIPT_DIR}/inventory.ini" "${SCRIPT_DIR}/verify.yml" "$@"
