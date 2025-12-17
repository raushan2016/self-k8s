# Self-Hosted Kubernetes on GCP with Cilium

This project provides a parameterized and automated way to deploy a self-managed Kubernetes cluster on Google Cloud Platform (GCP) using a custom OS image and Cilium CNI.

## Project Structure

- `launch.sh`: **Main entry point**. Interactive script to build images, provision infra, and bootstrap the cluster.
- `config.env`: Configuration file for all parameters (Region, Machine Types, Versions, CIDRs).
- `osimage.bash`: Script to build a custom OS image with GPU drivers, Containerd, and Kubernetes binaries.
- `infra_setup.sh`: Script to provision VPC, Subnet, Firewall rules, and Compute Instances.
- `bootstrap_cp.sh`: Script to initialize the Kubernetes Control Plane and install Cilium.
- `bootstrap_worker.sh`: Script to join Worker nodes to the cluster.

## Quick Start

### 1. Configure
Edit `config.env` to set your Project ID, Region, and desired configurations.
```bash
PROJECT_ID="your-project-id"
REGION="us-central1"
# ... other settings
```

### 2. Launch
Run the launcher script:
```bash
./launch.sh
```

You will see a menu:
```
Select an action:
1) Build OS Image
2) Provision Infrastructure
3) Bootstrap Cluster
4) Destroy Cluster
5) Exit
```

### 3. Deployment Steps
1.  **Select Option 1 (Build OS Image)**: This will create a temporary VM, run `osimage.bash`, and create a GCP Image.
2.  **Select Option 2 (Provision Infrastructure)**: This will create the VPC, Subnet, and VMs using the image created in step 1.
3.  **Select Option 3 (Bootstrap Cluster)**: This will initialize the Control Plane, install Cilium, and join the worker nodes automatically.
4.  **Select Option 4 (Validate Cluster)**: This will run a series of checks (Node status, Pod status, Cilium health, Connectivity) to ensure the cluster is healthy.

### 4. Verify
SSH into the Control Plane (or use `kubectl` if you copied the config locally):
```bash
gcloud compute ssh k8s-control-plane
kubectl get nodes
kubectl get pods -A
```

## Manual Usage
You can still run individual scripts if preferred, but ensure `config.env` is present in the same directory.

- **Build Image**: `bash osimage.bash` (Run inside a VM)
- **Provision Infra**: `bash infra_setup.sh`
- **Bootstrap CP**: `bash bootstrap_cp.sh` (Run on Control Plane)
