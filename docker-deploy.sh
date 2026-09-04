#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Official Kubespray container image
KUBESPRAY_IMAGE="${KUBESPRAY_IMAGE:-quay.io/kubespray/kubespray:v2.31.0}"

# 1. Resolve SSH Private Key
if [ -n "${SSH_KEY_PATH:-}" ] && [ -f "${SSH_KEY_PATH}" ]; then
  LOCAL_SSH_KEY="${SSH_KEY_PATH}"
elif [ -f "${HOME}/.ssh/id_rsa" ]; then
  LOCAL_SSH_KEY="${HOME}/.ssh/id_rsa"
elif [ -f "${HOME}/.ssh/id_ed25519" ]; then
  LOCAL_SSH_KEY="${HOME}/.ssh/id_ed25519"
else
  echo "Error: Could not automatically locate an SSH private key in ~/.ssh/id_rsa or ~/.ssh/id_ed25519."
  echo "Specify your key path using: export SSH_KEY_PATH=/path/to/private_key"
  exit 1
fi

echo "=================================================================="
echo " Kubespray Docker Launcher (Kata-FC + Cilium)"
echo " Image      : ${KUBESPRAY_IMAGE}"
echo " Config Dir : ${SCRIPT_DIR}"
echo " SSH Key    : ${LOCAL_SSH_KEY}"
echo "=================================================================="

# 2. SSH Agent Forwarding options (if agent socket is active)
SSH_AGENT_MOUNTS=()
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
  SSH_AGENT_MOUNTS=(
    -v "${SSH_AUTH_SOCK}:/ssh-agent"
    -e "SSH_AUTH_SOCK=/ssh-agent"
  )
fi

# 3. Mount current kubespray repo if available, otherwise use container's builtin /kubespray
REPO_MOUNT=()
if [ -f "${KUBESPRAY_ROOT}/cluster.yml" ]; then
  REPO_MOUNT=(-v "${KUBESPRAY_ROOT}:/kubespray")
fi

# 4. Deployment commands to execute inside the container
CONTAINER_SCRIPT=$(cat << 'EOF'
set -euo pipefail
cd /kubespray

# Ensure correct permissions on the injected key inside container
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/ssh_key /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa

echo ""
echo ">>> [Phase 1/3] Deploying Kubernetes Cluster (Cilium CNI + Kata Containers)..."
ansible-playbook -i /kata-fc-cilium/inventory.ini \
  cluster.yml \
  -b \
  -e @/kata-fc-cilium/vars.yml \
  --private-key /root/.ssh/id_rsa \
  "$@"

echo ""
echo ">>> [Phase 2/3] Setting up Devmapper Thin-Pool for Firecracker..."
ansible-playbook -i /kata-fc-cilium/inventory.ini \
  /kata-fc-cilium/setup-devmapper.yml \
  -b \
  --private-key /root/.ssh/id_rsa \
  "$@"

echo ""
echo ">>> [Phase 3/3] Applying kata-fc RuntimeClass and Verifying MicroVM Pod..."
ansible-playbook -i /kata-fc-cilium/inventory.ini \
  /kata-fc-cilium/verify.yml \
  -b \
  --private-key /root/.ssh/id_rsa \
  "$@"

echo ""
echo "=================================================================="
echo " All phases complete: Cluster deployed, configured, and verified!"
echo "=================================================================="
EOF
)

# 5. Run official Kubespray container
docker run --rm -it \
  "${REPO_MOUNT[@]}" \
  -v "${SCRIPT_DIR}:/kata-fc-cilium:ro" \
  -v "${LOCAL_SSH_KEY}:/tmp/ssh_key:ro" \
  "${SSH_AGENT_MOUNTS[@]}" \
  -e ANSIBLE_HOST_KEY_CHECKING=False \
  "${KUBESPRAY_IMAGE}" \
  bash -c "${CONTAINER_SCRIPT}" -- "$@"
