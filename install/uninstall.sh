#!/bin/bash

# MLRun CE Uninstall Script
# Matches the simplified install script with single/multi modes

set -e
# Make command substitutions inherit errexit (Bash 4.4+)
shopt -s inherit_errexit 2>/dev/null || true

# Add common binary paths for Code Runner compatibility
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:${PATH}"

# Load configuration from .env file (all settings + secrets, never committed to git)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# Configuration
SUDO_PASS="${SUDO_PASS:-}"
CONTROLLER_RELEASE="mlrun-ce-controller"
CONTROLLER_NAMESPACE="controller"
KUBE_CONTEXT=""
USE_LOCAL_CONTEXT=1
KUBECONFIG_PATH=""
ALLOW_CLOUD=0
CLEAN_IMAGES=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Sanitize cluster name for DNS (extract part after @ if present)
sanitize_cluster_name() {
    local name="${1:-}"
    if [[ "${name:-}" == *"@"* ]]; then
        echo "${name##*@}"
    else
        echo "${name:-}"
    fi
}


# Check if running on a local/dev cluster (safe for force delete)
is_local_cluster() {
    local context_name
    context_name=$(kubectl config current-context 2>/dev/null) || true
    context_name="${KUBE_CONTEXT:-${context_name:-}}"
    local node_names
    node_names=$(kubectl get nodes -o name 2>/dev/null) || true
    
    # If using --remote, it's a cluster on a VM - safe for force delete
    if [[ -n "${JUMP_USER:-}" ]] && [[ -n "${JUMP_IP:-}" ]]; then
        return 0  # Remote VM
    fi
    
    # Check context name for local indicators
    if [[ "${context_name:-}" =~ (docker-desktop|minikube|kind|rancher-desktop|colima|orbstack) ]]; then
        return 0  # Local
    fi
    
    # Check node names for local indicators (docker-desktop, minikube, etc.)
    if echo "${node_names:-}" | grep -qiE "(docker-desktop|minikube|colima|orbstack)"; then
        return 0  # Local
    fi
    
    # Check for Kind cluster pattern: single node ending in -control-plane
    if echo "${node_names:-}" | grep -qE "\-control-plane$"; then
        # Likely a Kind cluster
        return 0  # Kind
    fi
    
    # Check for cloud indicators in context name
    if [[ "${context_name:-}" =~ (eks|aks|gke|aws|azure|gcp|amazonaws|googlecloud) ]]; then
        return 1  # Cloud
    fi
    
    # Check node names for cloud indicators
    if echo "${node_names:-}" | grep -qiE "(ec2|compute\.internal|aks|gke)"; then
        return 1  # Cloud
    fi
    
    # Unknown - assume NOT local (safer)
    return 1
}

# Clean Docker images from cluster (useful for testing fresh installs)
# Supports: Kind clusters (local/remote), bare-metal/VM clusters (RKE, k3s, kubeadm)
clean_cluster_images() {
    echo ""
    echo "Cleaning Docker images from cluster..."
    
    local node_names
    node_names=$(kubectl get nodes -o name 2>/dev/null) || true
    
    # Detect cluster type
    local is_kind=0
    if echo "${node_names:-}" | grep -qE "\-control-plane$"; then
        is_kind=1
    fi
    
    if [[ "${is_kind}" -eq 1 ]]; then
        # Kind cluster
        clean_kind_images_impl
    else
        # Bare-metal/VM cluster (RKE, k3s, kubeadm)
        clean_node_images_impl
    fi
}

# Implementation for Kind clusters
clean_kind_images_impl() {
    echo "  Detected: Kind cluster"
    
    # Get the Kind container name
    local kind_container
    kind_container=$(docker ps -qf "name=control-plane" 2>/dev/null | head -1) || true
    
    if [[ -z "${kind_container:-}" ]]; then
        # Try via SSH for remote Kind clusters
        if [[ -n "${JUMP_USER:-}" ]] && [[ -n "${JUMP_IP:-}" ]]; then
            echo "  Cleaning images on remote Kind cluster..."
            # shellcheck disable=SC2087
            ssh "${JUMP_USER}@${JUMP_IP}" bash << 'REMOTE_SCRIPT'
set -e
KIND_CONTAINER=$(docker ps -qf "name=control-plane" 2>/dev/null | head -1)
if [ -z "$KIND_CONTAINER" ]; then
    echo "    Could not find Kind container"
    exit 0
fi

echo "    Found Kind container: $KIND_CONTAINER"

# Get list of mlrun-related images (MLRun CE dependencies)
# Includes: mlrun, nuclio, jupyter, minio, seaweedfs, strimzi, kafka, prometheus, grafana
IMAGES=$(docker exec "$KIND_CONTAINER" crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[]' 2>/dev/null | grep -E "^(mlrun/|docker\.io/mlrun/|quay\.io/nuclio/|jupyter/|minio/|chrislusf/seaweed|quay\.io/strimzi/|bitnami/kafka|quay\.io/prometheus/|quay\.io/prometheus-operator/|grafana/|registry\.k8s\.io/kube-state-metrics/|quay\.io/brancz/kube-rbac-proxy|quay\.io/thanos/)" || true)

if [ -z "$IMAGES" ]; then
    echo "    No MLRun-related images found"
    exit 0
fi

echo "    Removing images:"
for img in $IMAGES; do
    echo "      - $img"
    docker exec "$KIND_CONTAINER" crictl rmi "$img" 2>/dev/null || true
done

echo "    ✓ Images cleaned from Kind cluster"
REMOTE_SCRIPT
            return
        else
            echo -e "  ${YELLOW}⚠ Could not find Kind container locally${NC}"
            return
        fi
    fi
    
    echo "    Found Kind container: ${kind_container}"
    
    # Get list of mlrun-related images (MLRun CE dependencies)
    local images
    images=$(docker exec "${kind_container}" crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[]' 2>/dev/null | grep -E "^(mlrun/|docker\.io/mlrun/|quay\.io/nuclio/|jupyter/|minio/|chrislusf/seaweed|quay\.io/strimzi/|bitnami/kafka|quay\.io/prometheus/|quay\.io/prometheus-operator/|grafana/|registry\.k8s\.io/kube-state-metrics/|quay\.io/brancz/kube-rbac-proxy|quay\.io/thanos/)" || true)
    
    if [[ -z "${images:-}" ]]; then
        echo "    No MLRun-related images found"
        return
    fi
    
    echo "    Removing images:"
    while IFS= read -r img; do
        [[ -z "${img:-}" ]] && continue
        echo "      - ${img}"
        docker exec "${kind_container}" crictl rmi "${img}" 2>/dev/null || true
    done <<< "${images}"
    
    echo -e "  ${GREEN}✓${NC} Images cleaned from Kind cluster"
}

# Implementation for bare-metal/VM clusters (RKE, k3s, kubeadm)
clean_node_images_impl() {
    echo "  Detected: Bare-metal/VM cluster"
    
    if [[ -z "${JUMP_USER:-}" ]]; then
        echo -e "  ${YELLOW}⚠ No remote connection info - cannot clean images on cluster nodes${NC}"
        echo "  Use --remote user@ip to enable image cleanup on remote clusters"
        return
    fi
    
    # Get ALL K8s node IPs (images may be on any node)
    local node_ips
    node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true
    
    if [[ -z "${node_ips:-}" ]]; then
        echo -e "  ${YELLOW}⚠ Could not detect K8s node IPs, using remote IP${NC}"
        node_ips="${JUMP_IP}"
    fi
    
    local node_count
    node_count=$(echo "${node_ips}" | wc -w | tr -d ' ')
    echo "  Found ${node_count} K8s node(s)"
    
    # Clean images on each node
    for node_ip in ${node_ips}; do
        echo ""
        echo "  Cleaning images on node: ${node_ip}"
        
        # Test SSH connectivity first
        if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes "${JUMP_USER}@${node_ip}" "echo ok" &>/dev/null; then
            echo -e "    ${YELLOW}⚠ Could not connect to ${node_ip}, skipping...${NC}"
            continue
        fi
        
        # shellcheck disable=SC2087
        ssh -o StrictHostKeyChecking=no "${JUMP_USER}@${node_ip}" bash << 'REMOTE_SCRIPT'
set -e

# Detect container runtime: Docker or containerd (crictl)
USE_DOCKER=0
if command -v docker &>/dev/null && docker ps &>/dev/null 2>&1; then
    USE_DOCKER=1
    echo "    Using Docker runtime"
elif command -v crictl &>/dev/null; then
    echo "    Using containerd runtime (crictl)"
else
    echo "    ⚠ No container runtime found (docker/crictl)"
    exit 0
fi

# MLRun CE image patterns (including all CE dependencies)
PATTERN="(mlrun|quay\.io/mlrun|quay\.io/nuclio|chrislusf/seaweed|quay\.io/strimzi|bitnami/kafka|quay\.io/prometheus|grafana/grafana|quay\.io/minio|registry\.k8s\.io/kube-state-metrics|ghcr\.io/kubeflow|kubeflow/spark|quay\.io/kiwigrid/k8s-sidecar|gcr\.io/tfx-oss-public/ml_metadata)"

echo "    Scanning for MLRun-related images..."

if [ "$USE_DOCKER" -eq 1 ]; then
    # Docker: get image IDs matching pattern
    IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "$PATTERN" || true)
    
    if [ -z "$IMAGES" ]; then
        echo "    No MLRun-related images found on this node"
        exit 0
    fi
    
    IMAGE_COUNT=$(echo "$IMAGES" | wc -l)
    echo "    Found $IMAGE_COUNT MLRun-related images"
    
    # First, stop and remove any containers using these images
    echo "    Stopping containers using MLRun images..."
    for img in $IMAGES; do
        # Find containers using this image (running or stopped)
        CONTAINERS=$(docker ps -a --filter "ancestor=$img" -q 2>/dev/null || true)
        if [ -n "$CONTAINERS" ]; then
            echo "      Removing containers for: $img"
            docker rm -f $CONTAINERS 2>/dev/null || true
        fi
    done
    
    echo "    Removing images:"
    for img in $IMAGES; do
        echo "      - $img"
        docker rmi -f "$img" 2>/dev/null || true
    done
else
    # crictl (containerd)
    IMAGES=$(crictl images -o json 2>/dev/null | jq -r '.images[].repoTags[]' 2>/dev/null | grep -E "$PATTERN" || true)
    
    if [ -z "$IMAGES" ]; then
        echo "    No MLRun-related images found on this node"
        exit 0
    fi
    
    IMAGE_COUNT=$(echo "$IMAGES" | wc -l)
    echo "    Found $IMAGE_COUNT MLRun-related images"
    
    # First, stop any pods/containers using these images via crictl
    echo "    Stopping containers using MLRun images..."
    for img in $IMAGES; do
        # Get image ID
        IMG_ID=$(crictl images -o json 2>/dev/null | jq -r ".images[] | select(.repoTags[] == \"$img\") | .id" 2>/dev/null || true)
        if [ -n "$IMG_ID" ]; then
            # Find containers using this image
            CONTAINERS=$(crictl ps -a -o json 2>/dev/null | jq -r ".containers[] | select(.imageRef == \"$IMG_ID\" or .image.image == \"$img\") | .id" 2>/dev/null || true)
            if [ -n "$CONTAINERS" ]; then
                echo "      Removing containers for: $img"
                for cid in $CONTAINERS; do
                    crictl stop "$cid" 2>/dev/null || true
                    crictl rm "$cid" 2>/dev/null || true
                done
            fi
        fi
    done
    
    echo "    Removing images:"
    for img in $IMAGES; do
        echo "      - $img"
        crictl rmi "$img" 2>/dev/null || true
    done
fi

# Clean up dangling images
if [ "$USE_DOCKER" -eq 1 ]; then
    echo "    Pruning dangling images..."
    docker image prune -f 2>/dev/null || true
fi

echo "    ✓ Images cleaned"
REMOTE_SCRIPT
        
        echo -e "    ${GREEN}✓${NC} Done with node ${node_ip}"
    done
    
    echo ""
    echo -e "  ${GREEN}✓${NC} Images cleaned from all K8s nodes"
}

# Check if the K8s API server port (6443) is blocked by another process.
# On local clusters (e.g. docker-desktop), an SSH tunnel or other process
# occupying port 6443 prevents the API server from starting.
# Returns 0 if conflict was resolved, 1 if no conflict found.
check_apiserver_port_conflict() {
    local port_info
    port_info=$(lsof -i :6443 -sTCP:LISTEN 2>/dev/null | grep -v "^COMMAND" || true)

    if [[ -z "${port_info:-}" ]]; then
        return 1
    fi

    local blocking_pid blocking_cmd
    blocking_pid=$(echo "${port_info}" | awk '{print $2}' | head -1)
    blocking_cmd=$(ps -p "${blocking_pid}" -o command= 2>/dev/null || echo "unknown")

    # If it's a known K8s process, not a conflict
    if echo "${blocking_cmd}" | grep -qE "(kube-apiserver|kubectl|vpnkit|com\.docker)"; then
        return 1
    fi

    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  Port 6443 is blocked by another process!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  PID:     ${blocking_pid}"
    echo "  Command: ${blocking_cmd}"
    echo ""
    echo "  The Kubernetes API server needs port 6443, but it's already"
    echo "  in use (likely an SSH tunnel to a remote cluster)."
    echo ""

    read -r -p "  Kill this process to free port 6443? (Y/n): " confirm
    if [[ "${confirm:-}" =~ ^[Nn]$ ]]; then
        echo ""
        echo "  To fix manually:"
        echo "    kill ${blocking_pid}"
        echo "    # Then reset Kubernetes in Docker Desktop settings"
        echo ""
        return 1
    fi
    kill "${blocking_pid}" 2>/dev/null || true

    sleep 2

    # Verify port is free
    if lsof -i :6443 -sTCP:LISTEN &>/dev/null; then
        echo -e "  ${RED}Port 6443 is still in use after killing PID ${blocking_pid}${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} Port 6443 is now free"
    echo ""
    echo -e "  ${YELLOW}You may need to reset Kubernetes in Docker Desktop settings${NC}"
    echo -e "  ${YELLOW}(Settings → Kubernetes → Reset Kubernetes Cluster)${NC}"
    echo ""

    # Give Docker Desktop a moment to detect the freed port
    echo "  Waiting for Kubernetes API server to start..."
    local wait_attempt=0
    while [[ ${wait_attempt} -lt 12 ]]; do
        if kubectl cluster-info &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Kubernetes API server is up"
            return 0
        fi
        sleep 5
        ((wait_attempt++))
        echo "  Still waiting... ($((wait_attempt * 5))s)"
    done

    echo -e "  ${YELLOW}API server not ready yet. You may need to reset Kubernetes in Docker Desktop.${NC}"
    return 1
}

# Test cluster connectivity and offer to reconnect if needed
test_cluster_connectivity() {
    local max_retries=3
    local retry=0
    
    echo "Testing cluster connectivity..."
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        if kubectl cluster-info &>/dev/null; then
            echo -e "${GREEN}✓${NC} Connected to cluster"
            return 0
        fi
        
        # Connection failed
        if [[ ${retry} -eq 0 ]]; then
            echo -e "${YELLOW}Cannot connect to Kubernetes cluster${NC}"
        fi
        
        # If we have remote connection info, auto-reconnect
        if [[ -n "${JUMP_USER:-}" ]] && [[ -n "${JUMP_IP:-}" ]] && [[ -n "${CLUSTER_NAME:-}" ]]; then
            echo ""
            echo -e "${YELLOW}Auto-reconnecting... (attempt $((retry + 1))/${max_retries})${NC}"
            
            # Find create_kubeconfig.sh relative to this script
            local create_kubeconfig="${SCRIPT_DIR}/create_kubeconfig_ce.sh"
            
            if [[ -f "${create_kubeconfig}" ]]; then
                echo "Running: ${create_kubeconfig} ${JUMP_USER} ${JUMP_IP} ${CLUSTER_NAME}"
                bash "${create_kubeconfig}" "${JUMP_USER}" "${JUMP_IP}" "${CLUSTER_NAME}" 2>/dev/null || true
                
                # Brief wait before retry
                sleep 2
            else
                echo -e "${RED}ERROR: create_kubeconfig.sh not found${NC}"
                echo "Expected at: ${create_kubeconfig}"
                exit 1
            fi
        else
            # No remote info — on local clusters, check if port 6443 is blocked
            if check_apiserver_port_conflict; then
                ((retry++))
                continue  # Port was freed, retry connectivity
            fi
            echo -e "${RED}ERROR: Cannot connect to Kubernetes cluster${NC}"
            echo "No remote connection info available for auto-reconnect."
            exit 1
        fi
        
        ((retry++))
    done
    
    # All retries exhausted
    echo -e "${RED}ERROR: Failed to connect after ${max_retries} attempts${NC}"
    exit 1
}

# Safeguard: Block uninstall on cloud clusters unless explicitly allowed
check_cluster_safety() {
    if [[ "${ALLOW_CLOUD:-0}" -eq 1 ]]; then
        return 0
    fi
    
    # shellcheck disable=SC2310
    if is_local_cluster; then
        echo -e "${GREEN}✓${NC} Local cluster detected - safe to proceed"
        return 0
    fi
    
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}⚠️  WARNING: This does NOT appear to be a local cluster!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    local current_ctx
    current_ctx=$(kubectl config current-context 2>/dev/null) || true
    echo "Context: ${KUBE_CONTEXT:-${current_ctx:-unknown}}"
    echo "This script uses --force delete which can orphan cloud resources."
    echo ""
    echo "If you're SURE this is safe, re-run with: --allow-cloud"
    echo ""
    exit 1
}

print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}${1:-}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Remove /etc/hosts entries for a namespace
remove_hosts_for_namespace() {
    local namespace="${1:-}"
    local cluster="${CLUSTER_NAME:-}"
    local marker_begin="# mlrun-hosts:${namespace}:${cluster} BEGIN"
    local marker_end="# mlrun-hosts:${namespace}:${cluster} END"

    if sudo grep -q "${marker_begin}" /etc/hosts 2>/dev/null; then
        echo "Removing /etc/hosts entries for namespace '${namespace}'..."
        sudo /bin/sh -c "sed -i '' '/${marker_begin//\//\\/}/,/${marker_end//\//\\/}/d' /etc/hosts"
    fi
}

# List all MLRun CE releases (excluding controller)
list_mlrun_releases() {
    echo "Scanning for MLRun CE releases..."
    
    # Get all namespaces with mlrun-related releases
    RELEASES=$(helm list --all-namespaces 2>/dev/null | grep -v "${CONTROLLER_RELEASE}" | grep -E "mlrun|nuclio|jupyter" | awk '{print $1 "|" $2}' || true)
    
    if [[ -z "${RELEASES:-}" ]]; then
        echo -e "${YELLOW}No MLRun CE namespace releases found.${NC}"
        return 1
    fi
    
    echo ""
    echo "Found MLRun CE releases:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local i=0
    RELEASE_LIST=()
    while IFS='|' read -r release namespace; do
        i=$((i + 1))
        RELEASE_LIST+=("${release}|${namespace}")
        echo "${i}. Release: ${release} (Namespace: ${namespace})"
    done <<< "${RELEASES}"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

# Check if controller is installed
is_controller_installed() {
    # shellcheck disable=SC2312
    helm list -n "${CONTROLLER_NAMESPACE}" 2>/dev/null | grep -q "${CONTROLLER_RELEASE}"
}

# Force cleanup a namespace - handles all edge cases
force_cleanup_namespace() {
    local namespace="${1:-}"
    local max_retries=3
    local retry=0
    
    # Check if namespace exists
    if ! kubectl get namespace "${namespace}" &>/dev/null; then
        return 0
    fi
    
    echo "Performing aggressive namespace cleanup for ${namespace}..."
    
    # Step 1: Force delete ALL pods first (most common cause of stuck namespaces)
    echo "  Force deleting all pods..."
    kubectl delete pods --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 2: Delete all StatefulSets (they recreate pods)
    echo "  Deleting StatefulSets..."
    kubectl delete statefulsets --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 3: Delete all Deployments
    echo "  Deleting Deployments..."
    kubectl delete deployments --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 4: Delete all ReplicaSets
    kubectl delete replicasets --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 5: Delete all Jobs
    kubectl delete jobs --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 6: Remove finalizers from PVCs and delete them
    echo "  Cleaning up PVCs..."
    for pvc in $(kubectl get pvc -n "${namespace}" -o name 2>/dev/null); do
        kubectl patch "${pvc}" -n "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    kubectl delete pvc --all -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
    
    # Step 7: Remove finalizers from ALL remaining resources
    echo "  Removing finalizers from remaining resources..."
    for resource_type in configmaps secrets serviceaccounts services endpoints; do
        for resource in $(kubectl get "${resource_type}" -n "${namespace}" -o name 2>/dev/null); do
            kubectl patch "${resource}" -n "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    done
    
    # Step 8: Handle CRDs with finalizers (common in operators like Strimzi, Kafka, etc.)
    echo "  Cleaning up CRDs..."
    # Strimzi/Kafka CRDs
    for crd_type in kafkas kafkatopics kafkausers kafkaconnects kafkabridges; do
        for resource in $(kubectl get "${crd_type}" -n "${namespace}" -o name 2>/dev/null); do
            kubectl patch "${resource}" -n "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete "${resource}" -n "${namespace}" --force --grace-period=0 2>/dev/null || true
        done
    done
    # Nuclio CRDs
    for crd_type in nucliofunctions nuclioprojects nucliofunctionevents nuclioapigateways; do
        for resource in $(kubectl get "${crd_type}" -n "${namespace}" -o name 2>/dev/null); do
            kubectl patch "${resource}" -n "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete "${resource}" -n "${namespace}" --force --grace-period=0 2>/dev/null || true
        done
    done
    # Spark CRDs
    for crd_type in sparkapplications scheduledsparkapplications; do
        for resource in $(kubectl get "${crd_type}" -n "${namespace}" -o name 2>/dev/null); do
            kubectl patch "${resource}" -n "${namespace}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete "${resource}" -n "${namespace}" --force --grace-period=0 2>/dev/null || true
        done
    done
    
    # Step 9: Brief wait for resources to clear
    sleep 2
    
    # Step 10: Remove namespace finalizers and delete namespace (with retry)
    while [[ ${retry} -lt ${max_retries} ]]; do
        echo "  Removing namespace finalizers (attempt $((retry + 1))/${max_retries})..."
        kubectl get namespace "${namespace}" -o json 2>/dev/null | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - 2>/dev/null || true
        
        kubectl delete namespace "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
        
        # Check if namespace is gone
        sleep 2
        if ! kubectl get namespace "${namespace}" &>/dev/null; then
            return 0
        fi
        
        ((retry++))
    done
    
    # Final check
    if kubectl get namespace "${namespace}" &>/dev/null; then
        return 1
    fi
    return 0
}

# Uninstall a namespace release
uninstall_namespace() {
    local release="${1:-}"
    local namespace="${2:-}"
    
    print_header "Uninstalling: ${release}"
    echo "Release: ${release}"
    echo "Namespace: ${namespace}"
    echo ""
    
    # Uninstall Helm release
    # shellcheck disable=SC2312
    if helm list -n "${namespace}" 2>/dev/null | grep -q "${release}"; then
        echo "Uninstalling Helm release '${release}'..."
        helm uninstall -n "${namespace}" "${release}" --wait=hookOnly
        echo -e "${GREEN}✓${NC} Helm release uninstalled"
    else
        echo -e "${YELLOW}Helm release '${release}' not found. Skipping.${NC}"
    fi
    
    # Delete namespace with appropriate method
    # shellcheck disable=SC2310
    if is_local_cluster; then
        # Local cluster: use aggressive cleanup
        if force_cleanup_namespace "${namespace}"; then
            echo -e "${GREEN}✓${NC} Namespace ${namespace} deleted"
        else
            echo -e "${YELLOW}⚠ Namespace ${namespace} still exists (may need manual cleanup)${NC}"
        fi
    else
        # Cloud cluster: graceful delete with timeout
        local pvc_output
        pvc_output=$(kubectl get pvc -n "${namespace}" --no-headers 2>/dev/null) || true
        PVC_COUNT=$(echo "${pvc_output}" | grep -c . || echo "0")
        if [[ "${PVC_COUNT:-0}" -gt 0 ]]; then
            echo "Deleting PVCs in namespace ${namespace}..."
            kubectl delete pvc --all -n "${namespace}" --timeout=60s 2>/dev/null || true
        fi
        if kubectl get namespace "${namespace}" &>/dev/null; then
            echo "Deleting namespace ${namespace}..."
            kubectl delete namespace "${namespace}" --timeout=120s 2>/dev/null || true
        fi
        if ! kubectl get namespace "${namespace}" &>/dev/null; then
            echo -e "${GREEN}✓${NC} Namespace ${namespace} deleted"
        else
            echo -e "${YELLOW}⚠ Namespace ${namespace} still exists (may need manual cleanup)${NC}"
        fi
    fi
    
    remove_hosts_for_namespace "${namespace}"
    echo ""
}

# Uninstall the controller
uninstall_controller() {
    print_header "Uninstalling Controller"
    echo "Release: ${CONTROLLER_RELEASE}"
    echo "Namespace: ${CONTROLLER_NAMESPACE}"
    echo ""
    
    # shellcheck disable=SC2310
    if ! is_controller_installed; then
        echo -e "${YELLOW}Controller not installed. Skipping.${NC}"
        return
    fi
    
    # Uninstall Helm release
    echo "Uninstalling Helm release '${CONTROLLER_RELEASE}'..."
    helm uninstall -n "${CONTROLLER_NAMESPACE}" "${CONTROLLER_RELEASE}" --wait=hookOnly
    echo -e "${GREEN}✓${NC} Controller release uninstalled"
    
    # Delete namespace with appropriate method
    # shellcheck disable=SC2310
    if is_local_cluster; then
        # Local cluster: use aggressive cleanup
        if force_cleanup_namespace "${CONTROLLER_NAMESPACE}"; then
            echo -e "${GREEN}✓${NC} Controller namespace deleted"
        else
            echo -e "${YELLOW}⚠ Controller namespace still exists (may need manual cleanup)${NC}"
        fi
    else
        # Cloud cluster: graceful delete with timeout
        local pvc_output
        pvc_output=$(kubectl get pvc -n "${CONTROLLER_NAMESPACE}" --no-headers 2>/dev/null) || true
        PVC_COUNT=$(echo "${pvc_output}" | grep -c . || echo "0")
        if [[ "${PVC_COUNT:-0}" -gt 0 ]]; then
            echo "Deleting PVCs in namespace ${CONTROLLER_NAMESPACE}..."
            kubectl delete pvc --all -n "${CONTROLLER_NAMESPACE}" --timeout=60s 2>/dev/null || true
        fi
        if kubectl get namespace "${CONTROLLER_NAMESPACE}" &>/dev/null; then
            echo "Deleting namespace ${CONTROLLER_NAMESPACE}..."
            kubectl delete namespace "${CONTROLLER_NAMESPACE}" --timeout=120s 2>/dev/null || true
        fi
        if ! kubectl get namespace "${CONTROLLER_NAMESPACE}" &>/dev/null; then
            echo -e "${GREEN}✓${NC} Controller namespace deleted"
        fi
    fi
    
    echo ""
}

# Show usage
show_usage() {
    local script_name
    script_name=$(basename "$0") || true
    echo ""
    echo "MLRun CE Helm Uninstall Script"
    echo ""
    echo "Usage:"
    echo "  ${script_name} <namespace> [--remote user@ip] [--allow-cloud]"
    echo "  ${script_name} controller [--remote user@ip] [--allow-cloud]"
    echo "  ${script_name} all [--remote user@ip] [--allow-cloud]"
    echo "  ${script_name} list [--remote user@ip]"
    echo "  ${script_name}                        # Interactive mode"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  --remote user@ip   Connect to remote VM (e.g., iguazio@192.168.224.180)"
    echo "  --allow-cloud      Allow uninstall on cloud clusters (EKS/AKS/GKE)"
    echo "  --clean-images     Remove Docker images from cluster nodes (for fresh install test)"
    echo ""
    echo "Configuration is loaded from .env file in the same directory as this script."
    echo "Default (no --remote): Local mode - prompts for kubeconfig/context selection."
    echo ""
    echo "Safety: This script blocks uninstall on cloud clusters by default."
    echo "        Local clusters (docker-desktop, minikube, kind) are allowed."
    echo ""
    echo "Examples:"
    echo "  # Local (interactive or last selection)"
    echo "  ${script_name} mlrun                  # Uninstall 'mlrun' namespace"
    echo "  ${script_name} all                    # Uninstall everything"
    echo ""
    echo "  # Remote VM"
    echo "  ${script_name} mlrun --remote iguazio@192.168.224.180"
    echo "  ${script_name} all --remote iguazio@192.168.236.6"
    echo ""
    exit 1
}

# Interactive mode - select what to uninstall
interactive_mode() {
    while true; do
        echo ""
        echo "Installed releases:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        # shellcheck disable=SC2310
        if ! list_mlrun_releases; then
            echo "(none)"
        fi
        # shellcheck disable=SC2310
        if is_controller_installed; then
            echo ""
            echo "Controller: ${CONTROLLER_RELEASE} (Namespace: ${CONTROLLER_NAMESPACE})"
        fi
        echo ""
        echo "Select release number to uninstall, or:"
        echo "  c = controller, a = all, r = refresh, q = quit"
        read -r -p "Choice: " choice

        case "${choice:-}" in
            q|Q)
                echo "Exiting."
                exit 0
                ;;
            r|R)
                continue
                ;;
            c|C)
                uninstall_controller
                ;;
            a|A)
                uninstall_all
                ;;
            *)
                if [[ "${choice:-}" =~ ^[0-9]+$ ]] && [[ "${choice:-0}" -ge 1 ]] && [[ "${choice:-0}" -le ${#RELEASE_LIST[@]} ]]; then
                    local selected="${RELEASE_LIST[$((choice-1))]}"
                    local release_name
                    local namespace
                    release_name=$(echo "${selected}" | cut -d'|' -f1) || true
                    namespace=$(echo "${selected}" | cut -d'|' -f2) || true
                    uninstall_namespace "${release_name}" "${namespace}"
                else
                    echo -e "${RED}Invalid selection${NC}"
                fi
                ;;
        esac
    done
}

# Uninstall all releases and controller
uninstall_all() {
    print_header "Uninstalling ALL MLRun CE Releases"
    
    echo -e "${YELLOW}⚠️  WARNING: This will uninstall ALL MLRun CE namespaces and the controller!${NC}"
    read -r -p "Are you sure? (y/N): " confirm
    
    if [[ ! "${confirm:-}" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return
    fi
    
    # Get all releases
    RELEASES=$(helm list --all-namespaces 2>/dev/null | grep -v "^NAME" | grep -v "${CONTROLLER_RELEASE}" | awk '{print $1 "|" $2}' || true)
    
    # Uninstall each namespace release
    if [[ -n "${RELEASES:-}" ]]; then
        while IFS='|' read -r release namespace; do
            # Skip if it looks like system namespace
            if  [[ "${namespace:-}" == "kube-system" ]] || \
                [[ "${namespace:-}" == "default" ]] || \
                [[ "${namespace:-}" == "ingress-nginx" ]]; then
                continue
            fi
            # Only uninstall if it's likely an MLRun release (has mlrun components)
            # shellcheck disable=SC2312
            if kubectl get pods -n "${namespace}" 2>/dev/null | grep -qE "mlrun|jupyter|nuclio|minio"; then
                uninstall_namespace "${release}" "${namespace}"
            fi
        done <<< "${RELEASES}"
    fi
    
    # Uninstall controller
    uninstall_controller
    
    # Clean images if requested
    if [[ "${CLEAN_IMAGES:-0}" -eq 1 ]]; then
        clean_cluster_images
    fi
    
    print_header "Cleanup Complete!"
    echo -e "${GREEN}✓${NC} All MLRun CE installations removed."
}

# ============================================================================
# Main
# ============================================================================

# Parse all arguments in single pass
MODE=""
FORCE_MODE=""
while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --allow-cloud)
            ALLOW_CLOUD=1
            shift
        ;;
        --clean-images)
            CLEAN_IMAGES=1
            shift
        ;;
        -h|--help|help)
            show_usage
        ;;
        --remote)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                echo -e "${RED}ERROR: --remote requires user@ip argument${NC}"
                exit 1
            fi
            if [[ "$2" != *"@"* ]]; then
                echo -e "${RED}ERROR: --remote requires user@ip format (e.g., iguazio@192.168.224.180)${NC}"
                exit 1
            fi
            USE_LOCAL_CONTEXT=0
            FORCE_MODE="remote"
            JUMP_USER="${2%%@*}"
            JUMP_IP="${2##*@}"
            export JUMP_USER JUMP_IP
            shift 2
        ;;
        --*)
            shift  # Skip unknown flags
        ;;
        *)
            if [[ -z "${MODE}" ]]; then
                MODE="${1}"
            fi
            shift
        ;;
    esac
done

# Select cluster / context
if [[ "${FORCE_MODE:-}" == "remote" ]]; then
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        echo -e "${RED}ERROR: CLUSTER_NAME is required for remote connections${NC}"
        echo "Set it in .env or export CLUSTER_NAME=<name> before running"
        exit 1
    fi
else
    # No --remote flag: use the current kubeconfig context
    USE_LOCAL_CONTEXT=1
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        CLUSTER_NAME=$(kubectl config current-context 2>/dev/null)
    fi
fi

# shellcheck disable=SC2310
CLUSTER_NAME=$(sanitize_cluster_name "${CLUSTER_NAME:-}") || true

# Set kubeconfig
if [[ "${USE_LOCAL_CONTEXT:-1}" -eq 1 ]]; then
    if [[ -z "${KUBECONFIG_PATH:-}" ]]; then
        KUBECONFIG_PATH="${HOME}/.kube/config"
    fi
else
    KUBECONFIG_PATH="${HOME}/.kube/config_${CLUSTER_NAME}"
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    echo -e "${RED}ERROR: KUBECONFIG file not found at: ${KUBECONFIG_PATH}${NC}"
    exit 1
fi
export KUBECONFIG="${KUBECONFIG_PATH}"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl config use-context "${KUBE_CONTEXT}" &>/dev/null || true
fi

# Test connectivity
test_cluster_connectivity

# Safety check - block cloud clusters unless explicitly allowed
check_cluster_safety

case "${MODE:-}" in
    "")
        # Interactive mode
        interactive_mode
        ;;
    
    list)
        list_mlrun_releases
        # shellcheck disable=SC2310
        if is_controller_installed; then
            echo ""
            echo "Controller: ${CONTROLLER_RELEASE} (Namespace: ${CONTROLLER_NAMESPACE})"
        fi
        ;;
    
    controller)
        uninstall_controller
        print_header "Done!"
        ;;
    
    all)
        uninstall_all
        ;;
    
    help|--help|-h)
        show_usage
        ;;
    
    *)
        # Assume it's a namespace name
        uninstall_namespace "${MODE}" "${MODE}"
        
        # Ask if they want to also remove controller
        # shellcheck disable=SC2310
        if is_controller_installed; then
            echo ""
            read -r -p "Do you also want to uninstall the controller? (y/N): " confirm
            if [[ "${confirm:-}" =~ ^[Yy]$ ]]; then
                uninstall_controller
            fi
        fi
        
        # Clean images if requested
        if [[ "${CLEAN_IMAGES:-0}" -eq 1 ]]; then
            clean_cluster_images
        fi
        
        print_header "Done!"
        ;;
esac

echo -e "${GREEN}Done!${NC}"
