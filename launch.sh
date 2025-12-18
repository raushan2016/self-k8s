#!/bin/bash
set -e -o pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
if [ -f "config.env" ]; then
    source config.env
else
    echo "Error: config.env not found."
    exit 1
fi

# Defaults
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
ZONE="${ZONE:-us-central1-a}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-control-plane}"
WORKER_NAME_PREFIX="${WORKER_NAME_PREFIX:-k8s-worker}"
WORKER_COUNT="${WORKER_COUNT:-2}"
CUSTOM_IMAGE_NAME="${CUSTOM_IMAGE_NAME:-k8s-custom-image-v1}"
CUSTOM_IMAGE_FAMILY="${CUSTOM_IMAGE_FAMILY:-k8s-custom}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"

echo "============================================================"
echo "Self-Hosted Kubernetes Launcher"
echo "Project: $PROJECT_ID | Zone: $ZONE"
echo "============================================================"

function show_menu() {
    echo "Select an action:"
    echo "1) Build OS Image"
    echo "2) Provision Infrastructure"
    echo "3) Bootstrap Cluster"
    echo "4) Validate Cluster"
    echo "5) Destroy Cluster"
    echo "6) Exit"
}

function build_image() {
    echo "--- Building OS Image ---"
    # Use RESOURCE_PREFIX if defined, else default
    PREFIX="${RESOURCE_PREFIX:-build}"
    BUILD_VM="${PREFIX}-vm-$(date +%s)"
    #BUILD_VM="${PREFIX}-vm-$(date +%s)"
    
    echo "Checking if temporary VM $BUILD_VM exists..."
    if gcloud compute instances describe $BUILD_VM --project $PROJECT_ID --zone $ZONE &>/dev/null; then
        echo "VM $BUILD_VM already exists. Ensuring it is running..."
        gcloud compute instances start $BUILD_VM --project $PROJECT_ID --zone $ZONE || true
        echo "Skipping creation."
    else
        echo "Creating temporary VM: $BUILD_VM..."
        # Determine image source
        if [ -n "$IMAGE_NAME" ]; then
            IMAGE_ARGS="--image $IMAGE_NAME"
        else
            IMAGE_ARGS="--image-family $IMAGE_FAMILY"
        fi

        gcloud compute instances create $BUILD_VM \
            --project $PROJECT_ID \
            --zone $ZONE \
            --machine-type e2-standard-16 \
            $IMAGE_ARGS \
            --image-project $IMAGE_PROJECT \
            --boot-disk-size $BUILD_DISK_SIZE
        echo "[SUCCESS] Temporary VM created."

        echo "Waiting for VM to be ready..."
        sleep 30
    fi

    echo "Uploading scripts..."
    gcloud compute scp config.env osimage.bash $BUILD_VM:~/ --project $PROJECT_ID --zone $ZONE
    echo "[SUCCESS] Scripts uploaded."

    echo "Running build script..."
    gcloud compute ssh $BUILD_VM --project $PROJECT_ID --zone $ZONE --command "sudo bash osimage.bash"
    echo "[SUCCESS] Build script executed."

    echo "Stopping temporary VM to release disk..."
    gcloud compute instances stop $BUILD_VM --project $PROJECT_ID --zone $ZONE
    echo "[SUCCESS] Temporary VM stopped."

    echo "Creating Image: $CUSTOM_IMAGE_NAME..."
    if gcloud compute images describe $CUSTOM_IMAGE_NAME --project $PROJECT_ID &>/dev/null; then
        echo "Image $CUSTOM_IMAGE_NAME already exists. Deleting..."
        gcloud compute images delete $CUSTOM_IMAGE_NAME --project $PROJECT_ID
    fi
    
    gcloud compute images create $CUSTOM_IMAGE_NAME \
        --source-disk $BUILD_VM \
        --source-disk-zone $ZONE \
        --family $CUSTOM_IMAGE_FAMILY \
        --project $PROJECT_ID
    echo "[SUCCESS] Image created: $CUSTOM_IMAGE_NAME"

    echo "Deleting temporary VM..."
    gcloud compute instances delete $BUILD_VM --project $PROJECT_ID --zone $ZONE
    echo "[SUCCESS] Temporary VM deleted."
    
    echo "Image build complete."
}

function provision_infra() {
    echo "--- Provisioning Infrastructure ---"
    bash infra_setup.sh
    echo "[SUCCESS] Infrastructure provisioning complete."
}

function bootstrap_cluster() {
    echo "--- Bootstrapping Cluster ---"
    
    echo "Uploading scripts to Control Plane ($CONTROL_PLANE_NAME)..."
    gcloud compute scp config.env bootstrap_cp.sh $CONTROL_PLANE_NAME:~/ --project $PROJECT_ID --zone $ZONE
    echo "[SUCCESS] Scripts uploaded to Control Plane."

    echo "Running Control Plane bootstrap..."
    gcloud compute ssh $CONTROL_PLANE_NAME --project $PROJECT_ID --zone $ZONE --command "chmod +x bootstrap_cp.sh && ./bootstrap_cp.sh"
    echo "[SUCCESS] Control Plane bootstrapped."

    # Extract Join Command
    echo "Extracting Join Command..."
    JOIN_CMD=$(gcloud compute ssh $CONTROL_PLANE_NAME --project $PROJECT_ID --zone $ZONE --command "kubeadm token create --print-join-command")
    
    if [ -z "$JOIN_CMD" ]; then
        echo "Error: Failed to get join command."
        exit 1
    fi
    
    echo "Join Command: $JOIN_CMD"

    # Join Workers
    for (( i=0; i<$WORKER_COUNT; i++ )); do
        WORKER="${WORKER_NAME_PREFIX}-${i}"
        echo "Joining Worker: $WORKER..."
        gcloud compute ssh $WORKER --project $PROJECT_ID --zone $ZONE --command "sudo $JOIN_CMD"
        echo "[SUCCESS] Worker $WORKER joined."
    done
    
    echo "Cluster bootstrapping complete."
}

function validate_cluster() {
    echo "--- Validating Cluster ---"
    bash validate_cluster.sh
}

function destroy_cluster() {
    echo "--- Destroying Cluster ---"
    read -p "Are you sure? This will delete VMs and Network. (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo "Aborted."
        return
    fi
    
    echo "Deleting VMs..."
    gcloud compute instances delete $CONTROL_PLANE_NAME --project $PROJECT_ID --zone $ZONE --quiet || true
    for (( i=0; i<$WORKER_COUNT; i++ )); do
        gcloud compute instances delete "${WORKER_NAME_PREFIX}-${i}" --project $PROJECT_ID --zone $ZONE --quiet || true
    done
    
    echo "Deleting Subnet..."
    gcloud compute networks subnets delete $SUBNET_NAME --project $PROJECT_ID --region $REGION --quiet || true
    
    echo "Deleting Network..."
    gcloud compute networks delete $NETWORK_NAME --project $PROJECT_ID --quiet || true
    
    echo "Cluster destroyed."
}

# Main Loop
while true; do
    show_menu
    read -p "Enter choice [1-6]: " CHOICE
    case $CHOICE in
        1) build_image ;;
        2) provision_infra ;;
        3) bootstrap_cluster ;;
        4) validate_cluster ;;
        5) destroy_cluster ;;
        6) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo ""
done
