#!/bin/bash

# MLRun CE Helm Install Script
# Supports two modes:
#   1. Single namespace  - Direct install using values.yaml (no controller)
#   2. Multi-namespace   - Controller install first, then namespace installs

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

# Required configuration (must be set in .env)
DOMAIN="${DOMAIN:-}"
INGRESS_CLASS="${INGRESS_CLASS:-}"

# Optional configuration (sensible defaults, can be overridden in .env)
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-v1.11.3}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs-client}"
KAFKA_PVC_SIZE="${KAFKA_PVC_SIZE:-8Gi}"
INSECURE_TLS="${INSECURE_TLS:-1}"
SUDO_PASS="${SUDO_PASS:-}"
EXTRA_VALUES_FILES=()

# Internal state
CHART_PATH="${CHART_PATH:-$(cd "${SCRIPT_DIR}/../charts/mlrun-ce" 2>/dev/null && pwd || echo "")}"
NON_ADMIN_VALUES="${NON_ADMIN_VALUES:-}"
KUBE_CONTEXT=""
USE_LOCAL_CONTEXT=1
KUBECONFIG_PATH=""
MULTI_MODE=0
HOSTS_IP="127.0.0.1"
AUTO_CONFIRM=0
NO_INGRESS=0
CLUSTER_IP=0

# Discover all ingress paths in values.yaml dynamically
# Returns lines in format: ingress_path|host_prefix|host_format|needs_paths
discover_ingresses() {
    local values_file="${CHART_PATH}/values.yaml"
    
    if [[ ! -f "${values_file}" ]]; then
        echo -e "${RED}ERROR: values.yaml not found at: ${values_file}${NC}" >&2
        return 1
    fi
    
    if ! command -v yq &>/dev/null; then
        echo -e "${RED}ERROR: yq is required for dynamic ingress discovery${NC}" >&2
        echo "Install with: brew install yq" >&2
        return 1
    fi
    
    # Find all paths ending in .ingress or Ingress (all possible ingress configs)
    local ingress_paths
    ingress_paths=$(yq eval '.. | path | join(".")' "${values_file}" 2>/dev/null | grep -E '\.ingress$|Ingress$' | sort -u || true)
    
    while IFS= read -r ingress_path; do
        [[ -z "${ingress_path:-}" ]] && continue
        
        # Generate host_prefix from ingress path (fully dynamic)
        # Example: mlrun.api.ingress → mlrun-api
        #          minio.consoleIngress → minio-console
        #          kube-prometheus-stack.grafana.ingress → kube-prometheus-stack-grafana
        local host_prefix
        host_prefix=$(echo "${ingress_path}" | \
            sed -E 's/(\.ingress|Ingress)$//' | \
            sed 's/\./-/g' | \
            tr '[:upper:]' '[:lower:]') || true
        
        # Detect host format by checking:
        # 1. If .path exists at ingress level → simple string hosts (Grafana-style)
        # 2. If hosts[0] is a string → simple string hosts
        # 3. Check subchart defaults for nested dependencies
        # 4. Otherwise → map format with paths (K8s standard)
        local host_format
        local needs_paths
        local has_path_field
        has_path_field=$(yq eval ".${ingress_path}.path" "${values_file}" 2>/dev/null || echo "null")
        
        if [[ "${has_path_field}" != "null" ]]; then
            # Chart has path at ingress level → check if it uses 'host' (singular) or 'hosts[0]'
            local has_singular_host
            has_singular_host=$(yq eval ".${ingress_path} | has(\"host\")" "${values_file}" 2>/dev/null || echo "false")
            if [[ "${has_singular_host}" == "true" ]]; then
                # Template uses singular 'host' field (e.g., seaweedfs.adminService.ingress.host)
                host_format="host"
            else
                # Template uses 'hosts[0]' array
                host_format="hosts[0]"
            fi
            needs_paths="false"
        else
            local hosts_type
            hosts_type=$(yq eval ".${ingress_path}.hosts[0] | type" "${values_file}" 2>/dev/null || echo "")
            
            if [[ "${hosts_type}" == "!!str" ]]; then
                # hosts is explicitly a list of strings
                host_format="hosts[0]"
                needs_paths="false"
            elif [[ "${hosts_type}" == "!!null" ]] || [[ -z "${hosts_type}" ]]; then
                # hosts not defined in parent values - check subchart defaults
                # Parse ingress_path to find subchart
                local path_segments
                IFS='.' read -ra path_segments <<< "${ingress_path}"
                local chart_name="${path_segments[0]}"
                local tgz_file tgz_files
                tgz_files=$(find "${CHART_PATH}/charts" -name "${chart_name}-*.tgz" 2>/dev/null || true)
                tgz_file=$(echo "${tgz_files}" | head -1)
                
                if [[ -n "${tgz_file}" ]]; then
                    local subchart_has_path="null"
                    
                    if [[ ${#path_segments[@]} -ge 3 ]]; then
                        local potential_nested="${path_segments[1]}"
                        # Build the values path without the chart name (e.g., "dashboard.ingress" for nuclio.dashboard.ingress)
                        local values_path="${ingress_path#"${chart_name}."}"
                        
                        # First check if it's a nested chart (e.g., grafana inside kube-prometheus-stack)
                        local tar_list
                        tar_list=$(tar -tzf "${tgz_file}" 2>/dev/null || true)
                        if echo "${tar_list}" | grep -q "^${chart_name}/charts/${potential_nested}/"; then
                            # It's a nested subchart - check nested chart's values.yaml
                            local nested_values
                            nested_values=$(tar -xzf "${tgz_file}" -O "${chart_name}/charts/${potential_nested}/values.yaml" 2>/dev/null || true)
                            subchart_has_path=$(echo "${nested_values}" | yq eval '.ingress.path' - 2>/dev/null || echo "null")
                        else
                            # Not a nested chart - it's a config path within the main chart
                            # Check chart_name/values.yaml with the full values_path (e.g., dashboard.ingress.path)
                            local config_values
                            config_values=$(tar -xzf "${tgz_file}" -O "${chart_name}/values.yaml" 2>/dev/null || true)
                            subchart_has_path=$(echo "${config_values}" | yq eval ".${values_path}.path" - 2>/dev/null || echo "null")
                        fi
                    else
                        # Direct subchart: chart.ingress → check chart/values.yaml .ingress.path
                        local direct_values
                        direct_values=$(tar -xzf "${tgz_file}" -O "${chart_name}/values.yaml" 2>/dev/null || true)
                        subchart_has_path=$(echo "${direct_values}" | yq eval '.ingress.path' - 2>/dev/null || echo "null")
                    fi
                    
                    if [[ "${subchart_has_path}" != "null" ]]; then
                        host_format="hosts[0]"
                        needs_paths="false"
                    else
                        host_format="hosts[0].host"
                        needs_paths="true"
                    fi
                else
                    # No tgz found - fallback to K8s standard
                    host_format="hosts[0].host"
                    needs_paths="true"
                fi
            else
                # hosts is a map → use K8s standard format
                host_format="hosts[0].host"
                needs_paths="true"
            fi
        fi
        
        echo "${ingress_path}|${host_prefix}|${host_format}|${needs_paths}"
    done <<< "${ingress_paths}"
}

# Show ingresses that will be created and ask for confirmation
confirm_ingresses() {
    local namespace="$1"
    local ingress_list
    ingress_list=$(discover_ingresses)
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}Ingresses to be enabled for namespace '${namespace}':${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    while IFS='|' read -r ingress_path host_prefix host_format needs_paths; do
        [[ -z "${ingress_path:-}" ]] && continue
        local hostname="${host_prefix}.${namespace}.${CLUSTER_NAME}.${DOMAIN}"
        printf "  %-35s -> %s\n" "${ingress_path}" "${hostname}"
    done <<< "${ingress_list:-}"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ "${AUTO_CONFIRM:-0}" -eq 1 ]]; then
        echo "Auto-confirmed (-y flag)"
        return 0
    fi
    
    read -r -p "Proceed with installation? (Y/n) [Y]: " confirm
    if [[ "${confirm:-}" =~ ^[Nn]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Update or append a key=value in the .env file
update_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
    elif grep -q "^# *${key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i.bak "s|^# *${key}=.*|${key}=\"${value}\"|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
    else
        printf '%s="%s"\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
}

# Ensure .env exists and required variables are set.
# In interactive mode (no args): prompts the user and saves to .env
# In CLI mode (with args): fails fast with a clear error message
init_env() {
    local interactive="${1:-0}"

    if [[ ! -f "${ENV_FILE}" ]]; then
        if [[ "${interactive}" -eq 1 ]]; then
            if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
                echo ""
                echo -e "${BLUE}No .env file found. Creating one from .env.example...${NC}"
                cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
            else
                echo ""
                echo -e "${BLUE}No .env file found. Creating a new one...${NC}"
                touch "${ENV_FILE}"
            fi
        fi
    fi

    # Source .env if it exists (may have values from create_kubeconfig_ce.sh or partial fill)
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi
    DOMAIN="${DOMAIN:-}"
    INGRESS_CLASS="${INGRESS_CLASS:-}"

    local missing=()
    [[ -z "${DOMAIN}" ]] && missing+=("DOMAIN")
    [[ -z "${INGRESS_CLASS}" ]] && missing+=("INGRESS_CLASS")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    # --- CLI mode: fail fast ---
    if [[ "${interactive}" -eq 0 ]]; then
        echo ""
        echo -e "${RED}ERROR: Missing required configuration variables:${NC}"
        for var in "${missing[@]}"; do
            echo -e "  ${RED}✗${NC} ${var}"
        done
        echo ""
        if [[ ! -f "${ENV_FILE}" ]]; then
            echo "No .env file found. Create one from the template:"
            echo "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
            echo "  vi ${SCRIPT_DIR}/.env"
        else
            echo "Edit your .env file and set the missing variables:"
            echo "  vi ${ENV_FILE}"
        fi
        echo ""
        echo "Or run without arguments for interactive setup:"
        echo "  ./$(basename "${BASH_SOURCE[0]}")"
        echo ""
        exit 1
    fi

    # --- Interactive mode: prompt and save ---
    local local_cluster=0
    if is_local_cluster; then
        local_cluster=1
        local ctx
        ctx=$(kubectl config current-context 2>/dev/null) || true
        echo ""
        echo -e "${GREEN}✓${NC} Detected local cluster: ${ctx}"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}  First-time setup: configure required variables${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "${local_cluster}" -eq 1 ]]; then
        echo ""
        echo -e "${YELLOW}  Local cluster detected -- DOMAIN and INGRESS_CLASS are only${NC}"
        echo -e "${YELLOW}  needed if you plan to use ingresses. You can skip them for now${NC}"
        echo -e "${YELLOW}  and use NodePort access (--no-ingress) instead.${NC}"
    fi

    if [[ -z "${DOMAIN}" ]]; then
        echo ""
        echo "DOMAIN: DNS domain for ingress hostnames"
        echo "  Hostnames will be: <service>.<namespace>.<cluster>.<domain>"
        if [[ "${local_cluster}" -eq 1 ]]; then
            read -r -p "  Enter DOMAIN (leave empty for 'local'): " DOMAIN
            if [[ -z "${DOMAIN}" ]]; then
                DOMAIN="local"
                echo -e "  ${GREEN}→ Using '${DOMAIN}' for local cluster${NC}"
            fi
        else
            read -r -p "  Enter DOMAIN: " DOMAIN
            if [[ -z "${DOMAIN}" ]]; then
                echo -e "${RED}ERROR: DOMAIN is required for remote clusters.${NC}"
                exit 1
            fi
        fi
        update_env_var "DOMAIN" "${DOMAIN}"
    fi

    if [[ -z "${INGRESS_CLASS}" ]]; then
        echo ""
        echo "INGRESS_CLASS: Kubernetes ingress class name"
        echo "  Common values: nginx, traefik, haproxy, alb"
        if [[ "${local_cluster}" -eq 1 ]]; then
            INGRESS_CLASS="nginx"
            echo -e "  ${GREEN}→ Defaulting to '${INGRESS_CLASS}'${NC}"
        else
            read -r -p "  Enter INGRESS_CLASS [nginx]: " INGRESS_CLASS
            INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
        fi
        update_env_var "INGRESS_CLASS" "${INGRESS_CLASS}"
    fi

    echo ""
    echo -e "${GREEN}✓${NC} Required variables saved to ${ENV_FILE}"

    # Auto-adjust defaults for local clusters
    if [[ "${local_cluster}" -eq 1 ]]; then
        echo ""
        echo -e "${BLUE}Select storage class for your local cluster:${NC}"
        local smart_sc
        smart_sc=$(select_storage_class)
        if [[ -n "${smart_sc}" ]]; then
            STORAGE_CLASS="${smart_sc}"
            update_env_var "STORAGE_CLASS" "${STORAGE_CLASS}"
            echo -e "${GREEN}✓${NC} Storage class set to '${STORAGE_CLASS}'"
        fi
        INGRESS_NGINX_VERSION=""
        update_env_var "INGRESS_NGINX_VERSION" ""
        echo -e "${GREEN}✓${NC} Skipping nginx-ingress install (local cluster)"
    fi

    echo ""
    read -r -p "Customize optional settings? (y/N): " customize
    if [[ "${customize}" =~ ^[Yy]$ ]]; then
        echo ""
        read -r -p "  STORAGE_CLASS [${STORAGE_CLASS}]: " input
        [[ -n "${input}" ]] && STORAGE_CLASS="${input}" && update_env_var "STORAGE_CLASS" "${STORAGE_CLASS}"

        read -r -p "  KAFKA_PVC_SIZE [${KAFKA_PVC_SIZE}]: " input
        [[ -n "${input}" ]] && KAFKA_PVC_SIZE="${input}" && update_env_var "KAFKA_PVC_SIZE" "${KAFKA_PVC_SIZE}"

        read -r -p "  INSECURE_TLS (1=skip, 0=strict) [${INSECURE_TLS}]: " input
        [[ -n "${input}" ]] && INSECURE_TLS="${input}" && update_env_var "INSECURE_TLS" "${INSECURE_TLS}"

        read -r -p "  INGRESS_NGINX_VERSION (empty=skip install) [${INGRESS_NGINX_VERSION}]: " input
        if [[ -n "${input}" ]]; then
            INGRESS_NGINX_VERSION="${input}"
            update_env_var "INGRESS_NGINX_VERSION" "${INGRESS_NGINX_VERSION}"
        fi

        echo ""
        echo -e "${GREEN}✓${NC} Optional settings saved to ${ENV_FILE}"
    fi

    echo ""
    echo -e "${GREEN}✓${NC} Setup complete. Settings are saved in ${ENV_FILE}"
    echo "  You can edit this file anytime to change values."
    echo ""
}

# Sanitize cluster name for DNS (extract part after @ if present)
sanitize_cluster_name() {
    local name="$1"
    if [[ "${name:-}" == *"@"* ]]; then
        echo "${name##*@}"
    else
        echo "${name:-}"
    fi
}

# Quick check if current kube context looks like a local dev cluster.
# Returns 0 (true) if local, 1 (false) otherwise. Does NOT require cluster access.
is_local_cluster() {
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null) || true
    [[ "${ctx:-}" =~ (docker-desktop|minikube|rancher-desktop|colima|orbstack) ]]
}

# Query the cluster for available storage classes and let the user pick.
# Falls back to manual input if kubectl is unavailable.
# Usage: sc=$(select_storage_class)
select_storage_class() {
    local sc_list
    sc_list=$(kubectl get sc --no-headers -o custom-columns='NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class' 2>/dev/null) || true

    if [[ -z "${sc_list:-}" ]]; then
        read -r -p "  STORAGE_CLASS (kubectl unavailable, enter manually) [${STORAGE_CLASS}]: " input
        echo "${input:-${STORAGE_CLASS}}"
        return
    fi

    local names=() defaults=()
    while IFS= read -r line; do
        local name default_flag
        name=$(echo "${line}" | awk '{print $1}')
        default_flag=$(echo "${line}" | awk '{print $2}')
        names+=("${name}")
        if [[ "${default_flag}" == "true" ]]; then
            defaults+=("${name}")
        fi
    done <<< "${sc_list}"

    if [[ ${#names[@]} -eq 0 ]]; then
        read -r -p "  No storage classes found. Enter manually [${STORAGE_CLASS}]: " input
        echo "${input:-${STORAGE_CLASS}}"
        return
    fi

    local options=()
    for name in "${names[@]}"; do
        if [[ " ${defaults[*]:-} " == *" ${name} "* ]]; then
            options+=("${name}  (default)")
        else
            options+=("${name}")
        fi
    done
    options+=("Enter manually")

    local sc_idx
    sc_idx=$(prompt_select "Available storage classes:" "${options[@]}")

    if [[ "${sc_idx}" -lt ${#names[@]} ]]; then
        echo "${names[${sc_idx}]}"
    else
        read -r -p "  Enter storage class name: " input
        echo "${input:-${STORAGE_CLASS}}"
    fi
}

print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}$1${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Detect cluster type and set appropriate configuration
# Sets: CLUSTER_TYPE (kind|rke|k3s|kubeadm|cloud|local|unknown)
#       NEEDS_DNAT (true if Kind cluster needing port forwarding)
#       K8S_NODE_IP (the actual K8s node IP for /etc/hosts)
detect_cluster_type() {
    echo "Detecting cluster type..."
    
    CLUSTER_TYPE="unknown"
    NEEDS_DNAT="false"
    K8S_NODE_IP=""
    
    local context_name
    context_name=$(kubectl config current-context 2>/dev/null) || true
    context_name="${KUBE_CONTEXT:-${context_name:-}}"
    
    local node_info
    node_info=$(kubectl get nodes -o wide --no-headers 2>/dev/null | head -1) || true
    local node_name
    node_name=$(echo "${node_info}" | awk '{print $1}') || true
    local node_ip
    node_ip=$(echo "${node_info}" | awk '{print $6}') || true
    
    # Check for local development clusters
    if [[ "${context_name:-}" =~ (docker-desktop|minikube|rancher-desktop|colima|orbstack) ]]; then
        CLUSTER_TYPE="local"
        K8S_NODE_IP="127.0.0.1"
        echo -e "  ${GREEN}✓${NC} Detected: Local cluster (${context_name})"
        echo "  Using localhost for /etc/hosts"
        return
    fi
    
    # Check for Kind cluster (node name ends in -control-plane or -worker)
    if [[ "${node_name:-}" =~ -control-plane$ ]] || [[ "${node_name:-}" =~ -worker$ ]]; then
        CLUSTER_TYPE="kind"
        NEEDS_DNAT="true"
        # For Kind, use the jump host IP (VM IP) since we'll set up DNAT
        K8S_NODE_IP="${JUMP_IP:-${HOSTS_IP:-}}"
        echo -e "  ${GREEN}✓${NC} Detected: Kind cluster (node: ${node_name})"
        echo "  Kind node internal IP: ${node_ip} (Docker network)"
        echo "  Using VM IP for /etc/hosts: ${K8S_NODE_IP}"
        return
    fi
    
    # Check for cloud clusters
    if [[ "${context_name:-}" =~ (eks|aks|gke|aws|azure|gcp|amazonaws|googlecloud) ]]; then
        CLUSTER_TYPE="cloud"
        # For cloud, use the LoadBalancer external IP (will be assigned by cloud provider)
        K8S_NODE_IP="${node_ip}"
        echo -e "  ${YELLOW}⚠${NC} Detected: Cloud cluster (${context_name})"
        echo "  Note: Ingress should use LoadBalancer with external IP"
        return
    fi
    
    # Check for RKE/k3s/kubeadm (real VMs, not containerized)
    # These typically have node names matching the hostname or IP pattern
    if [[ "${node_name:-}" =~ ^[0-9]+-[0-9]+-[0-9]+-[0-9]+ ]] || \
       [[ "${node_name:-}" =~ (master|worker|node|k8s) ]] || \
       [[ -n "${node_ip:-}" && ! "${node_ip:-}" =~ ^172\. && ! "${node_ip:-}" =~ ^10\.244\. ]]; then
        # Node IP is not in typical Docker/Kind network ranges
        CLUSTER_TYPE="rke"
        K8S_NODE_IP="${node_ip}"
        echo -e "  ${GREEN}✓${NC} Detected: Bare-metal/VM cluster (RKE/k3s/kubeadm)"
        echo "  Node: ${node_name}"
        echo "  Using K8s node IP for /etc/hosts: ${K8S_NODE_IP}"
        return
    fi
    
    # Unknown - use provided HOSTS_IP or node IP
    echo -e "  ${YELLOW}⚠${NC} Could not determine cluster type"
    K8S_NODE_IP="${HOSTS_IP:-${node_ip:-}}"
    echo "  Using IP for /etc/hosts: ${K8S_NODE_IP}"
}

# Update HOSTS_IP based on detected cluster type
apply_cluster_detection() {
    detect_cluster_type
    
    # Override HOSTS_IP with detected K8S_NODE_IP if available
    if [[ -n "${K8S_NODE_IP:-}" ]]; then
        if [[ "${HOSTS_IP:-}" != "${K8S_NODE_IP:-}" ]]; then
            echo ""
            echo -e "${YELLOW}Updating /etc/hosts IP:${NC}"
            echo "  Previous: ${HOSTS_IP:-<not set>}"
            echo "  Detected: ${K8S_NODE_IP}"
            HOSTS_IP="${K8S_NODE_IP}"
        fi
    fi
    
    # Local clusters should use 'local' domain
    if [[ "${CLUSTER_TYPE:-}" == "local" ]] && [[ "${DOMAIN:-}" != "local" ]]; then
        echo -e "${YELLOW}Overriding domain for local cluster: '${DOMAIN:-}' → 'local'${NC}"
        DOMAIN="local"
    fi
    echo ""
}

install_ingress_nginx() {
    if [[ -z "${INGRESS_NGINX_VERSION:-}" ]]; then
        echo "Skipping ingress-nginx install (INGRESS_NGINX_VERSION is empty)"
        return
    fi
    
    if kubectl get deployment -n ingress-nginx ingress-nginx-controller &>/dev/null; then
        echo "ingress-nginx already installed."
    else
        echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION}..."
        kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
        kubectl rollout status -n ingress-nginx deployment/ingress-nginx-controller --timeout=2m
    fi
    
    # Configure DNAT rules only for Kind clusters (they need port forwarding from VM to Docker)
    if [[ "${CLUSTER_TYPE:-}" == "kind" ]] && [[ "${NEEDS_DNAT:-}" == "true" ]] && \
       [[ -n "${JUMP_USER:-}" ]] && [[ -n "${JUMP_IP:-}" ]]; then
        configure_kind_ingress_dnat
    elif [[ "${CLUSTER_TYPE:-}" == "rke" ]] || [[ "${CLUSTER_TYPE:-}" == "k3s" ]]; then
        echo "Bare-metal/VM cluster detected - no DNAT needed (direct access to node)"
    fi
}

# Configure DNAT rules for KIND ingress with proper interface filtering
# This ensures outbound traffic from containers is NOT intercepted
configure_kind_ingress_dnat() {
    echo "Configuring ingress DNAT rules on remote VM..."
    
    # Get ingress NodePorts
    local http_nodeport
    local https_nodeport
    http_nodeport=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    https_nodeport=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
    
    if [[ -z "${http_nodeport:-}" ]] || [[ -z "${https_nodeport:-}" ]]; then
        echo "  ⚠️  Could not get ingress NodePorts, skipping DNAT configuration"
        return
    fi
    
    echo "  Ingress NodePorts: HTTP=${http_nodeport:-}, HTTPS=${https_nodeport:-}"
    
    # Run DNAT configuration on remote VM
    # shellcheck disable=SC2087
    ssh "${JUMP_USER}@${JUMP_IP}" bash << REMOTE_SCRIPT
set -e

_SUDO_PASS='${SUDO_PASS:-}'
_run_sudo() {
    if [ -n "\$_SUDO_PASS" ]; then
        echo "\$_SUDO_PASS" | sudo -S "\$@" 2>/dev/null
    else
        sudo "\$@"
    fi
}

# Get KIND node IP (Docker bridge network)
KIND_NODE_IP=\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \$(docker ps -qf "name=control-plane") 2>/dev/null || echo "")
if [ -z "\$KIND_NODE_IP" ]; then
    echo "  ⚠️  Could not determine KIND node IP"
    exit 0
fi
echo "  KIND node IP: \$KIND_NODE_IP"

# Get the external interface (the one with default route)
EXT_IFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
if [ -z "\$EXT_IFACE" ]; then
    echo "  ⚠️  Could not determine external interface"
    exit 0
fi
echo "  External interface: \$EXT_IFACE"

# Remove any existing DNAT rules for ports 80/443 that DON'T have interface filter
# These are the problematic rules that intercept outbound traffic
echo "  Cleaning up any misconfigured DNAT rules..."

# Check if nft is available
if command -v nft &>/dev/null; then
    # Remove rules without interface filter (the problematic ones)
    for handle in \$(_run_sudo nft -a list chain ip nat PREROUTING 2>/dev/null | grep -E 'tcp dport (80|443).*dnat' | grep -v 'iifname' | awk '{print \$NF}'); do
        echo "    Removing nft rule handle \$handle"
        _run_sudo nft delete rule ip nat PREROUTING handle \$handle 2>/dev/null || true
    done
    
    # Add correct rules with interface filter (only if not already present)
    if ! _run_sudo nft list chain ip nat PREROUTING 2>/dev/null | grep -q "iifname.*dport 80.*dnat"; then
        echo "  Adding DNAT rule for HTTP (port 80 -> ${http_nodeport:-})"
        _run_sudo nft add rule ip nat PREROUTING iifname "\$EXT_IFACE" tcp dport 80 dnat to \$KIND_NODE_IP:${http_nodeport:-} 2>/dev/null || true
    fi
    
    if ! _run_sudo nft list chain ip nat PREROUTING 2>/dev/null | grep -q "iifname.*dport 443.*dnat"; then
        echo "  Adding DNAT rule for HTTPS (port 443 -> ${https_nodeport:-})"
        _run_sudo nft add rule ip nat PREROUTING iifname "\$EXT_IFACE" tcp dport 443 dnat to \$KIND_NODE_IP:${https_nodeport:-} 2>/dev/null || true
    fi
else
    # Fallback to iptables
    _run_sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination \$KIND_NODE_IP:${http_nodeport:-} 2>/dev/null || true
    _run_sudo iptables -t nat -D PREROUTING -p tcp --dport 443 -j DNAT --to-destination \$KIND_NODE_IP:${https_nodeport:-} 2>/dev/null || true
    
    echo "  Adding DNAT rule for HTTP (port 80 -> ${http_nodeport:-})"
    _run_sudo iptables -t nat -A PREROUTING -i \$EXT_IFACE -p tcp --dport 80 -j DNAT --to-destination \$KIND_NODE_IP:${http_nodeport:-}
    
    echo "  Adding DNAT rule for HTTPS (port 443 -> ${https_nodeport:-})"
    _run_sudo iptables -t nat -A PREROUTING -i \$EXT_IFACE -p tcp --dport 443 -j DNAT --to-destination \$KIND_NODE_IP:${https_nodeport:-}
fi

echo -e "  ✓ DNAT rules configured correctly"
REMOTE_SCRIPT

    echo -e "${GREEN}✓${NC} Ingress DNAT rules configured on remote VM"
}
# Add /etc/hosts entries for a namespace (uses dynamic ingress discovery)
add_hosts_for_namespace() {
    local namespace="$1"
    local cluster="${CLUSTER_NAME:-}"
    local marker_begin="# mlrun-hosts:${namespace}:${cluster} BEGIN"
    local marker_end="# mlrun-hosts:${namespace}:${cluster} END"
    local ingress_list
    ingress_list=$(discover_ingresses)
    
    # Build entries from discovered ingresses
    local entries="${marker_begin:-}"
    while IFS='|' read -r ingress_path host_prefix host_format needs_paths; do
        [[ -z "${ingress_path:-}" ]] && continue
        local hostname="${host_prefix}.${namespace}.${cluster}.${DOMAIN}"
        entries+=$'\n'"${HOSTS_IP:-} ${hostname:-}"
    done <<< "${ingress_list:-}"
    # Add Kafka external hostname (uses NodePort, not ingress)
    entries+=$'\n'"${HOSTS_IP:-} kafka.${namespace}.${cluster}.${DOMAIN}"
    entries+=$'\n'"${marker_end:-}"

    # Remove existing entries for this namespace/cluster if present
    if sudo grep -q "${marker_begin:-}" /etc/hosts 2>/dev/null; then
        echo "Removing existing /etc/hosts entries for namespace '${namespace:-}'..."
        sudo sed -i.bak "/${marker_begin:-}/,/${marker_end:-}/d" /etc/hosts 2>/dev/null || \
        sudo sed -i '' "/${marker_begin:-}/,/${marker_end:-}/d" /etc/hosts 2>/dev/null || true
    fi
    
    echo "Adding /etc/hosts entries for namespace '${namespace:-}'..."
    echo "${entries:-}" | sudo tee -a /etc/hosts >/dev/null
}
# Function to select kubeconfig file (local kube configs)
select_kubeconfig_file() {
    local kube_dir="${HOME}/.kube"
    local files=()

    if [[ ! -d "${kube_dir:-}" ]]; then
        echo -e "${RED}ERROR: ~/.kube directory not found${NC}"
        exit 1
    fi

    local file_list
    file_list=$(find "${kube_dir:-}" -maxdepth 1 -type f \
        ! -name "*.txt" ! -name "*.md" ! -name ".DS_Store" ! -name "kubectx" 2>/dev/null | sort) || true
    
    while IFS= read -r file; do
        files+=("${file:-}")
    done <<< "${file_list:-}"

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: No kubeconfig files found in ~/.kube${NC}"
        exit 1
    fi

    echo "Available kubeconfig files:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local i=1
    for f in "${files[@]}"; do
        local name
        local ctxs
        name="$(basename "${f:-}")"
        ctxs="$(KUBECONFIG="${f:-}" kubectl config get-contexts -o name 2>/dev/null | paste -sd ', ' -)" || true
        if [[ -z "${ctxs:-}" ]]; then
            ctxs="no contexts"
        fi
        echo "${i}. ${name:-} (${ctxs:-})"
        i=$((i + 1))
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -r -p "Select kubeconfig file (1-${#files[@]}): " selection

    if ! [[ "${selection:-}" =~ ^[0-9]+$ ]] || [[ "${selection:-}" -lt 1 ]] || [[ "${selection:-}" -gt ${#files[@]} ]]; then
        echo -e "${RED}ERROR: Invalid selection${NC}"
        exit 1
    fi

    KUBECONFIG_PATH="${files[$((selection-1))]}"
    export KUBECONFIG="${KUBECONFIG_PATH:-}"
    echo -e "${GREEN}✓${NC} Selected kubeconfig: ${KUBECONFIG_PATH:-}"
    echo ""
}

# Function to select kube context (local clusters like docker-desktop)
select_kube_context() {
    local contexts=()
    local ctx_list
    ctx_list=$(kubectl config get-contexts -o name 2>/dev/null) || true
    
    while IFS= read -r ctx; do
        if [[ -n "${ctx:-}" ]]; then
            contexts+=("${ctx:-}")
        fi
    done <<< "${ctx_list:-}"

    if [[ ${#contexts[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: No kube contexts found. Is kubectl configured?${NC}"
        exit 1
    fi

    echo "Available kube contexts:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local i=1
    for ctx in "${contexts[@]}"; do
        echo "${i}. ${ctx:-}"
        i=$((i + 1))
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -r -p "Select context number (1-${#contexts[@]}): " selection

    if ! [[ "${selection:-}" =~ ^[0-9]+$ ]] || [[ "${selection:-}" -lt 1 ]] || [[ "${selection:-}" -gt ${#contexts[@]} ]]; then
        echo -e "${RED}ERROR: Invalid selection${NC}"
        exit 1
    fi

    KUBE_CONTEXT="${contexts[$((selection-1))]}"
    CLUSTER_NAME=$(sanitize_cluster_name "${KUBE_CONTEXT:-}")
    export KUBE_CONTEXT CLUSTER_NAME
    echo -e "${GREEN}✓${NC} Selected kube context: ${KUBE_CONTEXT:-}"
    echo -e "${GREEN}✓${NC} Cluster name for ingress: ${CLUSTER_NAME:-}"
    echo ""
}

# Fix SSH host key mismatch
fix_ssh_host_key() {
    local user="$1"
    local host="$2"
    local pass="${3:-${SUDO_PASS:-}}"
    
    echo "🔑 Fixing SSH host key for ${host:-}..."
    # cspell:ignore keygen
    ssh-keygen -R "${host:-}" &>/dev/null
    echo "  ✓ Removed old host key from known_hosts"
    
    if [[ -n "${pass:-}" ]]; then
        sshpass -p "${pass}" ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub "${user}@${host}" &>/dev/null || \
            echo "  ⚠️  ssh-copy-id failed (may already have key), continuing..."
    else
        ssh-copy-id -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa.pub "${user}@${host}" &>/dev/null || \
            echo "  ⚠️  ssh-copy-id failed (may already have key), continuing..."
    fi
    echo "  ✓ SSH key copied to remote host"
    
    local sudo_prefix="sudo"
    [[ -n "${pass:-}" ]] && sudo_prefix="echo '${pass}' | sudo -S"
    ssh -o StrictHostKeyChecking=no "${user}@${host}" "${sudo_prefix} cat /etc/ssh/sshd_config | grep -q '^AllowTcpForwarding yes' || (${sudo_prefix} sed -i 's/^#*\s*AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config && ${sudo_prefix} systemctl restart sshd)" &>/dev/null
    echo "  ✓ TCP forwarding enabled on remote host"
    echo -e "${GREEN}✅ SSH host key fixed for ${host:-}${NC}"
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

    if [[ "${AUTO_CONFIRM:-0}" -eq 1 ]]; then
        echo "  Auto-killing blocking process (PID ${blocking_pid})..."
        kill "${blocking_pid}" 2>/dev/null || true
    else
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
    fi

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

# Test cluster connectivity and re-establish if needed
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
        
        # Check if we can auto-reconnect
        if [[ "${USE_LOCAL_CONTEXT:-0}" -eq 1 ]] || [[ -z "${JUMP_USER:-}" ]] || [[ -z "${JUMP_IP:-}" ]]; then
            # On local clusters, check if port 6443 is blocked by another process
            if check_apiserver_port_conflict; then
                continue  # Port was freed, retry connectivity
            fi
            echo -e "${RED}❌ ERROR: Cannot connect using current kube context${NC}"
            echo "Check your context with: kubectl config get-contexts"
            exit 1
        fi

        echo ""
        echo -e "${YELLOW}Auto-reconnecting... (attempt $((retry + 1))/${max_retries})${NC}"
        
        # Find create_kubeconfig.sh
        local script_dir
        script_dir=$(dirname "${BASH_SOURCE[0]}") || true
        local create_kubeconfig="${script_dir}/../common/create_kubeconfig.sh"
        
        if [[ ! -f "${create_kubeconfig}" ]]; then
            create_kubeconfig="${HOME}/Git/useful-stuff/common/create_kubeconfig.sh"
        fi
        
        if [[ ! -f "${create_kubeconfig}" ]]; then
            echo -e "${RED}ERROR: create_kubeconfig.sh not found${NC}"
            exit 1
        fi
        
        OUTPUT=$("${create_kubeconfig}" "${JUMP_USER:-}" "${JUMP_IP:-}" "${CLUSTER_NAME:-}" 2>&1)
        RESULT=$?
        
        if [[ ${RESULT:-0} -ne 0 ]]; then
            if echo "${OUTPUT:-}" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
                echo -e "${YELLOW}⚠️  Detected SSH host key mismatch - VM was likely recreated${NC}"
                fix_ssh_host_key "${JUMP_USER:-}" "${JUMP_IP:-}"
                echo ""
                echo "🔄 Retrying after SSH key fix..."
                "${create_kubeconfig}" "${JUMP_USER:-}" "${JUMP_IP:-}" "${CLUSTER_NAME:-}" 2>/dev/null || true
            fi
        fi
        
        # Brief wait before retry
        sleep 2
        ((retry++))
    done
    
    # All retries exhausted
    echo -e "${RED}ERROR: Failed to connect after ${max_retries} attempts${NC}"
    exit 1
}

# Check if all chart dependencies are present
check_dependencies_present() {
    local chart_yaml="${CHART_PATH}/Chart.yaml"
    local charts_dir="${CHART_PATH}/charts"
    
    if [[ ! -f "${chart_yaml}" ]]; then
        return 1  # No Chart.yaml, need to check
    fi
    
    # Get list of dependencies from Chart.yaml
    local deps
    deps=$(yq eval '.dependencies[].name' "${chart_yaml}" 2>/dev/null || true)
    
    if [[ -z "${deps}" ]]; then
        return 0  # No dependencies defined
    fi
    
    # Check each dependency has a .tgz file
    while IFS= read -r dep_name; do
        [[ -z "${dep_name}" ]] && continue
        local found_files found
        found_files=$(find "${charts_dir}" -maxdepth 1 -name "${dep_name}-*.tgz" 2>/dev/null || true)
        found=$(echo "${found_files}" | head -1)
        if [[ -z "${found}" ]]; then
            return 1  # Missing dependency
        fi
    done <<< "${deps}"
    
    return 0  # All present
}

# Ensure Helm chart dependencies are up to date
ensure_chart_dependencies() {
    if [[ "${SKIP_DEPS:-0}" -eq 1 ]]; then
        echo -e "${GREEN}✓${NC} Skipping helm dependency check (--skip-deps)"
        return
    fi
    
    # Auto-detect if dependencies are already present
    # shellcheck disable=SC2310  # Intentional: predicate function, we want its return value
    if check_dependencies_present; then
        echo -e "${GREEN}✓${NC} Chart dependencies already present"
        return
    fi
    
    echo "Downloading Helm chart dependencies..."
    if ! helm dependency build "${CHART_PATH:-}" --skip-refresh 2>/dev/null; then
        echo "Running helm dependency update..."
        if ! helm dependency update "${CHART_PATH:-}"; then
            echo -e "${RED}❌ ERROR: Failed to update Helm dependencies${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓${NC} Chart dependencies downloaded"
}

# Check if controller is already installed
is_controller_installed() {
    local helm_output
    helm_output=$(helm list -n controller 2>/dev/null) || true
    echo "${helm_output:-}" | grep -q "mlrun-ce-controller"
}

# Install controller (for multi-namespace mode)
install_controller() {
    print_header "Installing MLRun CE Controller"
    
    # shellcheck disable=SC2310  # Function used as predicate in if condition (intended behavior)
    if is_controller_installed; then
        echo -e "${YELLOW}⚠️  Controller already installed in 'controller' namespace${NC}"
        echo "Skipping controller installation..."
        return 0
    fi
    
    echo "Installing controller using: admin_installation_values.yaml"
    echo "Namespace: controller"
    echo ""
    
    local controller_helm_args=(-n controller --create-namespace)
    [[ "${INSECURE_TLS:-0}" -eq 1 ]] && controller_helm_args+=(--insecure-skip-tls-verify)
    controller_helm_args+=("${CHART_PATH:-}" -f "${CHART_PATH:-}/admin_installation_values.yaml")
    
    if ! helm upgrade --install mlrun-ce-controller "${controller_helm_args[@]}" 2> >(grep -v 'cannot merge map onto non-map\|SessionAffinity is ignored' >&2); then
        echo -e "${RED}❌ ERROR: Controller installation failed!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✅ Controller installed successfully${NC}"
    
    # Wait for Strimzi operator to be ready
    echo "Waiting for Strimzi operator to be ready..."
    kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n controller --timeout=120s 2>/dev/null || true
}

# Force delete a PVC by removing finalizers first
force_delete_pvc() {
    local namespace="$1"
    local pvc_name="$2"
    
    # Remove finalizers using JSON patch (prevents stuck in Terminating)
    kubectl patch pvc "${pvc_name}" -n "${namespace}" --type='json' -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    # Delete with --wait=false to avoid blocking
    kubectl delete pvc "${pvc_name}" -n "${namespace}" --force --grace-period=0 --wait=false 2>/dev/null || true
}

# Pre-install cleanup for fresh install
pre_install_cleanup() {
    local namespace="$1"
    
    echo -e "${YELLOW}Cleaning up stateful PVCs for fresh install...${NC}"
    
    # Delete Kafka PVC if exists
    if kubectl get pvc "data-kafka-stream-kafka-stream-pool-0" -n "${namespace}" &>/dev/null; then
        echo "  Deleting Kafka PVC..."
        force_delete_pvc "${namespace}" "data-kafka-stream-kafka-stream-pool-0"
    fi
    
    # Delete MySQL PVC if exists
    local mysql_pvcs
    mysql_pvcs=$(kubectl get pvc -n "${namespace}" -l app=mysql -o name 2>/dev/null || true)
    if [[ -n "${mysql_pvcs}" ]]; then
        echo "  Deleting MySQL PVCs..."
        while IFS= read -r pvc; do
            [[ -z "${pvc}" ]] && continue
            local pvc_name="${pvc#persistentvolumeclaim/}"
            force_delete_pvc "${namespace}" "${pvc_name}"
        done <<< "${mysql_pvcs}"
    fi
    
    # Delete SeaweedFS PVCs if exist
    local seaweed_pvcs
    seaweed_pvcs=$(kubectl get pvc -n "${namespace}" -o name 2>/dev/null | grep seaweedfs || true)
    if [[ -n "${seaweed_pvcs}" ]]; then
        echo "  Deleting SeaweedFS PVCs..."
        while IFS= read -r pvc; do
            [[ -z "${pvc}" ]] && continue
            local pvc_name="${pvc#persistentvolumeclaim/}"
            force_delete_pvc "${namespace}" "${pvc_name}"
        done <<< "${seaweed_pvcs}"
    fi
    
    # Brief wait for cleanup
    sleep 2
    
    echo -e "${GREEN}✓${NC} Pre-install cleanup complete"
}

# Clean up stale Kafka PVC if cluster.id mismatch is detected
cleanup_kafka_pvc_if_needed() {
    local namespace="$1"
    local kafka_pod="kafka-stream-kafka-stream-pool-0"
    local kafka_pvc="data-kafka-stream-kafka-stream-pool-0"
    
    # Check if Kafka pod exists and is in CrashLoopBackOff
    local pod_status
    pod_status=$(kubectl get pod "${kafka_pod}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [[ -z "${pod_status}" ]]; then
        return 0  # Pod doesn't exist yet, nothing to clean
    fi
    
    # Check for CrashLoopBackOff or Error
    local container_status
    container_status=$(kubectl get pod "${kafka_pod}" -n "${namespace}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    
    if [[ "${container_status}" == "CrashLoopBackOff" ]] || [[ "${pod_status}" == "Failed" ]]; then
        # Check logs for cluster.id mismatch
        local logs
        logs=$(kubectl logs "${kafka_pod}" -n "${namespace}" --tail=50 2>/dev/null || echo "")
        
        if echo "${logs}" | grep -q "Invalid cluster.id"; then
            echo -e "${YELLOW}⚠️  Detected Kafka cluster.id mismatch - cleaning up stale PVC...${NC}"
            
            # Force delete the PVC (removes finalizers first)
            force_delete_pvc "${namespace}" "${kafka_pvc}"
            
            # Brief wait for cleanup
            sleep 3
            
            # Delete the pod to trigger recreation
            kubectl delete pod "${kafka_pod}" -n "${namespace}" --force --grace-period=0 2>/dev/null || true
            
            # Recreate PVC with correct labels for Strimzi
            echo "  Recreating Kafka PVC..."
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${kafka_pvc}
  namespace: ${namespace}
  labels:
    strimzi.io/cluster: kafka-stream
    strimzi.io/kind: Kafka
    strimzi.io/name: kafka-stream-kafka-stream-pool
    strimzi.io/pool-name: kafka-stream-pool
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${KAFKA_PVC_SIZE}
  storageClassName: ${STORAGE_CLASS}
EOF
            echo -e "${GREEN}✓${NC} Kafka PVC cleaned up and recreated"
        fi
    fi
}

# Detect NodePort conflicts and generate an override values file with free ports.
# Sets NODEPORT_OVERRIDE_FILE to the generated file path, or empty if no conflicts.
NODEPORT_OVERRIDE_FILE=""
generate_nodeport_overrides() {
    NODEPORT_OVERRIDE_FILE=""
    local namespace="$1"
    local override_file="${SCRIPT_DIR}/custom-ports-${namespace}.yaml"

    # Reuse existing override file from a previous run
    if [[ -f "${override_file}" ]]; then
        echo -e "${GREEN}✓${NC} Reusing NodePort overrides: $(basename "${override_file}")"
        NODEPORT_OVERRIDE_FILE="${override_file}"
        return 0
    fi

    local values_file="${CHART_PATH}/values.yaml"

    # Extract chart's default NodePort paths and values ("path port" per line)
    local chart_nodeports
    chart_nodeports=$(yq eval \
        '[.. | select(has("nodePort")) | {"path": (path | join(".")), "port": .nodePort}]
         | .[] | .path + " " + (.port | tostring)' \
        "${values_file}" 2>/dev/null)

    if [[ -z "${chart_nodeports:-}" ]]; then
        return 0
    fi

    # Get every NodePort currently allocated on the cluster
    local allocated
    allocated=$(kubectl get svc --all-namespaces \
        -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' 2>/dev/null \
        | grep -v '^$' | sort -nu || true)

    if [[ -z "${allocated:-}" ]]; then
        return 0
    fi

    # Find which chart defaults conflict with allocated ports
    local -a override_entries=()
    local has_conflict=0

    while IFS=' ' read -r yq_path default_port; do
        [[ -z "${yq_path:-}" ]] && continue
        if echo "${allocated}" | grep -qx "${default_port}"; then
            has_conflict=1
            local candidate=$((default_port + 1))
            while [[ "${candidate}" -le 32767 ]] && echo "${allocated}" | grep -qx "${candidate}"; do
                ((candidate++))
            done
            if [[ "${candidate}" -gt 32767 ]]; then
                echo -e "${RED}ERROR: No free NodePort available for ${yq_path}${NC}"
                return 1
            fi
            override_entries+=("${yq_path} ${default_port} ${candidate}")
            # Reserve the new port so subsequent iterations won't pick the same one
            allocated="${allocated}"$'\n'"${candidate}"
        fi
    done <<< "${chart_nodeports}"

    if [[ "${has_conflict}" -eq 0 ]]; then
        return 0
    fi

    echo ""
    echo "Detected NodePort conflicts — generating overrides for '${namespace}'..."

    # Build YAML override file using yq
    echo '{}' > "${override_file}.tmp"

    for entry in "${override_entries[@]}"; do
        local yq_path old_port new_port
        read -r yq_path old_port new_port <<< "${entry}"

        yq eval -i ".${yq_path}.nodePort = ${new_port}" "${override_file}.tmp"

        # global.nuclio.dashboard must also be mirrored to nuclio.dashboard
        if [[ "${yq_path}" == "global.nuclio.dashboard" ]]; then
            yq eval -i ".nuclio.dashboard.nodePort = ${new_port}" "${override_file}.tmp"
        fi

        printf "  %-45s %s → %s\n" "${yq_path}.nodePort:" "${old_port}" "${new_port}"
    done

    # Add header comment
    {
        echo "# Auto-generated NodePort overrides for namespace: ${namespace}"
        echo "# Generated on $(date +%Y-%m-%d) by install.sh"
        echo "# To customize further, edit this file before re-running the script"
        cat "${override_file}.tmp"
    } > "${override_file}"
    rm -f "${override_file}.tmp"

    echo -e "${GREEN}✓${NC} Saved to: $(basename "${override_file}")"
    NODEPORT_OVERRIDE_FILE="${override_file}"
}

# Install MLRun CE to a namespace
install_namespace() {
    local release_name="$1"
    local namespace="$1"  # Release name = namespace
    local helm_extra_args=()
    
    print_header "Installing MLRun CE: ${release_name:-}"
    
    echo "Release name: ${release_name:-}"
    echo "Namespace: ${namespace:-}"
    echo "Values: values.yaml (original)"
    
    if [[ "${NO_INGRESS:-0}" -eq 1 ]]; then
        echo -e "${YELLOW}Ingress disabled (--no-ingress) - using NodePort/ClusterIP access${NC}"
    else
        echo "Discovering and enabling all available ingresses..."
        
        local ingress_list
        ingress_list=$(discover_ingresses)
        
        # Build ingress args dynamically by scanning values.yaml
        while IFS='|' read -r ingress_path host_prefix host_format needs_paths; do
            [[ -z "${ingress_path:-}" ]] && continue
            local hostname="${host_prefix}.${namespace}.${CLUSTER_NAME}.${DOMAIN}"
            
            # Enable ingress
            helm_extra_args+=(--set "${ingress_path}.enabled=true")
            
            # Set hostname based on format
            helm_extra_args+=("--set-string=${ingress_path}.${host_format}=${hostname}")
            
            # Set paths if needed
            if [[ "${needs_paths:-}" == "true" ]]; then
                helm_extra_args+=("--set-string=${ingress_path}.hosts[0].paths[0].path=/")
                helm_extra_args+=("--set-string=${ingress_path}.hosts[0].paths[0].pathType=Prefix")
            fi
            
            # Set ingress class
            helm_extra_args+=(--set "${ingress_path}.ingressClassName=${INGRESS_CLASS}")
            
            echo "  ✓ ${ingress_path} -> ${hostname}"
        done <<< "${ingress_list:-}"
        
        # Kafka external listener - set advertised host per broker for external clients
        local kafka_hostname="kafka.${namespace}.${CLUSTER_NAME}.${DOMAIN}"
        helm_extra_args+=(--set "kafka.listeners[2].configuration.brokers[0].broker=0")
        helm_extra_args+=(--set "kafka.listeners[2].configuration.brokers[0].advertisedHost=${kafka_hostname}")
        echo "  ✓ kafka external listener -> ${kafka_hostname}:9094"
        
        # Jupyter: allow larger file uploads
        helm_extra_args+=("--set-string=jupyterNotebook.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/proxy-body-size=100m")
    fi
    
    echo ""
    
    local helm_args=(-n "${namespace:-}" --create-namespace)
    [[ "${INSECURE_TLS:-0}" -eq 1 ]] && helm_args+=(--insecure-skip-tls-verify)
    helm_args+=("${CHART_PATH:-}" -f "${CHART_PATH:-}/values.yaml")

    if [[ "${MULTI_MODE:-0}" -eq 1 ]]; then
        helm_args+=(-f "${NON_ADMIN_VALUES:-}")
        helm_extra_args+=(--set "spark-operator.spark.jobNamespaces[0]=${namespace}")
    fi
    
    # Append extra values files from --values flags
    if [[ ${#EXTRA_VALUES_FILES[@]} -gt 0 ]]; then
        for extra_values in "${EXTRA_VALUES_FILES[@]}"; do
            helm_args+=(-f "${extra_values}")
        done
    fi

    # Auto-detect NodePort conflicts and generate overrides (skip for ClusterIP deployments)
    if [[ "${CLUSTER_IP:-0}" -eq 0 ]]; then
        generate_nodeport_overrides "${namespace}"
        if [[ -n "${NODEPORT_OVERRIDE_FILE}" ]]; then
            helm_args+=(-f "${NODEPORT_OVERRIDE_FILE}")
        fi
    fi

    # Pre-create namespace to avoid race conditions after uninstall
    if ! kubectl get namespace "${namespace:-}" &>/dev/null; then
        kubectl create namespace "${namespace:-}" 2>/dev/null || true
    fi

    # Always clean up stale PVCs before install (dev/test environment)
    pre_install_cleanup "${namespace:-}"

    if ! helm upgrade --install "${release_name:-}" \
    "${helm_args[@]}" \
    "${helm_extra_args[@]}" 2> >(grep -v 'cannot merge map onto non-map\|SessionAffinity is ignored' >&2); then
        echo -e "${RED}❌ ERROR: Helm installation failed!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✅ Helm release '${release_name:-}' installed successfully${NC}"
    
    # Add /etc/hosts entries only when using ingresses
    if [[ "${NO_INGRESS:-0}" -eq 0 ]]; then
        add_hosts_for_namespace "${namespace:-}"
    fi
    
    # Post-install: check for Kafka PVC issues (common on reruns)
    echo "Checking for stateful component issues..."
    sleep 10  # Give pods time to start
    cleanup_kafka_pvc_if_needed "${namespace:-}"
}

# Verify Jupyter is accessible
verify_jupyter() {
    local namespace="$1"
    
    echo ""
    echo "Waiting for Jupyter pod to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=jupyter-notebook -n "${namespace:-}" --timeout=300s 2>/dev/null || echo "Warning: Jupyter pod not ready yet"
    
    echo "Testing Jupyter availability..."
    JUPYTER_URL=""
    
    # Use NodePort directly when --no-ingress mode
    if [[ "${NO_INGRESS:-0}" -eq 1 ]]; then
        local node_ip="${HOSTS_IP:-localhost}"
        JUPYTER_URL="http://${node_ip}:30040"
    else
        local ingress_host
        ingress_host=$(kubectl get ing -n "${namespace:-}" -l app.kubernetes.io/component=jupyter-notebook -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
        local ingress_tls
        ingress_tls=$(kubectl get ing -n "${namespace:-}" -l app.kubernetes.io/component=jupyter-notebook -o jsonpath='{.items[0].spec.tls[0].hosts[0]}' 2>/dev/null || true)
        if [[ -n "${ingress_host:-}" ]]; then
            if ! grep -q " ${ingress_host}" /etc/hosts 2>/dev/null; then
                echo "Ingress host '${ingress_host}' is not in /etc/hosts. Adding entries..."
                add_hosts_for_namespace "${namespace:-}"
            fi
            if [[ -n "${ingress_tls:-}" ]]; then
                JUPYTER_URL="https://${ingress_host}"
            else
                JUPYTER_URL="http://${ingress_host}"
            fi
        else
            # Fallback to NodePort when ingress is not present
            local node_port
            node_port=$(kubectl get svc -n "${namespace:-}" -l app.kubernetes.io/component=jupyter-notebook -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || true)
            if [[ -n "${node_port:-}" ]]; then
                local node_ip
                local nodes_output
                nodes_output=$(kubectl get nodes -o name 2>/dev/null) || true
                if echo "${nodes_output:-}" | grep -q docker-desktop; then
                    node_ip="127.0.0.1"
                else
                    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null) || true
                    if [[ -z "${node_ip:-}" ]]; then
                        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true
                    fi
                fi
                if [[ -n "${node_ip:-}" ]]; then
                    JUPYTER_URL="http://${node_ip}:${node_port}"
                fi
            fi
        fi
    fi

    if [[ -z "${JUPYTER_URL:-}" ]]; then
        echo "⚠️  Could not determine Jupyter URL (no ingress and no nodePort found)."
        return
    fi
    echo "Jupyter URL: ${JUPYTER_URL:-}"
    MAX_ATTEMPTS=20
    ATTEMPT=0
    
    while [[ "${ATTEMPT:-}" -lt "${MAX_ATTEMPTS:-}" ]]; do
        ATTEMPT=$((ATTEMPT + 1))
        HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "${JUPYTER_URL:-}" 2>/dev/null || echo "000")
        # Normalize curl's 000000 to 000
        if [[ "${HTTP_CODE:-}" = "000000" ]]; then
            HTTP_CODE="000"
        fi
        
        if [[ "${HTTP_CODE:-}" = "200" ]] || [[ "${HTTP_CODE:-}" = "302" ]]; then
            echo -e "${GREEN}✓${NC} Jupyter is responding!"
            break
        elif [[ "${HTTP_CODE:-}" = "502" ]] || [[ "${HTTP_CODE:-}" = "000" ]]; then
            if [[ "${HTTP_CODE:-}" = "000" ]]; then
                echo "  No response (HTTP 000). This usually means DNS/ingress not reachable yet."
            else
                echo "  Still initializing (HTTP ${HTTP_CODE:-}), waiting... (${ATTEMPT:-}/${MAX_ATTEMPTS:-})"
            fi
            sleep 15
        else
            echo "  Unexpected response (HTTP ${HTTP_CODE:-}), waiting..."
            sleep 10
        fi
    done
}

# Print final summary
print_summary() {
    local namespace="$1"
    local mode="$2"
    local node_ip="${HOSTS_IP:-localhost}"
    
    echo ""
    print_header "Installation Complete!"
    echo ""
    echo "Mode: ${mode:-}"
    echo "Namespace: ${namespace:-}"
    echo ""
    
    echo "Internal Services:"
    echo "  Kafka Bootstrap: kafka-stream.${namespace}.svc.cluster.local:9092"
    echo "  Pipelines:       http://pipelines.${namespace}.svc.cluster.local:8888"
    echo "  SeaweedFS S3:    http://seaweedfs-s3.${namespace}.svc.cluster.local:8333"
    echo "  SeaweedFS Admin: http://seaweedfs-admin-ui.${namespace}.svc.cluster.local:23646"
    echo "  TimescaleDB:     timescaledb.${namespace}.svc.cluster.local:5432"
    echo ""
    
    if [[ "${NO_INGRESS:-0}" -eq 0 ]]; then
        echo "External Services:"
        echo "  Kafka External:  kafka.${namespace}.${CLUSTER_NAME}.${DOMAIN}:9094"
        echo ""
    fi
}

# ============================================================================
# Interactive Wizard
# ============================================================================

# Prompt with a default value. Usage: result=$(prompt_with_default "Question" "default")
prompt_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local input
    if [[ -n "${default_val:-}" ]]; then
        read -r -p "${prompt_text} [${default_val}]: " input
        echo "${input:-${default_val}}"
    else
        read -r -p "${prompt_text}: " input
        echo "${input:-}"
    fi
}

# Prompt for yes/no. Returns 0 for yes, 1 for no. Usage: if prompt_yes_no "Question?" "Y"; then ...
prompt_yes_no() {
    local prompt_text="$1"
    local default="${2:-Y}"
    local input
    if [[ "${default}" == "Y" ]]; then
        read -r -p "${prompt_text} (Y/n) [Y]: " input
        [[ ! "${input:-}" =~ ^[Nn]$ ]]
    else
        read -r -p "${prompt_text} (y/N) [N]: " input
        [[ "${input:-}" =~ ^[Yy]$ ]]
    fi
}

# Prompt to select from numbered options. Returns the selected index (0-based).
# Usage: idx=$(prompt_select "Choose:" "option1" "option2" "option3")
prompt_select() {
    local prompt_text="$1"
    shift
    local options=("$@")
    
    echo "" >&2
    echo -e "${BLUE}${prompt_text}${NC}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    local i
    for i in "${!options[@]}"; do
        echo "  $((i + 1)). ${options[$i]}" >&2
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    
    local selection
    while true; do
        read -r -p "Select (1-${#options[@]}): " selection
        if [[ "${selection:-}" =~ ^[0-9]+$ ]] && [[ "${selection}" -ge 1 ]] && [[ "${selection}" -le ${#options[@]} ]]; then
            echo $((selection - 1))
            return
        fi
        echo -e "${RED}Invalid selection, try again${NC}" >&2
    done
}

interactive_wizard() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}  MLRun CE Interactive Installation Wizard${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local is_local=0

    # --- Step 1: Cluster Connection ---
    echo ""
    echo -e "${BLUE}Step 1: Cluster Connection${NC}"
    local conn_idx
    conn_idx=$(prompt_select "How to connect to the cluster?" \
        "Local context  - Use a local kubeconfig (docker-desktop, minikube, etc.)" \
        "Remote SSH     - Connect via SSH to a remote VM")

    if [[ "${conn_idx}" -eq 0 ]]; then
        USE_LOCAL_CONTEXT=1
        FORCE_MODE="local"
        is_local_cluster && is_local=1
        if [[ "${is_local}" -eq 1 ]]; then
            local ctx
            ctx=$(kubectl config current-context 2>/dev/null) || true
            KUBECONFIG_PATH="${HOME}/.kube/config"
            KUBE_CONTEXT="${ctx}"
            CLUSTER_NAME=$(sanitize_cluster_name "${ctx}")
            export KUBECONFIG="${KUBECONFIG_PATH}"
            echo -e "${GREEN}✓${NC} Detected local cluster: ${ctx}"
            echo -e "${GREEN}✓${NC} Using kubeconfig: ~/.kube/config, context: ${ctx}"
        else
            echo -e "${GREEN}✓${NC} Local context selected (you'll pick the kubeconfig/context next)"
        fi
    else
        USE_LOCAL_CONTEXT=0
        FORCE_MODE="remote"
        local remote_input
        remote_input=$(prompt_with_default "Remote user@ip (e.g. iguazio@192.168.224.180)" "")
        while [[ -z "${remote_input:-}" ]] || [[ "${remote_input}" != *"@"* ]]; do
            echo -e "${RED}Please use user@ip format${NC}"
            remote_input=$(prompt_with_default "Remote user@ip" "")
        done
        JUMP_USER="${remote_input%%@*}"
        JUMP_IP="${remote_input##*@}"
        HOSTS_IP="${JUMP_IP}"
        export JUMP_USER JUMP_IP
        echo -e "${GREEN}✓${NC} Remote: ${JUMP_USER}@${JUMP_IP}"

        if [[ -z "${CLUSTER_NAME:-}" ]]; then
            CLUSTER_NAME=$(prompt_with_default "Cluster name (e.g. vmdev235ig4)" "")
            if [[ -z "${CLUSTER_NAME:-}" ]]; then
                echo -e "${RED}ERROR: Cluster name is required for remote connections${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}✓${NC} Cluster name: ${CLUSTER_NAME} (from .env)"
        fi

        if [[ -n "${SUDO_PASS:-}" ]]; then
            echo -e "${GREEN}✓${NC} SSH/sudo password: loaded from .env"
        else
            local auth_idx
            auth_idx=$(prompt_select "SSH authentication method?" \
                "SSH key    - Passwordless SSH (key already configured)" \
                "Password   - Enter SSH/sudo password")
            if [[ "${auth_idx}" -eq 1 ]]; then
                read -r -s -p "Enter SSH/sudo password: " SUDO_PASS
                echo ""
                echo -e "${GREEN}✓${NC} Password set"
                if prompt_yes_no "Save password to .env for future runs?" "N"; then
                    local env_file="${SCRIPT_DIR}/.env"
                    if grep -q '^SUDO_PASS=' "${env_file}" 2>/dev/null; then
                        sed -i.bak "s|^SUDO_PASS=.*|SUDO_PASS=\"${SUDO_PASS}\"|" "${env_file}" && rm -f "${env_file}.bak"
                    else
                        echo "SUDO_PASS=\"${SUDO_PASS}\"" >> "${env_file}"
                    fi
                    echo -e "${GREEN}✓${NC} Saved to .env"
                fi
            else
                SUDO_PASS=""
                echo -e "${GREEN}✓${NC} Using SSH key (no password)"
            fi
        fi
    fi

    # --- Step 2: Access Mode ---
    echo ""
    echo -e "${BLUE}Step 2: Access Mode${NC}"
    if [[ "${is_local}" -eq 1 ]]; then
        local access_idx
        access_idx=$(prompt_select "How should services be accessed?" \
            "NodePort   - Direct IP:port access (recommended for local clusters)" \
            "Ingress    - Use ingress controller with DNS hostnames")
        if [[ "${access_idx}" -eq 0 ]]; then
            NO_INGRESS=1
            echo -e "${GREEN}✓${NC} NodePort mode (no ingress)"
        else
            NO_INGRESS=0
            echo -e "${GREEN}✓${NC} Will set up ingresses"
        fi
    else
        local access_idx
        access_idx=$(prompt_select "How should services be accessed?" \
            "Ingress    - Use ingress controller with DNS hostnames (recommended)" \
            "NodePort   - Direct IP:port access (no DNS required)")
        if [[ "${access_idx}" -eq 0 ]]; then
            NO_INGRESS=0
            echo -e "${GREEN}✓${NC} Will set up ingresses"
        else
            NO_INGRESS=1
            echo -e "${GREEN}✓${NC} NodePort mode (no ingress)"
        fi
    fi

    # --- Step 3: Installation Mode ---
    echo ""
    echo -e "${BLUE}Step 3: Installation Mode${NC}"
    local mode_idx
    mode_idx=$(prompt_select "Select installation mode:" \
        "single   - Install to a single namespace (no controller)" \
        "multi    - Multi-namespace mode (installs controller + namespace)" \
        "controller - Install controller only (for multi-namespace setup)")

    case "${mode_idx}" in
        0) MODE="single" ;;
        1) MODE="multi" ;;
        2) MODE="controller" ;;
    esac
    echo -e "${GREEN}✓${NC} Mode: ${MODE}"

    if [[ "${MODE}" == "multi" ]] || [[ "${MODE}" == "controller" ]]; then
        local svc_idx
        svc_idx=$(prompt_select "Service type for non-admin namespace?" \
            "NodePort   - Services exposed via NodePort (direct IP:port access)" \
            "ClusterIP  - Services only reachable inside the cluster (use with ingress)")
        if [[ "${svc_idx}" -eq 1 ]]; then
            CLUSTER_IP=1
            echo -e "${GREEN}✓${NC} Service type: ClusterIP"
        else
            CLUSTER_IP=0
            echo -e "${GREEN}✓${NC} Service type: NodePort"
        fi
    fi

    # --- Step 4: Namespace / Release name ---
    if [[ "${MODE}" != "controller" ]]; then
        echo ""
        echo -e "${BLUE}Step 4: Namespace${NC}"
        echo "The namespace also serves as the Helm release name."
        NAMESPACE=$(prompt_with_default "Namespace" "mlrun")
        if [[ -z "${NAMESPACE:-}" ]]; then
            echo -e "${RED}ERROR: Namespace is required${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓${NC} Namespace: ${NAMESPACE}"
    fi

    echo ""
    echo -e "${GREEN}✓${NC} Chart path: ${CHART_PATH}"

    # --- Step 5: Configuration ---
    echo ""
    echo -e "${BLUE}Step 5: Configuration${NC}"

    # Auto-adjust for local clusters
    if [[ "${is_local}" -eq 1 ]]; then
        if [[ -n "${DOMAIN:-}" ]] && [[ "${DOMAIN}" != "local" ]]; then
            echo ""
            echo -e "${YELLOW}Domain '${DOMAIN}' loaded from .env${NC}"
            if ! prompt_yes_no "Use '${DOMAIN}' for local cluster?" "N"; then
                DOMAIN="local"
                echo -e "${GREEN}✓${NC} Domain: ${DOMAIN}"
            fi
        fi
        echo ""
        echo -e "${BLUE}Select storage class:${NC}"
        local auto_sc
        auto_sc=$(select_storage_class)
        if [[ -n "${auto_sc}" ]]; then
            STORAGE_CLASS="${auto_sc}"
            echo -e "${GREEN}✓${NC} Storage class: ${STORAGE_CLASS}"
        fi
        if [[ "${NO_INGRESS}" -eq 1 ]]; then
            INGRESS_NGINX_VERSION=""
            echo -e "${GREEN}✓${NC} Skipping nginx-ingress install (NodePort mode)"
        elif kubectl get deployment -n ingress-nginx ingress-nginx-controller &>/dev/null; then
            INGRESS_NGINX_VERSION=""
            echo -e "${GREEN}✓${NC} nginx-ingress already installed"
        else
            echo -e "${GREEN}✓${NC} Will install nginx-ingress for local ingress support"
        fi
        echo ""
    fi

    if [[ "${NO_INGRESS}" -eq 1 ]]; then
        echo "Current settings:"
        echo "  Storage class:   ${STORAGE_CLASS}"
        echo "  Kafka PVC size:  ${KAFKA_PVC_SIZE}"
        echo "  TLS verify:      $(if [[ "${INSECURE_TLS}" -eq 1 ]]; then echo "skip (insecure)"; else echo "strict"; fi)"
        echo ""

        if prompt_yes_no "Customize these settings?" "N"; then
            if [[ "${is_local}" -eq 0 ]]; then
                STORAGE_CLASS=$(select_storage_class)
                echo -e "${GREEN}✓${NC} Storage class: ${STORAGE_CLASS}"
            fi
            KAFKA_PVC_SIZE=$(prompt_with_default "  Kafka PVC size" "${KAFKA_PVC_SIZE}")
            if prompt_yes_no "  Skip TLS verification (helm --insecure-skip-tls-verify)?" "Y"; then
                INSECURE_TLS=1
            else
                INSECURE_TLS=0
            fi
        fi
    else
        echo "Current settings:"
        echo "  Domain:          ${DOMAIN}"
        echo "  Ingress class:   ${INGRESS_CLASS}"
        echo "  Nginx version:   ${INGRESS_NGINX_VERSION:-<skip install>}"
        echo "  Storage class:   ${STORAGE_CLASS}"
        echo "  Kafka PVC size:  ${KAFKA_PVC_SIZE}"
        echo "  TLS verify:      $(if [[ "${INSECURE_TLS}" -eq 1 ]]; then echo "skip (insecure)"; else echo "strict"; fi)"
        echo ""

        if prompt_yes_no "Customize these settings?" "N"; then
            DOMAIN=$(prompt_with_default "  DNS domain" "${DOMAIN}")
            INGRESS_CLASS=$(prompt_with_default "  Ingress class" "${INGRESS_CLASS}")
            INGRESS_NGINX_VERSION=$(prompt_with_default "  nginx-ingress version (empty to skip)" "${INGRESS_NGINX_VERSION}")
            STORAGE_CLASS=$(select_storage_class)
            echo -e "${GREEN}✓${NC} Storage class: ${STORAGE_CLASS}"
            KAFKA_PVC_SIZE=$(prompt_with_default "  Kafka PVC size" "${KAFKA_PVC_SIZE}")
            if prompt_yes_no "  Skip TLS verification (helm --insecure-skip-tls-verify)?" "Y"; then
                INSECURE_TLS=1
            else
                INSECURE_TLS=0
            fi
        fi
    fi
    
    # --- Step 6: Extra values files ---
    echo ""
    echo -e "${BLUE}Step 6: Extra Values Files${NC}"
    if prompt_yes_no "Add extra Helm values files (--values)?" "N"; then
        while true; do
            local extra_file
            extra_file=$(prompt_with_default "  Values file path (empty to stop)" "")
            [[ -z "${extra_file:-}" ]] && break
            if [[ -f "${extra_file}" ]]; then
                EXTRA_VALUES_FILES+=("${extra_file}")
                echo -e "  ${GREEN}✓${NC} Added: ${extra_file}"
            else
                echo -e "  ${YELLOW}File not found: ${extra_file}${NC}"
            fi
        done
    fi
    
    # --- Review ---
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}  Installation Summary${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-20s %s\n" "Mode:" "${MODE}"
    [[ "${MODE}" != "controller" ]] && printf "  %-20s %s\n" "Namespace:" "${NAMESPACE}"
    printf "  %-20s %s\n" "Chart path:" "${CHART_PATH}"
    if [[ "${USE_LOCAL_CONTEXT:-0}" -eq 1 ]]; then
        printf "  %-20s %s\n" "Connection:" "Local kubeconfig"
    else
        printf "  %-20s %s\n" "Connection:" "Remote (${JUMP_USER}@${JUMP_IP})"
    fi
    printf "  %-20s %s\n" "Access:" "$(if [[ "${NO_INGRESS}" -eq 0 ]]; then echo "Ingress (${INGRESS_CLASS})"; else echo "NodePort"; fi)"
    if [[ "${MODE}" == "multi" ]] || [[ "${MODE}" == "controller" ]]; then
        printf "  %-20s %s\n" "Service type:" "$(if [[ "${CLUSTER_IP:-0}" -eq 1 ]]; then echo "ClusterIP"; else echo "NodePort"; fi)"
    fi
    printf "  %-20s %s\n" "Domain:" "${DOMAIN}"
    printf "  %-20s %s\n" "Storage class:" "${STORAGE_CLASS}"
    printf "  %-20s %s\n" "TLS verify:" "$(if [[ "${INSECURE_TLS}" -eq 1 ]]; then echo "skip"; else echo "strict"; fi)"
    if [[ ${#EXTRA_VALUES_FILES[@]} -gt 0 ]]; then
        printf "  %-20s %s\n" "Extra values:" "${EXTRA_VALUES_FILES[*]}"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Build the equivalent CLI command
    local cli_cmd
    cli_cmd="./$(basename "${BASH_SOURCE[0]}") ${MODE}"
    [[ "${MODE}" != "controller" ]] && cli_cmd+=" ${NAMESPACE}"
    
    if [[ "${USE_LOCAL_CONTEXT:-0}" -eq 0 ]] && [[ -n "${JUMP_USER:-}" ]]; then
        cli_cmd+=" --remote ${JUMP_USER}@${JUMP_IP}"
    fi
    [[ "${NO_INGRESS}" -eq 1 ]] && cli_cmd+=" --no-ingress"
    [[ "${CLUSTER_IP:-0}" -eq 1 ]] && cli_cmd+=" --cluster-ip"
    [[ "${SKIP_DEPS:-0}" -eq 1 ]] && cli_cmd+=" --skip-deps"
    if [[ ${#EXTRA_VALUES_FILES[@]} -gt 0 ]]; then
        for f in "${EXTRA_VALUES_FILES[@]}"; do
            cli_cmd+=" --values ${f}"
        done
    fi
    cli_cmd+=" -y"

    echo ""
    echo -e "${BLUE}To re-run without the wizard, use:${NC}"
    echo ""
    echo "  ${cli_cmd}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if ! prompt_yes_no "Proceed with installation?"; then
        echo "Installation cancelled."
        exit 0
    fi
    
    AUTO_CONFIRM=1
}

# Show usage
show_usage() {
    local script_name
    script_name="$(basename "$0")"
    echo ""
    echo "MLRun CE Helm Install Script"
    echo ""
    echo "Usage:"
    echo "  ${script_name:-}                                           (interactive wizard)"
    echo "  ${script_name:-} single <namespace> [options]"
    echo "  ${script_name:-} multi <namespace> [options]"
    echo "  ${script_name:-} controller [options]"
    echo ""
    echo "Modes:"
    echo "  No arguments:  Interactive wizard -- guides you through setup and installation"
    echo "  With arguments: CLI mode -- no prompts, fails fast if .env is missing"
    echo ""
    echo "Options (CLI mode):"
    echo "  -h, --help           Show this help message"
    echo "  --remote user@ip     Connect to remote VM via SSH (uses VM IP for /etc/hosts)"
    echo "  --values <path>      Extra Helm values file (can be specified multiple times)"
    echo "  --skip-deps          Skip helm dependency download (use existing charts/)"
    echo "  --no-ingress         Skip ingress setup, use NodePort access"
    echo "  --cluster-ip         Use ClusterIP services in multi mode (default: NodePort)"
    echo "  -y                   Auto-confirm (skip ingress confirmation prompt)"
    echo ""
    echo "Access Modes:"
    echo "  Default:       Uses ingresses with nginx-ingress controller (requires DNS)"
    echo "  --no-ingress:  Uses NodePort for external access (direct IP:port access)"
    echo "  --cluster-ip:  Forces ClusterIP services in multi mode (use with ingress)"
    echo ""
    echo "Ingress Discovery:"
    echo "  The script automatically scans values.yaml to discover all available ingresses"
    echo "  and enables them with appropriate hostnames. Requires 'yq' to be installed."
    echo ""
    echo "Default (no --remote): Local mode - prompts for kubeconfig/context selection"
    echo "                       (or uses last selection if available)"
    echo ""
    echo "Setup:"
    echo "  Configuration is loaded from a .env file (never committed to git)."
    echo "  Running with no arguments will create .env and prompt for values."
    echo "  Or create it manually:"
    echo "    cp .env.example .env"
    echo "    vi .env"
    echo ""
    echo "  Required in .env:"
    echo "    DOMAIN             DNS domain for ingress hostnames"
    echo "    INGRESS_CLASS      Ingress class (nginx, traefik, etc.)"
    echo ""
    echo "  Optional in .env (have sensible defaults):"
    echo "    INGRESS_NGINX_VERSION  nginx-ingress version (default: v1.11.3, empty=skip)"
    echo "    STORAGE_CLASS          K8s storage class (default: nfs-client)"
    echo "    KAFKA_PVC_SIZE         Kafka PVC size (default: 8Gi)"
    echo "    INSECURE_TLS           1=skip TLS verify, 0=strict (default: 1)"
    echo "    SUDO_PASS              Remote sudo password (default: empty=passwordless)"
    echo ""
    echo "Examples:"
    echo "  # Interactive wizard (recommended for first-time use)"
    echo "  ${script_name:-}"
    echo ""
    echo "  # Local install with ingresses (auto-discovers and enables all ingresses)"
    echo "  ${script_name:-} single mlrun"
    echo ""
    echo "  # Install with extra Helm values file"
    echo "  ${script_name:-} single mlrun --values overrides.yaml"
    echo ""
    echo "  # Remote VM with ingresses"
    echo "  ${script_name:-} single mlrun --remote iguazio@192.168.224.180"
    echo ""
    echo "  # Remote VM with NodePort only"
    echo "  ${script_name:-} single mlrun --remote iguazio@192.168.224.180 --no-ingress"
    echo ""
    echo "  # Multi-namespace with ClusterIP services (for ingress-based access)"
    echo "  ${script_name:-} multi mlrun --remote iguazio@192.168.224.180 --cluster-ip"
    echo ""
    exit 1
}

# ============================================================================
# Main
# ============================================================================

# Two modes: interactive (no args) or CLI (with args)
if [[ $# -eq 0 ]]; then
    init_env 1
    interactive_wizard
else
    MODE="${1:-}"
    NAMESPACE="${2:-}"

    if [[ "${MODE:-}" == "-h" ]] || [[ "${MODE:-}" == "--help" ]] || [[ "${MODE:-}" == "help" ]]; then
        show_usage
    fi

    # CLI mode: validate .env without prompts
    init_env 0
    shift 2 || true
fi
SKIP_DEPS="${SKIP_DEPS:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
        ;;
        -y)
            AUTO_CONFIRM=1
            shift 1
        ;;
        --values|-f)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
                echo -e "${RED}ERROR: --values requires a file path${NC}"
                exit 1
            fi
            EXTRA_VALUES_FILES+=("$2")
            shift 2
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
            HOSTS_IP="${JUMP_IP}"
            export JUMP_USER JUMP_IP
            shift 2
        ;;
        --skip-deps)
            SKIP_DEPS=1
            shift 1
        ;;
        --no-ingress)
            NO_INGRESS=1
            shift 1
        ;;
        --cluster-ip)
            CLUSTER_IP=1
            shift 1
        ;;
        *)
            shift 1
        ;;
    esac
done

if [[ -z "${MODE:-}" ]]; then
    show_usage
fi

if [[ -z "${CHART_PATH:-}" ]] || [[ ! -d "${CHART_PATH}" ]]; then
    echo -e "${RED}ERROR: Helm chart not found at: ${SCRIPT_DIR}/../charts/mlrun-ce${NC}"
    echo "Expected repo structure: <repo>/charts/mlrun-ce/"
    exit 1
fi

if [[ -z "${NON_ADMIN_VALUES:-}" ]]; then
    if [[ "${CLUSTER_IP:-0}" -eq 1 ]]; then
        NON_ADMIN_VALUES="${CHART_PATH:-}/non_admin_cluster_ip_installation_values.yaml"
    else
        NON_ADMIN_VALUES="${CHART_PATH:-}/non_admin_installation_values.yaml"
    fi
fi

# Verify yq is available for dynamic ingress discovery
if ! command -v yq &>/dev/null; then
    echo -e "${YELLOW}⚠️  WARNING: yq not found. Install with: brew install yq${NC}"
    echo "yq is required for automatic ingress discovery from values.yaml"
    exit 1
fi

# Select cluster / context
if [[ "${FORCE_MODE:-}" == "local" ]]; then
    if [[ -z "${KUBE_CONTEXT:-}" ]]; then
        select_kubeconfig_file
        select_kube_context
    fi
elif [[ "${FORCE_MODE:-}" == "remote" ]]; then
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        echo -e "${RED}ERROR: CLUSTER_NAME is required for remote connections${NC}"
        echo "Set it in .env or export CLUSTER_NAME=<name> before running"
        exit 1
    fi
else
    # CLI mode without --remote: use the current kubeconfig context
    USE_LOCAL_CONTEXT=1
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        CLUSTER_NAME=$(kubectl config current-context 2>/dev/null)
    fi
fi

CLUSTER_NAME=$(sanitize_cluster_name "${CLUSTER_NAME:-}")

# Set kubeconfig
if [[ "${USE_LOCAL_CONTEXT:-0}" -eq 1 ]]; then
    if [[ -z "${KUBECONFIG_PATH:-}" ]]; then
        KUBECONFIG_PATH="${HOME}/.kube/config"
    fi
else
    KUBECONFIG_PATH="${HOME}/.kube/config_${CLUSTER_NAME:-}"
fi

if [[ ! -f "${KUBECONFIG_PATH:-}" ]]; then
    echo -e "${YELLOW}Kubeconfig not found, will create during connectivity test${NC}"
fi
export KUBECONFIG="${KUBECONFIG_PATH:-}"
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl config use-context "${KUBE_CONTEXT:-}" &>/dev/null || true
fi

# Test connectivity
test_cluster_connectivity

# Detect cluster type and adjust configuration
apply_cluster_detection

# Install ingress-nginx only if not using --no-ingress
if [[ "${NO_INGRESS:-0}" -eq 0 ]]; then
    install_ingress_nginx
else
    echo -e "${YELLOW}Skipping ingress-nginx installation (--no-ingress mode)${NC}"
fi

# Ensure chart dependencies are built
ensure_chart_dependencies

case "${MODE:-}" in
    single)
        if [[ -z "${NAMESPACE:-}" ]]; then
            echo -e "${RED}ERROR: Namespace required for single mode${NC}"
            show_usage
        fi
        
        echo ""
        if [[ "${NO_INGRESS:-0}" -eq 1 ]]; then
            echo -e "${BLUE}Mode: Single Namespace (no controller, NodePort access)${NC}"
        else
            echo -e "${BLUE}Mode: Single Namespace (no controller)${NC}"
        fi
        echo ""
        
        # Only confirm ingresses when using ingress mode
        if [[ "${NO_INGRESS:-0}" -eq 0 ]]; then
            confirm_ingresses "${NAMESPACE:-}"
        fi
        install_namespace "${NAMESPACE:-}"
        verify_jupyter "${NAMESPACE:-}"
        print_summary "${NAMESPACE:-}" "Single Namespace"
    ;;
    
    multi)
        if [[ -z "${NAMESPACE:-}" ]]; then
            echo -e "${RED}ERROR: Namespace required for multi mode${NC}"
            show_usage
        fi
        
        echo ""
        if [[ "${NO_INGRESS:-0}" -eq 1 ]]; then
            echo -e "${BLUE}Mode: Multi-Namespace (with controller, NodePort access)${NC}"
        else
            echo -e "${BLUE}Mode: Multi-Namespace (with controller)${NC}"
        fi
        echo ""
        MULTI_MODE=1
        
        # Only confirm ingresses when using ingress mode
        if [[ "${NO_INGRESS:-0}" -eq 0 ]]; then
            confirm_ingresses "${NAMESPACE:-}"
        fi
        
        # Install controller first (idempotent - skips if exists)
        install_controller
        
        # Install the namespace
        install_namespace "${NAMESPACE:-}"
        verify_jupyter "${NAMESPACE:-}"
        print_summary "${NAMESPACE:-}" "Multi-Namespace"
    ;;
    
    controller)
        echo ""
        echo -e "${BLUE}Mode: Controller Only${NC}"
        echo ""
        
        install_controller
        
        echo ""
        print_header "Controller Installation Complete!"
        echo ""
        echo "Controller installed in 'controller' namespace"
        echo "You can now install namespaces with: $0 multi <namespace>"
        echo ""
    ;;
    
    *)
        echo -e "${RED}ERROR: Unknown mode '${MODE:-}'${NC}"
        show_usage
    ;;
esac

echo -e "${GREEN}Done!${NC}"
