# Deploy Kubernetes Cluster with Kata Containers (Firecracker) & Cilium

This directory contains an end-to-end setup to deploy a Kubernetes cluster utilizing **Kata Containers with Firecracker (`kata-fc`)** for hardware-isolated microVM pods and **Cilium** as the eBPF CNI.

---

## Directory Contents

| File | Description |
|------|-------------|
| [`docker-deploy.sh`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/docker-deploy.sh) | **One-click Docker deployment script** (Deploys cluster, devmapper, OpenEBS LVM CSI, Kyverno, Agent Sandbox, and verification) |
| [`setup-devmapper.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-devmapper.yml) | Ansible playbook configuring persistent devmapper thin-pools for Firecracker rootfs |
| [`setup-openebs-lvm.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-openebs-lvm.yml) | Ansible playbook provisioning LVM volume groups & deploying OpenEBS LocalPV LVM CSI |
| [`setup-agent-sandbox.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-agent-sandbox.yml) | Ansible playbook deploying Kyverno, Agent Sandbox v1.0.0, and the Kata-FC enforcement policy |
| [`policy-kata-fc.yaml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/policy-kata-fc.yaml) | Kyverno ClusterPolicy mutating Kampfire sandboxes to use `kata-fc` and block volumes |
| [`kata-fc-lvm-test.yaml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/kata-fc-lvm-test.yaml) | Manifest testing raw block PVC (`volumeMode: Block`) in a `kata-fc` microVM |
| [`verify.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/verify.yml) | Ansible playbook verifying microVM kernel isolation, Cilium CNI, OpenEBS storage, Kyverno, and Agent Sandbox |
| [`inventory.ini`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/inventory.ini) | Node inventory definition (control plane, etcd, worker nodes) |
| [`vars.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/vars.yml) | Kubespray extra-vars (containerd, Cilium, Kata, `kata-fc`, devmapper snapshotter) |
| [`kata-fc-runtimeclass.yaml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/kata-fc-runtimeclass.yaml) | Kubernetes manifest defining the `kata-fc` `RuntimeClass` and baseline test pod |


---

## How Storage Is Handled: Firecracker vs Virtio-FS

> [!IMPORTANT]
> **Why Devmapper and OpenEBS LocalPV LVM are Required for Firecracker:**
> Unlike QEMU and Cloud-Hypervisor, **Firecracker does NOT support `virtio-fs` or directory sharing (`overlayfs`)**. Firecracker can only mount storage inside the guest microVM via direct raw block devices (`virtio-blk`).
>
> 1. **Container Rootfs (Images):** Handled by `devmapper` snapshotter in containerd ([`setup-devmapper.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-devmapper.yml)).
> 2. **Persistent Volumes (CSI):** Handled by **OpenEBS LocalPV LVM** ([`setup-openebs-lvm.yml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/setup-openebs-lvm.yml)), which allocates raw LVM logical volumes and connects them over `virtio-blk` to the microVM using `volumeMode: Block`.
>
> *(Note: If you prefer lightweight Rust-based microVMs with standard `overlayfs`, directory bind-mounts, and standard CSI drivers, consider **Cloud-Hypervisor (`kata-clh`)**, which is also included in the Kata bundle and supports `virtio-fs` natively).*

### Using Persistent Volumes in `kata-fc` Pods

Because Firecracker receives storage as raw block devices, PVCs must specify `volumeMode: Block`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-block-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  volumeMode: Block              # Direct block device for virtio-blk
  storageClassName: openebs-lvm
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: my-kata-pod
spec:
  runtimeClassName: kata-fc
  containers:
    - name: app
      image: alpine
      volumeDevices:             # Map block device directly into guest
        - name: my-storage
          devicePath: /dev/xvda
  volumes:
    - name: my-storage
      persistentVolumeClaim:
        claimName: my-block-pvc
```

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
   - **Phase 2:** Configure the devmapper thin-pool on worker nodes for Firecracker container images.
   - **Phase 3:** Provision LVM storage and deploy the OpenEBS LocalPV LVM CSI driver via Helm.
   - **Phase 4:** Deploy Kyverno, Agent Sandbox v1.0.0, apply `policy-kata-fc.yaml`, install Kampfire CLI, and run sandbox verification.
   - **Phase 5:** Run full cluster verification report.

---

## Agent Sandbox, Kyverno Policy & Kampfire CLI

All sandboxes created by **Kampfire** (stamped with label `agents.x-k8s.io/created-by: kampfire`) are intercepted by Kyverno via [`policy-kata-fc.yaml`](file:///Users/basarsubasi/kubespray/kata-fc-cilium/policy-kata-fc.yaml):
1. **Runtime Isolation:** Automatically mutates `spec.runtimeClassName: kata-fc` to boot the sandbox in a hardware-isolated Firecracker microVM.
2. **OpenEBS LVM CSI Storage:** Associated PVCs are automatically routed to `storageClassName: openebs-lvm`.

### Running Sandboxes with Kampfire:
```bash
# Launch a detached alpine sandbox with persistent /workspace
kampfire run --persist /workspace --image alpine -d

# Check that the pod was mutated to use kata-fc
kubectl get pods -l agents.x-k8s.io/created-by=kampfire -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.runtimeClassName,STATUS:.status.phase
```



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
