# Deploy Kubernetes Cluster with Kata Containers (Firecracker) & Cilium

This directory contains an end-to-end setup to deploy a Kubernetes cluster utilizing **Kata Containers with Firecracker (`kata-fc`)** for hardware-isolated microVM pods and **Cilium** as the eBPF CNI.

---

## Directory Contents

| File | Description |
|------|-------------|
| [`docker-deploy.sh`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/docker-deploy.sh) | **One-click Docker deployment script** (Deploys, configures devmapper, applies manifests, and runs verification) |
| [`verify.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/verify.yml) | Ansible playbook that applies `kata-fc` manifests, waits for pod, and verifies microVM kernel isolation & Cilium |
| [`inventory.ini`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/inventory.ini) | Node inventory definition (control plane, etcd, worker nodes) |
| [`vars.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/vars.yml) | Kubespray extra-vars (containerd, Cilium, Kata, `kata-fc`, devmapper snapshotter) |
| [`setup-devmapper.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-devmapper.yml) | Ansible playbook configuring persistent devmapper thin-pools for Firecracker |
| [`deploy.sh`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/deploy.sh) | Local bash script for running all 3 phases directly with host Python/Ansible |
| [`kata-fc-runtimeclass.yaml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/kata-fc-runtimeclass.yaml) | Kubernetes manifest defining the `kata-fc` `RuntimeClass` and a test pod |

---

## How Storage Is Handled: Firecracker vs Virtio-FS

> [!IMPORTANT]
> **Why Devmapper is Required for Firecracker:**
> Unlike QEMU and Cloud-Hypervisor, **Firecracker does NOT support `virtio-fs` or directory sharing (`overlayfs`)**. Firecracker only mounts filesystems inside the guest microVM via direct raw block devices (`virtio-blk`).
>
> To make this work seamlessly:
> 1. In [`vars.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/vars.yml), containerd is configured with `containerd_snapshotter: devmapper`.
> 2. The included [`setup-devmapper.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-devmapper.yml) playbook provisions a sparse thin-pool (`containerd-pool`) on all worker nodes, registers a persistent systemd service (`containerd-devmapper.service`) across reboots, and configures the containerd devmapper plugin block.

*(Note: If you prefer to use lightweight Rust-based microVMs with the standard `overlayfs` and `virtio-fs` instead of block devices, consider **Cloud-Hypervisor (`kata-clh`)**, which is also included in the Kata bundle and supports virtio-fs natively).*

---

## Prerequisites

1. **Hardware Virtualization (KVM):**
   Ensure hardware virtualization is enabled and `/dev/kvm` is accessible on all nodes:
   ```bash
   ls -l /dev/kvm
   egrep -c '(vmx|svm)' /proc/cpuinfo
   ```
2. **SSH & Sudo Access:**
   Ensure your SSH public key is added to the target nodes and passwordless `sudo` is configured.
3. **Docker on Host (for Docker deployment):**
   Docker installed and running on your local machine.

---

## Deployment Options

### Option A: Run in Official Kubespray Docker (Zero Local Dependencies)

This is the cleanest method—no local Python or Ansible installations are needed.

1. Edit your node IPs in [`inventory.ini`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/inventory.ini).
2. Run the Docker deployment script:
   ```bash
   bash kata-fc-cilium/docker-deploy.sh
   ```
   *The script will automatically:*
   - Inject your SSH key and this configuration folder into the official Kubespray container.
   - **Phase 1:** Deploy the Kubernetes cluster with Cilium CNI and Kata Containers.
   - **Phase 2:** Configure the devmapper thin-pool on worker nodes for Firecracker.
   - **Phase 3:** Apply the `kata-fc` `RuntimeClass`, spawn `test-kata-fc`, and verify that the microVM kernel is distinct from the host kernel.

---

### Option B: Run Directly on Host Machine (Python/Ansible)

If you have Python and Ansible installed locally on your host machine:

1. Install requirements:
   ```bash
   pip install -r requirements.txt
   ```
2. Run the deployment:
   ```bash
   bash kata-fc-cilium/deploy.sh
   ```

---

## Standalone Verification

If you ever want to re-run only the validation on an existing cluster without redeploying:

```bash
# Via Docker:
docker run --rm -it \
  -v $(pwd)/kata-fc-cilium:/kata-fc-cilium:ro \
  -v ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro \
  -e ANSIBLE_HOST_KEY_CHECKING=False \
  quay.io/kubespray/kubespray:v2.31.0 \
  ansible-playbook -i /kata-fc-cilium/inventory.ini /kata-fc-cilium/verify.yml -b --private-key /root/.ssh/id_rsa

# Or locally:
ansible-playbook -i kata-fc-cilium/inventory.ini kata-fc-cilium/verify.yml -b
```
