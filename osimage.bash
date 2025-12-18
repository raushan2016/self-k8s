#!/bin/bash
set -e -o pipefail

# Source configuration if available
if [ -f "config.env" ]; then
    source config.env
fi

# ==============================================================================
# LAYER 1: HARDWARE STABILITY
# ==============================================================================
echo "--- Layer 1: Applying Hardware Stability Locks ---"

# Preventing package managers from updating GPU drivers/firmware mid-run
NVIDIA_PACKAGES=(
  "libnvidia-cfg1-*-server"
  "libnvidia-compute-*-server"
  "libnvidia-nscq-*"
  "nvidia-compute-utils-*-server"
  "nvidia-fabricmanager-*"
  "nvidia-utils-*-server"
  "nvidia-imex-*"
)

for pkg in "${NVIDIA_PACKAGES[@]}"; do
  apt-mark hold "$pkg" || echo "Warning: Could not hold $pkg (might not be installed yet)"
done


GOOGLE_COMPUTE_PACKAGES=(
  "google-compute-engine"
  "google-compute-engine-oslogin"
  "google-guest-agent"
  "google-osconfig-agent"
)

for pkg in "${GOOGLE_COMPUTE_PACKAGES[@]}"; do
  apt-mark hold "$pkg" || echo "Warning: Could not hold $pkg (might not be installed yet)"
done
# ==============================================================================
# LAYER 2: GPU RUNTIME & LIBRARIES
# ==============================================================================
echo "--- Layer 2: Installing GPU Runtime, NCCL, and Toolkits ---"

# 1. Setup Repository via Keyring
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update

# 2. Install CUDA Toolkit, Container Toolkit, and DCGM
apt-get install -y \
  cuda-toolkit-13-0 \
  nvidia-container-toolkit \
  datacenter-gpu-manager-4-cuda13 \
  datacenter-gpu-manager-4-dev 

# 3. Install NCCL (NVIDIA Collective Communications Library)
apt-get install -y libnccl2 libnccl-dev

rm -f cuda-keyring_1.1-1_all.deb

# 4. Fabric Manager Configuration
systemctl enable nvidia-fabricmanager
if lspci | grep -q "NVIDIA"; then
    systemctl start nvidia-fabricmanager
    sleep 5
    systemctl is-active nvidia-fabricmanager
else
    echo "No NVIDIA GPUs detected. Skipping service start."
fi

# 5. Container Runtime Configuration 
echo "--- Configuring NVIDIA Container Runtime ---"

# Use this if container runtime is Docker
if command -v docker &> /dev/null; then
    echo "Configuring for Docker..."
    nvidia-ctk runtime configure --runtime=docker
    if systemctl is-active --quiet docker; then
        systemctl restart docker
    fi
else
    echo "Docker not found, skipping Docker configuration."
fi

# Use this if container runtime is Containerd
if command -v containerd &> /dev/null; then
    echo "Configuring for Containerd..."
    # Configures /etc/containerd/config.toml
    nvidia-ctk runtime configure --runtime=containerd
    if systemctl is-active --quiet containerd; then
        systemctl restart containerd
    fi
else
    echo "Containerd not found, skipping Containerd configuration."
fi

# 6. System Limits
cat <<EOF > /etc/security/limits.d/99-unlimited.conf
* - memlock unlimited
* - nproc unlimited
* - stack unlimited
* - nofile 1048576
* - cpu unlimited
* - rtprio unlimited
EOF

# 7. GPU Persistence
mkdir -p /etc/systemd/system/nvidia-persistenced.service.d
cat <<EOF > /etc/systemd/system/nvidia-persistenced.service.d/persistence_mode.conf
[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
EOF

systemctl daemon-reload
# Disabling nvidia-dcgm.service as it can be installed in kubernetes cluster for monitoring. Remove this if the service should be run
systemctl stop nvidia-dcgm.service || true
systemctl disable nvidia-dcgm.service || true

systemctl enable nvidia-persistenced.service

if lspci | grep -qi nvidia; then
    systemctl start nvidia-persistenced.service
fi

# 8. Hold NVIDIA Packages
echo "Holding NVIDIA packages to prevent auto-updates..."
for pkg in "${NVIDIA_PACKAGES[@]}"; do
  apt-mark hold "$pkg" || echo "Warning: Could not hold $pkg"
done

# ==============================================================================
# LAYER 3: KUBERNETES PREREQUISITES & RUNTIME
# ==============================================================================
echo "--- Layer 3: Configuring Kernel Modules & Containerd ---"

# 1. Load Kernel Modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# 2. Configure Sysctl
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 3. Install Containerd
if ! command -v containerd &> /dev/null; then
    echo "Installing Containerd..."
    apt-get update
    apt-get install -y containerd conntrack socat
fi

# 4. Configure Containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

# ==============================================================================
# LAYER 4: KUBERNETES COMPONENTS
# ==============================================================================
echo "--- Layer 4: Installing Kubeadm, Kubelet, Kubectl ---"

# Use variables from config.env if available, else default
K8S_VER="${KUBERNETES_VERSION:-v1.29}"

# 1. Install Kubernetes Packages
apt-get install -y apt-transport-https ca-certificates curl gpg

# Download public signing key
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VER}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 2. Install CNI Plugins
CNI_VER="${CNI_PLUGINS_VERSION:-v1.4.0}"
ARCH="amd64"
mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-${ARCH}-${CNI_VER}.tgz" \
  -o cni-plugins.tgz
tar -xzvf cni-plugins.tgz -C /opt/cni/bin
chown -R root:root /opt/cni/bin
rm -f cni-plugins.tgz

# ==============================================================================
# LAYER 5: OPENMPI & TOOLS
# ==============================================================================
echo "--- Layer 5: Installing OpenMPI & Tools ---"

apt-get install -y libopenmpi-dev openmpi-bin

# ==============================================================================
# OPTIONAL: GOOGLE CLOUD OPS AGENT
# ==============================================================================
echo "--- Installing & Configuring Ops Agent ---"

curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
bash add-google-cloud-ops-agent-repo.sh --also-install --version=latest
rm -f add-google-cloud-ops-agent-repo.sh

mkdir -p /etc/google-cloud-ops-agent
cat <<EOF > /etc/google-cloud-ops-agent/config.yaml
logging:
  receivers:
    syslog:
      type: files
      include_paths:
      - /var/log/syslog
      - /var/log/messages
  service:
    pipelines:
      default_pipeline:
        receivers: [syslog]
metrics:
  receivers:
    host_metrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      default_pipeline:
        receivers: [host_metrics]
EOF

systemctl restart google-cloud-ops-agent
systemctl enable google-cloud-ops-agent

# ==============================================================================
# FINAL CLEANUP: MIGRATE GCLOUD FROM SNAP TO APT
# ==============================================================================
echo "--- Final Cleanup: Removing Snap and Installing GCloud via APT ---"

snap remove google-cloud-cli lxd || true

GCLOUD_APT_SOURCE="/etc/apt/sources.list.d/google-cloud-sdk.list"
if [ ! -f "${GCLOUD_APT_SOURCE}" ]; then
    cat <<EOF > "${GCLOUD_APT_SOURCE}"
deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt cloud-sdk main
EOF
fi

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | tee /usr/share/keyrings/cloud.google.asc > /dev/null
apt-get update
apt-get install -y google-cloud-cli
hash -r

echo "Setup complete. All layers applied successfully."