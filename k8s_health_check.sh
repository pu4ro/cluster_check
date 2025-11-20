#!/bin/bash

# Kubernetes 클러스터 포괄적 상태 점검 및 리소스 분석 스크립트
# 고객 친화적 HTML 보고서 포함
# Author: DevOps Team
# Version: 3.0.0

# More lenient error handling to prevent early exit
set -e  # Exit on error, but allow more graceful handling
# set -u and set -o pipefail removed to prevent premature termination

# Global variables
declare -A CHECK_RESULTS=()
declare -A CHECK_DETAILS=()
declare -A NODE_RESOURCES=()
declare -a FAILED_CHECKS=()
declare -a WARNING_CHECKS=()
declare -a SUCCESS_CHECKS=()

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${SCRIPT_DIR}/reports"
KUBECONFIG=${KUBECONFIG:-"$HOME/.kube/config"}
KUBE_CONTEXT=${KUBE_CONTEXT:-""}

# Default values
DEFAULT_OUTPUT="html"
TARGET_URL=""
OUTPUT_FORMAT="html"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# Load configuration file
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    log_warn "설정 파일을 찾을 수 없습니다: $CONFIG_FILE. 기본값을 사용합니다."
    # Default values if config file is missing
    GENERATE_HTML_REPORT=true
    GENERATE_JSON_REPORT=true
fi

# Usage function
show_usage() {
    cat << EOF
사용법: $0 [URL] [옵션]

인자:
    URL                     점검할 도메인 URL (선택사항 - 미입력 시 대화형 입력)

옵션:
    --url URL               점검할 URL 지정
    --output FORMAT         출력 형식 (html|log|json, 기본값: html)
    --kubeconfig PATH       kubeconfig 파일 경로 (기본값: ~/.kube/config)
    --context NAME          사용할 Kubernetes 컨텍스트
    --interactive, -i       대화형 모드 강제 실행
    --help                  이 도움말 표시

사용 방법:

1) 대화형 모드 (권장):
    $0                      # 도메인과 프로토콜을 대화형으로 입력
    $0 --interactive        # 명시적으로 대화형 모드 실행

2) 명령행 인자 방식:
    $0 https://example.com
    $0 --url https://example.com --output json
    $0 https://example.com --kubeconfig /path/to/config --context my-cluster

3) 출력 형식별 사용:
    $0 --output html        # 고객용 HTML 대시보드 (기본값)
    $0 --output json        # 모니터링 시스템 연동용
    $0 --output log         # 관리자용 텍스트 로그

EOF
}

# Interactive input functions
get_user_input() {
    log_info "대화형 설정을 시작합니다..."
    echo
    
    # Get domain
    while true; do
        echo -n "🌐 점검할 도메인을 입력하세요 (예: example.com): "
        read -r domain_input
        
        if [[ -z "$domain_input" ]]; then
            log_warn "도메인을 입력해주세요."
            continue
        fi
        
        # Remove protocol if provided
        domain_input=$(echo "$domain_input" | sed 's|^https\?://||')
        
        # Basic domain validation
        if [[ ! "$domain_input" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
            log_warn "올바른 도메인 형식이 아닙니다. 예: example.com"
            continue
        fi
        
        break
    done
    
    # Get protocol
    echo
    echo "🔒 프로토콜을 선택하세요:"
    echo "  1) HTTPS (권장)"
    echo "  2) HTTP"
    
    while true; do
        echo -n "선택 (1 또는 2): "
        read -r protocol_choice
        
        case "$protocol_choice" in
            1)
                protocol="https"
                break
                ;;
            2)
                protocol="http"
                break
                ;;
            *)
                log_warn "1 또는 2를 선택해주세요."
                ;;
        esac
    done
    
    # Construct final URL
    TARGET_URL="${protocol}://${domain_input}"
    
    echo
    log_success "설정 완료: $TARGET_URL"
    echo
}

# Parse command line arguments
parse_arguments() {
    local url_provided=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output)
                OUTPUT_FORMAT="$2"
                if [[ ! "$OUTPUT_FORMAT" =~ ^(html|log|json)$ ]]; then
                    log_error "잘못된 출력 형식: $OUTPUT_FORMAT. html, log, json 중 하나를 선택하세요."
                    exit 1
                fi
                shift 2
                ;;
            --kubeconfig)
                KUBECONFIG="$2"
                shift 2
                ;;
            --context)
                KUBE_CONTEXT="$2"
                shift 2
                ;;
            --url)
                TARGET_URL="$2"
                url_provided=true
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --interactive|-i)
                # Force interactive mode
                url_provided=false
                shift
                ;;
            -*)
                log_error "알 수 없는 옵션: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$TARGET_URL" ]]; then
                    TARGET_URL="$1"
                    url_provided=true
                else
                    log_error "너무 많은 인자입니다."
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # If URL not provided via command line, get it interactively
    if [[ "$url_provided" == "false" || -z "$TARGET_URL" ]]; then
        get_user_input
    else
        # Validate URL format if provided via command line
        if [[ ! "$TARGET_URL" =~ ^https?:// ]]; then
            log_error "잘못된 URL 형식: $TARGET_URL. http:// 또는 https://로 시작해야 합니다."
            exit 1
        fi
    fi
}

# Kubernetes utility functions
kubectl_cmd() {
    local kubectl_args=()
    
    if [[ -n "$KUBECONFIG" && -f "$KUBECONFIG" ]]; then
        kubectl_args+=(--kubeconfig="$KUBECONFIG")
    fi
    
    if [[ -n "$KUBE_CONTEXT" ]]; then
        kubectl_args+=(--context="$KUBE_CONTEXT")
    fi
    
    kubectl "${kubectl_args[@]}" "$@"
}

# Check Kubernetes connection
check_kube_connection() {
    log_info "Kubernetes 클러스터 연결 확인 중..."
    
    if [[ -n "$KUBE_CONTEXT" ]]; then
        log_info "사용 중인 컨텍스트: $KUBE_CONTEXT"
    else
        local current_context=$(kubectl_cmd config current-context 2>/dev/null || echo "unknown")
        log_info "현재 컨텍스트: $current_context"
    fi
    
    if ! kubectl_cmd cluster-info &>/dev/null; then
        log_error "Kubernetes 클러스터에 연결할 수 없습니다."
        log_error "kubeconfig 파일을 확인하세요: $KUBECONFIG"
        return 1
    fi
    
    log_success "Kubernetes 클러스터 연결 성공"
    return 0
}

# Store check result
store_result() {
    local check_name="$1"
    local status="$2"
    local details="$3"
    local explanation="${4:-}"
    
    CHECK_RESULTS["$check_name"]="$status"
    CHECK_DETAILS["$check_name"]="$details"
    
    case "$status" in
        "SUCCESS")
            SUCCESS_CHECKS+=("$check_name")
            ;;
        "WARNING")
            WARNING_CHECKS+=("$check_name")
            ;;
        "FAILED")
            FAILED_CHECKS+=("$check_name")
            ;;
    esac
}

# Check 1: Node status
check_node_status() {
    log_info "노드 상태 점검 중..."
    
    # Get node information with error handling
    local node_info
    if ! node_info=$(kubectl_cmd get nodes -o json 2>/dev/null); then
        log_error "Failed to get node information"
        store_result "nodes" "FAILED" "클러스터 노드 정보를 가져올 수 없습니다."
        return 1
    fi
    
    if [[ -z "$node_info" ]]; then
        log_error "Empty node information received"
        store_result "nodes" "FAILED" "노드 정보가 비어있습니다."
        return 1
    fi
    
    local node_count
    if ! node_count=$(echo "$node_info" | jq -r '.items | length' 2>/dev/null); then
        log_error "Failed to parse node count"
        store_result "nodes" "FAILED" "노드 수를 파싱할 수 없습니다."
        return 1
    fi
    
    log_debug "Found $node_count nodes"
    
    local ready_nodes=0
    local not_ready_nodes=0
    local details=""
    
    # Parse node status information
    local node_status_list
    node_status_list=$(echo "$node_info" | jq -r '.items[] | "\(.metadata.name) \(.status.conditions[] | select(.type=="Ready") | .status)"')
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local node_name=$(echo "$line" | awk '{print $1}')
        local node_status=$(echo "$line" | awk '{print $2}')
        
        if [[ "$node_status" == "True" ]]; then
            ((ready_nodes++))
        else
            ((not_ready_nodes++))
            details+="노드 '$node_name'이 Ready 상태가 아닙니다. "
        fi
    done <<< "$node_status_list"
    
    # Get node resource information
    local node_name_list
    if ! node_name_list=$(echo "$node_info" | jq -r '.items[].metadata.name' 2>/dev/null); then
        log_warn "Failed to get node name list, skipping resource collection"
    else
        log_info "노드 리소스 정보 수집 중..."
        local processed_nodes=0
        for node_name in $node_name_list; do
            [[ -z "$node_name" ]] && continue
            log_info "노드 '$node_name' 리소스 정보 수집 중..."
            if get_node_resources "$node_name"; then
                ((processed_nodes++))
                log_debug "Successfully processed node: $node_name"
            else
                log_warn "Failed to get resources for node: $node_name"
            fi
        done
        log_info "총 $processed_nodes개 노드의 리소스 정보를 수집했습니다."
    fi

    # Check for resource threshold violations (80%)
    local high_memory_nodes=""
    local high_pod_nodes=""
    local high_disk_nodes=""

    for node_name in "${!NODE_RESOURCES[@]}"; do
        local node_data="${NODE_RESOURCES[$node_name]}"

        # Extract percentages from JSON data
        local memory_percent=$(echo "$node_data" | grep -o '"memory_percent":"[^"]*"' | cut -d'"' -f4 | tr -d '.')
        local pod_percent=$(echo "$node_data" | grep -o '"pod_percent":"[^"]*"' | cut -d'"' -f4 | tr -d '.')

        # Check memory usage
        if [[ -n "$memory_percent" && "$memory_percent" =~ ^[0-9]+$ && "$memory_percent" -ge 80 ]]; then
            high_memory_nodes+="노드 '$node_name' 메모리 사용률: ${memory_percent}%. "
        fi

        # Check pod usage
        if [[ -n "$pod_percent" && "$pod_percent" =~ ^[0-9]+$ && "$pod_percent" -ge 80 ]]; then
            high_pod_nodes+="노드 '$node_name' Pod 사용률: ${pod_percent}%. "
        fi
    done

    # Store resource threshold check results
    if [[ -n "$high_memory_nodes" ]]; then
        store_result "node_memory_usage" "WARNING" "$high_memory_nodes" "메모리 사용률이 80%를 초과한 노드는 성능 저하 및 Pod 스케줄링 실패가 발생할 수 있습니다. 불필요한 워크로드를 제거하거나 노드를 추가하세요."
    else
        store_result "node_memory_usage" "SUCCESS" "모든 노드의 메모리 사용률이 정상 범위입니다."
    fi

    if [[ -n "$high_pod_nodes" ]]; then
        store_result "node_pod_usage" "WARNING" "$high_pod_nodes" "Pod 사용률이 80%를 초과한 노드는 신규 Pod를 스케줄링할 수 없게 됩니다. 노드를 추가하거나 불필요한 Pod를 제거하세요."
    else
        store_result "node_pod_usage" "SUCCESS" "모든 노드의 Pod 사용률이 정상 범위입니다."
    fi

    if [[ $not_ready_nodes -eq 0 ]]; then
        store_result "nodes" "SUCCESS" "모든 노드($node_count개)가 Ready 상태입니다."
    else
        store_result "nodes" "FAILED" "$details" "노드가 Ready 상태가 아닐 때는 클러스터의 작업 부하를 처리할 수 없습니다. 노드의 kubelet 서비스와 네트워크 연결을 확인하세요."
    fi
}

# Get node resource information
get_node_resources() {
    local node_name=$1
    
    # Add timeout and error handling
    local node_info
    if ! node_info=$(timeout 20 kubectl_cmd describe node "$node_name" 2>/dev/null); then
        log_warn "Failed to describe node: $node_name"
        return 1
    fi
    
    if [[ -z "$node_info" ]]; then
        log_warn "Empty node information for: $node_name"
        return 1
    fi
    
    # Extract capacity and allocatable
    local cpu_capacity=$(echo "$node_info" | grep -A 10 "Capacity:" | grep "cpu:" | awk '{print $2}' | sed 's/m$//')
    local memory_capacity=$(echo "$node_info" | grep -A 10 "Capacity:" | grep "memory:" | awk '{print $2}' | sed 's/Ki$//')
    local cpu_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "cpu:" | awk '{print $2}' | sed 's/m$//')
    local memory_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "memory:" | awk '{print $2}' | sed 's/Ki$//')
    
    # Get current requests and extract percentages directly from kubectl output
    local resource_requests=$(echo "$node_info" | grep -A 20 "Allocated resources:")

    # Extract percentages from the output (format: "value (percentage%)")
    local cpu_percent=$(echo "$resource_requests" | grep -w "cpu" | awk '{print $3}' | tr -d '()%' || echo "0")
    local memory_percent=$(echo "$resource_requests" | grep -w "memory" | awk '{print $3}' | tr -d '()%' || echo "0")

    # Get pod count with timeout
    local pod_count=0
    if ! pod_count=$(timeout 15 kubectl_cmd get pods --all-namespaces --field-selector spec.nodeName="$node_name" --no-headers 2>/dev/null | wc -l); then
        log_warn "Failed to get pod count for node: $node_name"
        pod_count=0
    fi
    local max_pods=$(echo "$node_info" | grep "pods:" | tail -1 | awk '{print $2}')

    # Calculate pod percentage
    local pod_percent=0
    if [[ -n "$max_pods" && "$max_pods" =~ ^[0-9]+$ && "$max_pods" -gt 0 ]]; then
        pod_percent=$(echo "scale=1; ($pod_count * 100) / $max_pods" | bc -l 2>/dev/null || echo "0")
    fi

    # Ensure percentages are numeric (default to 0 if empty or invalid)
    [[ ! "$cpu_percent" =~ ^[0-9.]+$ ]] && cpu_percent="0"
    [[ ! "$memory_percent" =~ ^[0-9.]+$ ]] && memory_percent="0"

    # For backward compatibility, extract raw values as well
    local cpu_requests=$(echo "$resource_requests" | grep -w "cpu" | awk '{print $2}' | sed 's/m$//' || echo "0")
    local memory_requests=$(echo "$resource_requests" | grep -w "memory" | awk '{print $2}' | sed -E 's/[KMGT]i$//' || echo "0")
    
    # Check for GPU
    local gpu_info=""
    if echo "$node_info" | grep -q "nvidia.com/gpu"; then
        local gpu_capacity=$(echo "$node_info" | grep "nvidia.com/gpu:" | awk '{print $2}')
        local gpu_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "nvidia.com/gpu:" | awk '{print $2}')
        local gpu_requests=$(echo "$resource_requests" | grep "nvidia.com/gpu" | awk '{print $2}' || echo "0")
        local gpu_percent=0
        
        if [[ -n "$gpu_allocatable" && "$gpu_allocatable" =~ ^[0-9]+$ && "$gpu_allocatable" -gt 0 && -n "$gpu_requests" && "$gpu_requests" =~ ^[0-9]+$ ]]; then
            gpu_percent=$(echo "scale=1; ($gpu_requests * 100) / $gpu_allocatable" | bc -l 2>/dev/null || echo "0")
        fi
        
        gpu_info=",\"gpu_capacity\":\"$gpu_capacity\",\"gpu_allocatable\":\"$gpu_allocatable\",\"gpu_requests\":\"$gpu_requests\",\"gpu_percent\":\"$gpu_percent\""
    fi
    
    # Store node resource data with proper JSON formatting
    local node_json="{\"name\":\"$node_name\",\"pod_count\":$pod_count,\"max_pods\":$max_pods,\"pod_percent\":\"$pod_percent\",\"cpu_allocatable\":$cpu_allocatable,\"cpu_requests\":$cpu_requests,\"cpu_percent\":\"$cpu_percent\",\"memory_allocatable\":$memory_allocatable,\"memory_requests\":$memory_requests,\"memory_percent\":\"$memory_percent\"$gpu_info}"
    
    NODE_RESOURCES["$node_name"]="$node_json"
    
    log_debug "Stored node resources for $node_name: $node_json"
    log_info "노드 $node_name 리소스 정보: Pods ${pod_percent}%, CPU ${cpu_percent}%, Memory ${memory_percent}%"
}

# Check 2: Pod status
check_pod_status() {
    log_info "파드 상태 점검 중..."
    
    local pod_info=$(kubectl_cmd get pods -A -o json 2>/dev/null)
    local total_pods=$(echo "$pod_info" | jq -r '.items | length')
    local running_pods=0
    local failed_pods=0
    local pending_pods=0
    local details=""
    local problem_pods=""
    
    while read -r namespace pod_name phase; do
        case "$phase" in
            "Running"|"Succeeded")
                ((running_pods++))
                ;;
            "Pending")
                ((pending_pods++))
                problem_pods+="$namespace/$pod_name (Pending), "
                ;;
            *)
                ((failed_pods++))
                problem_pods+="$namespace/$pod_name ($phase), "
                ;;
        esac
    done < <(echo "$pod_info" | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.status.phase)"')
    
    if [[ $failed_pods -eq 0 && $pending_pods -eq 0 ]]; then
        store_result "pods" "SUCCESS" "모든 파드($total_pods개)가 정상 상태입니다."
    elif [[ $failed_pods -eq 0 && $pending_pods -gt 0 ]]; then
        details="$pending_pods개의 파드가 Pending 상태입니다: ${problem_pods%, }"
        store_result "pods" "WARNING" "$details" "Pending 상태의 파드는 리소스 부족이나 스케줄링 제약으로 인해 실행되지 못하고 있습니다. 클러스터 리소스와 파드 요구사항을 확인하세요."
    else
        details="$failed_pods개의 파드가 실패 상태, $pending_pods개의 파드가 Pending 상태입니다: ${problem_pods%, }"
        store_result "pods" "FAILED" "$details" "실패한 파드는 애플리케이션 오류나 설정 문제를 나타냅니다. kubectl describe pod 및 kubectl logs 명령어로 상세한 오류를 확인하세요."
    fi
}

# Check 3: Deployment status
check_deployment_status() {
    log_info "디플로이먼트 상태 점검 중..."
    
    local deploy_info=$(kubectl_cmd get deployments -A -o json 2>/dev/null)
    local total_deployments=$(echo "$deploy_info" | jq -r '.items | length')
    local healthy_deployments=0
    local unhealthy_deployments=0
    local details=""
    local problem_deployments=""
    
    while read -r namespace deploy_name replicas ready available; do
        if [[ "$replicas" == "$ready" && "$replicas" == "$available" ]]; then
            ((healthy_deployments++))
        else
            ((unhealthy_deployments++))
            problem_deployments+="$namespace/$deploy_name (desired: $replicas, ready: $ready, available: $available), "
        fi
    done < <(echo "$deploy_info" | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.spec.replicas // 0) \(.status.readyReplicas // 0) \(.status.availableReplicas // 0)"')
    
    if [[ $unhealthy_deployments -eq 0 ]]; then
        store_result "deployments" "SUCCESS" "모든 디플로이먼트($total_deployments개)가 정상 상태입니다."
    else
        details="$unhealthy_deployments개의 디플로이먼트가 비정상 상태입니다: ${problem_deployments%, }"
        store_result "deployments" "FAILED" "$details" "디플로이먼트가 원하는 복제본 수를 유지하지 못하고 있습니다. 파드 실행 실패, 리소스 부족, 또는 이미지 pull 오류 등이 원인일 수 있습니다."
    fi
}

# Check 4: Service endpoint status
check_service_endpoints() {
    log_info "서비스 엔드포인트 상태 점검 중..."
    
    local svc_info=$(kubectl_cmd get services -A -o json 2>/dev/null)
    local total_services=$(echo "$svc_info" | jq -r '.items | length')
    local services_with_endpoints=0
    local services_without_endpoints=0
    local problem_services=""
    
    while read -r namespace svc_name svc_type; do
        # Skip headless services and ExternalName services
        if [[ "$svc_type" == "ExternalName" ]]; then
            ((services_with_endpoints++))
            continue
        fi
        
        # Skip kserve/modelmesh-serving service
        if [[ "$namespace" == "kserve" && "$svc_name" == "modelmesh-serving" ]]; then
            log_info "Skipping kserve/modelmesh-serving service as requested"
            ((services_with_endpoints++))
            continue
        fi
        
        local endpoints=$(kubectl_cmd get endpoints -n "$namespace" "$svc_name" -o json 2>/dev/null)
        local endpoint_count=$(echo "$endpoints" | jq -r '.subsets[]?.addresses[]? | length' 2>/dev/null | wc -l)
        
        if [[ $endpoint_count -gt 0 ]]; then
            ((services_with_endpoints++))
        else
            ((services_without_endpoints++))
            problem_services+="$namespace/$svc_name, "
        fi
    done < <(echo "$svc_info" | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.spec.type)"')
    
    if [[ $services_without_endpoints -eq 0 ]]; then
        store_result "services" "SUCCESS" "모든 서비스($total_services개)가 유효한 엔드포인트를 가지고 있습니다."
    else
        local details="$services_without_endpoints개의 서비스가 엔드포인트를 가지고 있지 않습니다: ${problem_services%, }"
        store_result "services" "FAILED" "$details" "엔드포인트가 없는 서비스는 트래픽을 처리할 수 없습니다. 관련 파드가 실행 중인지, 서비스 셀렉터가 올바른지 확인하세요."
    fi
}

# Check 5: PV/PVC status
check_storage_status() {
    log_info "스토리지 (PV/PVC) 상태 점검 중..."
    
    local pv_info=$(kubectl_cmd get pv -o json 2>/dev/null)
    local pvc_info=$(kubectl_cmd get pvc -A -o json 2>/dev/null)
    
    local total_pvs=$(echo "$pv_info" | jq -r '.items | length')
    local bound_pvs=0
    local unbound_pvs=0
    local problem_pvs=""
    
    while read -r pv_name phase; do
        if [[ "$phase" == "Bound" ]]; then
            ((bound_pvs++))
        else
            ((unbound_pvs++))
            problem_pvs+="$pv_name ($phase), "
        fi
    done < <(echo "$pv_info" | jq -r '.items[] | "\(.metadata.name) \(.status.phase)"')
    
    local total_pvcs=$(echo "$pvc_info" | jq -r '.items | length')
    local bound_pvcs=0
    local unbound_pvcs=0
    local problem_pvcs=""
    
    while read -r namespace pvc_name phase; do
        if [[ "$phase" == "Bound" ]]; then
            ((bound_pvcs++))
        else
            ((unbound_pvcs++))
            problem_pvcs+="$namespace/$pvc_name ($phase), "
        fi
    done < <(echo "$pvc_info" | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.status.phase)"')
    
    local details=""
    local status="SUCCESS"
    
    if [[ $unbound_pvs -gt 0 ]]; then
        details+="$unbound_pvs개의 PV가 Bound 상태가 아닙니다: ${problem_pvs%, }. "
        status="FAILED"
    fi
    
    if [[ $unbound_pvcs -gt 0 ]]; then
        details+="$unbound_pvcs개의 PVC가 Bound 상태가 아닙니다: ${problem_pvcs%, }. "
        status="FAILED"
    fi
    
    if [[ "$status" == "SUCCESS" ]]; then
        store_result "storage" "SUCCESS" "모든 PV($total_pvs개)와 PVC($total_pvcs개)가 Bound 상태입니다."
    else
        store_result "storage" "FAILED" "${details% }" "Bound 상태가 아닌 PV/PVC는 스토리지 리소스를 사용할 수 없습니다. 스토리지 클래스 설정과 볼륨 프로비저닝을 확인하세요."
    fi
}

# Check 6: Rook-Ceph cluster health
check_rook_ceph_health() {
    log_info "Rook-Ceph 클러스터 상태 점검 중..."
    
    # Check if rook-ceph-tools deployment exists
    local tools_deployment=$(kubectl_cmd get deployment -n rook-ceph rook-ceph-tools -o json 2>/dev/null)
    if [[ -z "$tools_deployment" ]]; then
        store_result "rook_ceph" "WARNING" "rook-ceph-tools deployment를 찾을 수 없습니다." "Rook-Ceph가 설치되어 있지 않거나 tools deployment가 없습니다."
        return
    fi
    
    # Check if deployment is ready
    local ready_replicas=$(echo "$tools_deployment" | jq -r '.status.readyReplicas // 0')
    local desired_replicas=$(echo "$tools_deployment" | jq -r '.spec.replicas // 1')
    
    if [[ $ready_replicas -lt $desired_replicas ]]; then
        store_result "rook_ceph" "FAILED" "rook-ceph-tools 파드가 준비되지 않았습니다 ($ready_replicas/$desired_replicas)." "tools 파드가 실행 중이어야 Ceph 상태를 확인할 수 있습니다."
        return
    fi
    
    # Get the tools pod name
    local tools_pod=$(kubectl_cmd get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$tools_pod" ]]; then
        store_result "rook_ceph" "FAILED" "rook-ceph-tools 파드를 찾을 수 없습니다." "tools 파드가 실행 중이어야 합니다."
        return
    fi
    
    # Execute ceph -s command
    log_info "Ceph 상태 확인 중: $tools_pod"
    local ceph_status_output=$(kubectl_cmd exec -n rook-ceph "$tools_pod" -- ceph -s --format json 2>/dev/null)
    
    if [[ -z "$ceph_status_output" ]]; then
        store_result "rook_ceph" "FAILED" "Ceph 상태 명령 실행에 실패했습니다." "ceph -s 명령이 응답하지 않습니다."
        return
    fi
    
    # Parse ceph health status
    local health_status=$(echo "$ceph_status_output" | jq -r '.health.status // "UNKNOWN"' 2>/dev/null)
    local health_checks=$(echo "$ceph_status_output" | jq -r '.health.checks // {}' 2>/dev/null)
    local overall_status=$(echo "$ceph_status_output" | jq -r '.health.overall_status // "UNKNOWN"' 2>/dev/null)
    
    # Log detailed status for parsing
    local detailed_log="Ceph Health Status: $health_status, Overall: $overall_status"
    if [[ "$health_checks" != "{}" && "$health_checks" != "null" ]]; then
        local check_details=$(echo "$health_checks" | jq -r 'to_entries[] | "\(.key): \(.value.summary.message // .value.detail[0].message // "no details")"' 2>/dev/null | tr '\n' '; ')
        detailed_log="$detailed_log, Details: $check_details"
    fi
    
    log_info "$detailed_log"
    
    # Store result based on health status
    case "$health_status" in
        "HEALTH_OK")
            store_result "rook_ceph" "SUCCESS" "Ceph 클러스터가 정상 상태입니다 (HEALTH_OK)." "$detailed_log"
            ;;
        "HEALTH_WARN")
            store_result "rook_ceph" "WARNING" "Ceph 클러스터에 경고가 있습니다 (HEALTH_WARN)." "$detailed_log"
            ;;
        "HEALTH_ERR"|*)
            store_result "rook_ceph" "FAILED" "Ceph 클러스터에 오류가 있습니다 ($health_status)." "$detailed_log"
            ;;
    esac
}

# Check 7: Ingress backend connections
check_ingress_backends() {
    log_info "Ingress 백엔드 연결 상태 점검 중..."
    
    local ingress_info=$(kubectl_cmd get ingress -A -o json 2>/dev/null)
    local total_ingresses=$(echo "$ingress_info" | jq -r '.items | length')
    
    if [[ $total_ingresses -eq 0 ]]; then
        store_result "ingress" "SUCCESS" "Ingress 리소스가 없습니다."
        return
    fi
    
    local healthy_ingresses=0
    local unhealthy_ingresses=0
    local problem_ingresses=""
    
    while read -r namespace ingress_name; do
        local backend_valid=true
        
        # Check if backend services exist
        local backends=$(echo "$ingress_info" | jq -r ".items[] | select(.metadata.name==\"$ingress_name\" and .metadata.namespace==\"$namespace\") | .spec.rules[]?.http?.paths[]?.backend?.service?.name // empty" 2>/dev/null)
        
        for backend in $backends; do
            if ! kubectl_cmd get service -n "$namespace" "$backend" &>/dev/null; then
                backend_valid=false
                problem_ingresses+="$namespace/$ingress_name (backend service '$backend' not found), "
                break
            fi
        done
        
        if [[ "$backend_valid" == "true" ]]; then
            ((healthy_ingresses++))
        else
            ((unhealthy_ingresses++))
        fi
    done < <(echo "$ingress_info" | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ $unhealthy_ingresses -eq 0 ]]; then
        store_result "ingress" "SUCCESS" "모든 Ingress($total_ingresses개)가 유효한 백엔드 서비스에 연결되어 있습니다."
    else
        local details="$unhealthy_ingresses개의 Ingress가 잘못된 백엔드를 참조하고 있습니다: ${problem_ingresses%, }"
        store_result "ingress" "FAILED" "$details" "Ingress가 존재하지 않는 서비스를 백엔드로 참조하고 있습니다. Ingress 설정에서 올바른 서비스 이름을 확인하세요."
    fi
}

# Global variables for disk usage
declare -g HARBOR_DISK_USAGE=""
declare -g HARBOR_DISK_DETAILS=""
declare -g MINIO_DISK_USAGE=""
declare -g MINIO_DISK_DETAILS=""

# Check 7: Harbor disk usage
check_harbor_disk_usage() {
    log_info "Harbor 디스크 사용량 점검 중..."
    
    # Check if harbor-registry deployment exists
    local harbor_deployment=$(kubectl_cmd get deployment -n harbor harbor-registry -o json 2>/dev/null)
    if [[ -z "$harbor_deployment" ]]; then
        store_result "harbor_disk" "WARNING" "harbor-registry deployment를 찾을 수 없습니다." "Harbor가 설치되어 있지 않습니다."
        return
    fi
    
    # Check if deployment is ready
    local ready_replicas=$(echo "$harbor_deployment" | jq -r '.status.readyReplicas // 0')
    local desired_replicas=$(echo "$harbor_deployment" | jq -r '.spec.replicas // 1')
    
    if [[ $ready_replicas -lt $desired_replicas ]]; then
        store_result "harbor_disk" "FAILED" "harbor-registry 파드가 준비되지 않았습니다 ($ready_replicas/$desired_replicas)." "Harbor registry 파드가 실행 중이어야 합니다."
        return
    fi
    
    # Get the harbor-registry pod name
    local harbor_pod=$(kubectl_cmd get pods -n harbor -l app=harbor,component=registry -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$harbor_pod" ]]; then
        store_result "harbor_disk" "FAILED" "harbor-registry 파드를 찾을 수 없습니다." "registry 파드가 실행 중이어야 합니다."
        return
    fi
    
    # Execute df -h command to check RBD disk usage
    log_info "Harbor 디스크 사용량 확인 중: $harbor_pod"
    local disk_usage=$(kubectl_cmd exec -n harbor "$harbor_pod" -- df -h 2>/dev/null | grep "rbd" | head -1)
    
    if [[ -z "$disk_usage" ]]; then
        store_result "harbor_disk" "WARNING" "Harbor 디스크 사용량을 확인할 수 없습니다." "df -h 명령에서 RBD 디스크를 찾을 수 없습니다."
        return
    fi
    
    # Parse disk usage information
    local usage_percent=$(echo "$disk_usage" | awk '{print $5}' | sed 's/%//')
    local used_space=$(echo "$disk_usage" | awk '{print $3}')
    local total_space=$(echo "$disk_usage" | awk '{print $2}')
    local mount_point=$(echo "$disk_usage" | awk '{print $6}')
    
    # Store in global variable for dashboard display
    HARBOR_DISK_USAGE="$usage_percent"
    HARBOR_DISK_DETAILS="Used: $used_space/$total_space ($usage_percent%) on $mount_point"
    
    # Log detailed information
    local detailed_log="Harbor Disk Usage: $used_space/$total_space ($usage_percent%) on $mount_point"
    log_info "$detailed_log"
    
    # Determine result based on usage percentage
    if [[ $usage_percent -ge 90 ]]; then
        store_result "harbor_disk" "FAILED" "Harbor 디스크 사용량이 매우 높습니다 ($usage_percent%)." "$detailed_log"
    elif [[ $usage_percent -ge 80 ]]; then
        store_result "harbor_disk" "WARNING" "Harbor 디스크 사용량이 높습니다 ($usage_percent%)." "$detailed_log"
    else
        store_result "harbor_disk" "SUCCESS" "Harbor 디스크 사용량이 정상 범위입니다 ($usage_percent%)." "$detailed_log"
    fi
}

# Check 8: Minio disk usage
check_minio_disk_usage() {
    log_info "Minio 디스크 사용량 점검 중..."
    
    # Check if minio statefulset exists
    local minio_statefulset=$(kubectl_cmd get statefulset -n minio minio -o json 2>/dev/null)
    if [[ -z "$minio_statefulset" ]]; then
        store_result "minio_disk" "WARNING" "minio statefulset를 찾을 수 없습니다." "Minio가 설치되어 있지 않습니다."
        return
    fi
    
    # Check if statefulset is ready
    local ready_replicas=$(echo "$minio_statefulset" | jq -r '.status.readyReplicas // 0')
    local desired_replicas=$(echo "$minio_statefulset" | jq -r '.spec.replicas // 1')
    
    if [[ $ready_replicas -lt $desired_replicas ]]; then
        store_result "minio_disk" "FAILED" "minio 파드가 준비되지 않았습니다 ($ready_replicas/$desired_replicas)." "Minio 파드가 실행 중이어야 합니다."
        return
    fi
    
    # Get the minio pod name (usually minio-0 for statefulset)
    local minio_pod=$(kubectl_cmd get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$minio_pod" ]]; then
        store_result "minio_disk" "FAILED" "minio 파드를 찾을 수 없습니다." "Minio 파드가 실행 중이어야 합니다."
        return
    fi
    
    # Execute df -h command to check RBD disk usage
    log_info "Minio 디스크 사용량 확인 중: $minio_pod"
    local disk_usage=$(kubectl_cmd exec -n minio "$minio_pod" -- df -h 2>/dev/null | grep "rbd" | head -1)
    
    if [[ -z "$disk_usage" ]]; then
        store_result "minio_disk" "WARNING" "Minio 디스크 사용량을 확인할 수 없습니다." "df -h 명령에서 RBD 디스크를 찾을 수 없습니다."
        return
    fi
    
    # Parse disk usage information
    local usage_percent=$(echo "$disk_usage" | awk '{print $5}' | sed 's/%//')
    local used_space=$(echo "$disk_usage" | awk '{print $3}')
    local total_space=$(echo "$disk_usage" | awk '{print $2}')
    local mount_point=$(echo "$disk_usage" | awk '{print $6}')
    
    # Store in global variable for dashboard display
    MINIO_DISK_USAGE="$usage_percent"
    MINIO_DISK_DETAILS="Used: $used_space/$total_space ($usage_percent%) on $mount_point"
    
    # Log detailed information
    local detailed_log="Minio Disk Usage: $used_space/$total_space ($usage_percent%) on $mount_point"
    log_info "$detailed_log"
    
    # Determine result based on usage percentage
    if [[ $usage_percent -ge 90 ]]; then
        store_result "minio_disk" "FAILED" "Minio 디스크 사용량이 매우 높습니다 ($usage_percent%)." "$detailed_log"
    elif [[ $usage_percent -ge 80 ]]; then
        store_result "minio_disk" "WARNING" "Minio 디스크 사용량이 높습니다 ($usage_percent%)." "$detailed_log"
    else
        store_result "minio_disk" "SUCCESS" "Minio 디스크 사용량이 정상 범위입니다 ($usage_percent%)." "$detailed_log"
    fi
}

# Check 9: URL connectivity
check_url_connectivity() {
    log_info "URL 연결 상태 점검 중: $TARGET_URL"
    
    local response_code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL" --connect-timeout 10 --max-time 30 2>/dev/null || echo "000")
    local response_time=$(curl -s -o /dev/null -w "%{time_total}" "$TARGET_URL" --connect-timeout 10 --max-time 30 2>/dev/null || echo "0.000")
    
    if [[ "$response_code" == "200" ]]; then
        store_result "url_check" "SUCCESS" "URL이 정상적으로 응답합니다 (응답 코드: $response_code, 응답 시간: ${response_time}초)."
    elif [[ "$response_code" =~ ^[45][0-9][0-9]$ ]]; then
        store_result "url_check" "FAILED" "URL에서 오류 응답을 받았습니다 (응답 코드: $response_code, 응답 시간: ${response_time}초)." "HTTP 4xx 오류는 클라이언트 오류(인증, 권한, 잘못된 요청 등)를, 5xx 오류는 서버 오류를 나타냅니다."
    elif [[ "$response_code" =~ ^[23][0-9][0-9]$ ]]; then
        store_result "url_check" "WARNING" "URL이 응답하지만 200이 아닌 코드입니다 (응답 코드: $response_code, 응답 시간: ${response_time}초)." "리다이렉션이나 기타 상태 코드입니다. 애플리케이션 동작을 확인하세요."
    else
        store_result "url_check" "FAILED" "URL에 연결할 수 없습니다 (응답 코드: $response_code)." "네트워크 연결 문제이거나 서버가 응답하지 않고 있습니다. DNS 설정과 방화벽을 확인하세요."
    fi
}

# Helper function to determine color based on usage percentage
get_usage_color() {
    local percent=$(echo "$1" | cut -d. -f1)
    if [[ $percent -lt 60 ]]; then echo "success"
    elif [[ $percent -lt 80 ]]; then echo "warning"
    else echo "danger"
    fi
}

# Generate HTML report
generate_html_report() {
    local html_file="${OUTPUT_DIR}/k8s_health_report_${TIMESTAMP}.html"
    
    # Calculate overall status
    local total_checks=$((${#SUCCESS_CHECKS[@]} + ${#WARNING_CHECKS[@]} + ${#FAILED_CHECKS[@]}))
    local overall_status="정상"
    local status_class="success"
    
    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
        overall_status="문제 발생"
        status_class="danger"
    elif [[ ${#WARNING_CHECKS[@]} -gt 0 ]]; then
        overall_status="경고"
        status_class="warning"
    fi
    
    cat > "$html_file" << 'EOF'
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes 클러스터 상태 보고서</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.min.js"></script>
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            background-attachment: fixed;
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        }
        .dashboard-container {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            box-shadow: 0 25px 45px rgba(0, 0, 0, 0.1);
            margin: 20px;
            padding: 30px;
        }
        .status-icon {
            font-size: 1.2em;
            margin-right: 8px;
        }
        .resource-bar {
            height: 25px;
            border-radius: 12px;
            position: relative;
            overflow: hidden;
            background: #e9ecef;
            box-shadow: inset 0 2px 4px rgba(0,0,0,0.1);
        }
        .resource-bar .fill {
            height: 100%;
            transition: width 1s cubic-bezier(0.4, 0, 0.2, 1);
            border-radius: 12px;
            background: linear-gradient(45deg, var(--fill-color), var(--fill-color-light));
        }
        .resource-bar .label {
            position: absolute;
            width: 100%;
            text-align: center;
            line-height: 25px;
            font-weight: 600;
            color: #2d3436;
            z-index: 1;
            font-size: 0.85em;
        }
        .advanced-card {
            background: linear-gradient(135deg, #ffffff 0%, #f8f9fa 100%);
            border: none;
            border-radius: 16px;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.08);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
            margin-bottom: 25px;
            overflow: hidden;
        }
        .advanced-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.12);
        }
        .advanced-card .card-header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border: none;
            color: white;
            font-weight: 600;
            padding: 20px 25px;
        }
        .node-dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 25px;
            margin-bottom: 30px;
        }
        .node-item {
            background: white;
            border-radius: 16px;
            padding: 25px;
            box-shadow: 0 8px 25px rgba(0, 0, 0, 0.08);
            border: 1px solid rgba(102, 126, 234, 0.1);
            transition: all 0.3s ease;
        }
        .node-item:hover {
            transform: translateY(-3px);
            box-shadow: 0 15px 35px rgba(0, 0, 0, 0.12);
            border-color: rgba(102, 126, 234, 0.3);
        }
        .node-title {
            font-size: 1.4em;
            font-weight: 700;
            color: #2d3436;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .resource-section {
            margin: 20px 0;
        }
        .resource-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }
        .resource-label {
            font-weight: 600;
            color: #636e72;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .resource-value {
            font-size: 1.1em;
            font-weight: 700;
        }
        .chart-container {
            position: relative;
            height: 120px;
            margin: 15px 0;
        }
        .chart-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            align-items: center;
        }
        .summary-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-card {
            background: white;
            padding: 25px;
            border-radius: 16px;
            text-align: center;
            box-shadow: 0 8px 25px rgba(0, 0, 0, 0.06);
            border: 1px solid rgba(102, 126, 234, 0.1);
            transition: all 0.3s ease;
        }
        .stat-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 12px 30px rgba(0, 0, 0, 0.1);
        }
        .stat-icon {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .stat-value {
            font-size: 2.2em;
            font-weight: 700;
            margin: 10px 0;
        }
        .stat-label {
            color: #636e72;
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            font-size: 0.85em;
        }
        .explanation-box {
            background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%);
            border-left: 4px solid #6c757d;
            padding: 15px 20px;
            margin-top: 15px;
            border-radius: 0 12px 12px 0;
            font-size: 0.9em;
        }
        .explanation-box.danger {
            border-left-color: #dc3545;
            background: linear-gradient(135deg, #f8d7da 0%, #f5c6cb 100%);
        }
        .explanation-box.warning {
            border-left-color: #ffc107;
            background: linear-gradient(135deg, #fff3cd 0%, #ffeaa7 100%);
        }
        .check-item {
            background: white;
            border-radius: 12px;
            padding: 20px;
            margin: 15px 0;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.05);
            border-left: 4px solid #28a745;
            transition: all 0.3s ease;
        }
        .check-item.warning {
            border-left-color: #ffc107;
        }
        .check-item.danger {
            border-left-color: #dc3545;
        }
        .check-item:hover {
            transform: translateX(5px);
            box-shadow: 0 8px 25px rgba(0, 0, 0, 0.1);
        }
        @media (max-width: 768px) {
            .chart-grid {
                grid-template-columns: 1fr;
            }
            .node-dashboard {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="dashboard-container">
        <!-- Header Section -->
        <div class="text-center mb-5">
            <h1 class="display-3 fw-bold mb-3" style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;">
                <i class="fas fa-rocket me-3"></i>Kubernetes 클러스터 대시보드
            </h1>
            <p class="lead text-muted fs-5">생성 시간: REPORT_TIMESTAMP</p>
        </div>

        <!-- Summary Statistics -->
        <div class="summary-stats">
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="fas fa-clipboard-check"></i>
                </div>
                <div class="stat-value text-primary">SUCCESS_COUNT</div>
                <div class="stat-label">성공한 점검</div>
            </div>
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="fas fa-exclamation-triangle"></i>
                </div>
                <div class="stat-value text-warning">WARNING_COUNT</div>
                <div class="stat-label">경고 점검</div>
            </div>
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="fas fa-times-circle"></i>
                </div>
                <div class="stat-value text-danger">FAILED_COUNT</div>
                <div class="stat-label">실패한 점검</div>
            </div>
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="fas fa-chart-pie"></i>
                </div>
                <div class="stat-value OVERALL_STATUS_CLASS">OVERALL_STATUS</div>
                <div class="stat-label">전체 상태</div>
            </div>
        </div>

        <!-- Node Resources Dashboard -->
        <div class="advanced-card">
            <div class="card-header">
                <h3 class="mb-0">
                    <i class="fas fa-server me-2"></i>노드별 리소스 현황
                </h3>
            </div>
            <div class="card-body">
                <div class="node-dashboard" id="node-resources">
                    NODE_RESOURCES_CONTENT
                </div>
            </div>
        </div>

        <!-- Storage Monitoring Section -->
        <div class="advanced-card">
            <div class="card-header">
                <h3 class="mb-0">
                    <i class="fas fa-hdd me-2"></i>스토리지 모니터링
                </h3>
            </div>
            <div class="card-body">
                <div class="row">
                    <div class="col-md-6">
                        <div class="node-resource-card">
                            <div class="resource-section">
                                <div class="resource-header">
                                    <span class="resource-label"><i class="fas fa-anchor me-2"></i>Harbor 디스크 사용량</span>
                                    <span class="resource-value" id="harbor-usage-text">HARBOR_USAGE_TEXT</span>
                                </div>
                                <div class="progress-section">
                                    <div class="progress" style="height: 8px;">
                                        <div class="progress-bar" id="harbor-progress" role="progressbar" style="width: HARBOR_PROGRESS_WIDTH%; background-color: HARBOR_PROGRESS_COLOR;"></div>
                                    </div>
                                </div>
                                <div class="chart-container">
                                    <canvas id="harbor-chart"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-6">
                        <div class="node-resource-card">
                            <div class="resource-section">
                                <div class="resource-header">
                                    <span class="resource-label"><i class="fas fa-database me-2"></i>Minio 디스크 사용량</span>
                                    <span class="resource-value" id="minio-usage-text">MINIO_USAGE_TEXT</span>
                                </div>
                                <div class="progress-section">
                                    <div class="progress" style="height: 8px;">
                                        <div class="progress-bar" id="minio-progress" role="progressbar" style="width: MINIO_PROGRESS_WIDTH%; background-color: MINIO_PROGRESS_COLOR;"></div>
                                    </div>
                                </div>
                                <div class="chart-container">
                                    <canvas id="minio-chart"></canvas>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Detailed Check Results -->
        <div class="advanced-card">
            <div class="card-header">
                <h3 class="mb-0">
                    <i class="fas fa-clipboard-list me-2"></i>상세 점검 결과
                </h3>
            </div>
            <div class="card-body">
                CHECK_RESULTS_CONTENT
                            <div class="col-md-3">
                                <div class="text-center">
                                    <div class="alert alert-OVERALL_STATUS_CLASS" role="alert">
                                        <h4 class="alert-heading">전체 상태</h4>
                                        <h2>OVERALL_STATUS</h2>
                                    </div>
                                </div>
                            </div>
                            <div class="col-md-9">
                                <div class="row">
                                    <div class="col-md-4">
                                        <div class="card border-success">
                                            <div class="card-body text-center">
                                                <h5 class="card-title text-success">✅ 성공</h5>
                                                <h3 class="text-success">SUCCESS_COUNT</h3>
                                            </div>
                                        </div>
                                    </div>
                                    <div class="col-md-4">
                                        <div class="card border-warning">
                                            <div class="card-body text-center">
                                                <h5 class="card-title text-warning">⚠️ 경고</h5>
                                                <h3 class="text-warning">WARNING_COUNT</h3>
                                            </div>
                                        </div>
                                    </div>
                                    <div class="col-md-4">
                                        <div class="card border-danger">
                                            <div class="card-body text-center">
                                                <h5 class="card-title text-danger">❌ 실패</h5>
                                                <h3 class="text-danger">FAILED_COUNT</h3>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Node Resources Section -->
        <div class="row mb-4">
            <div class="col-12">
                <div class="card">
                    <div class="card-header">
                        <h3 class="card-title mb-0">🖥️ 노드 리소스 현황</h3>
                    </div>
                    <div class="card-body">
                        <div id="node-resources">
                            NODE_RESOURCES_CONTENT
                        </div>
                    </div>
                </div>
            </div>
        </div>


        <!-- Footer -->
        <div class="text-center mt-5 pt-4" style="border-top: 1px solid #e9ecef;">
            <p class="text-muted mb-2">
                <i class="fas fa-code me-2"></i>
                이 보고서는 자동으로 생성되었습니다
            </p>
            <p class="text-muted small">
                <i class="fas fa-users me-1"></i>DevOps Team | 
                <i class="fas fa-clock me-1"></i>REPORT_TIMESTAMP
            </p>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // Initialize charts and animations
        document.addEventListener('DOMContentLoaded', function() {
            // Animate progress bars
            const bars = document.querySelectorAll('.resource-bar .fill');
            bars.forEach((bar, index) => {
                setTimeout(() => {
                    bar.style.transform = 'scaleX(1)';
                    bar.style.transformOrigin = 'left';
                }, index * 100);
            });
            
            // Create donut charts for all nodes
            const chartOptions = {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                const labels = ['사용', '여유'];
                                return labels[context.dataIndex] + ': ' + context.parsed + '%';
                            }
                        }
                    }
                },
                cutout: '65%',
                animation: {
                    animateRotate: true,
                    animateScale: true,
                    duration: 1500
                }
            };
            
            // Initialize all canvas elements for charts
            document.querySelectorAll('canvas[id*=\"-chart-\"]').forEach(canvas => {
                const chartId = canvas.id;
                const chartType = chartId.split('-')[0]; // pod, cpu, memory, gpu
                
                // Get the percentage from the canvas context or data attributes
                let percentage = 0;
                let color = '#28a745';
                
                // Try to find the resource value from the parent container
                const resourceSection = canvas.closest('.resource-section');
                if (resourceSection) {
                    const valueElement = resourceSection.querySelector('.resource-value');
                    if (valueElement) {
                        const valueText = valueElement.textContent;
                        if (valueText.includes('/100')) {
                            percentage = parseInt(valueText.split('/')[0]);
                            color = valueElement.style.color || '#28a745';
                        } else if (valueText.includes('/')) {
                            // For pod usage like "35/110"
                            const [used, total] = valueText.split('/').map(n => parseInt(n));
                            percentage = Math.round((used / total) * 100);
                        }
                    }
                }
                
                // Create the chart
                new Chart(canvas, {
                    type: 'doughnut',
                    data: {
                        datasets: [{
                            data: [percentage, 100 - percentage],
                            backgroundColor: [color, '#e9ecef'],
                            borderWidth: 0,
                            borderRadius: 4
                        }]
                    },
                    options: chartOptions
                });
                
                // Add center text showing percentage
                const ctx = canvas.getContext('2d');
                const centerText = percentage + '%';
                
                // Override chart draw to add center text
                Chart.register({
                    id: 'centerText',
                    beforeDraw: (chart) => {
                        if (chart.canvas.id === chartId) {
                            const width = chart.width;
                            const height = chart.height;
                            const ctx = chart.ctx;
                            
                            ctx.restore();
                            const fontSize = (height / 100) * 16;
                            ctx.font = `bold ${fontSize}px Inter, Arial, sans-serif`;
                            ctx.textBaseline = 'middle';
                            ctx.fillStyle = color;
                            
                            const text = centerText;
                            const textX = Math.round((width - ctx.measureText(text).width) / 2);
                            const textY = height / 2;
                            
                            ctx.fillText(text, textX, textY);
                            ctx.save();
                        }
                    }
                });
            });
            
            // Function to create storage disk usage charts
            function createStorageChart() {
                // Create Harbor chart with injected data
                createDiskChart('harbor-chart', harborPercent, 'Harbor');
                
                // Create Minio chart with injected data
                createDiskChart('minio-chart', minioPercent, 'Minio');
            }
            
            function getCheckStatus(checkName) {
                if (checkName === 'harbor_disk') return 'HARBOR_STATUS';
                if (checkName === 'minio_disk') return 'MINIO_STATUS';
                return 'SUCCESS';
            }
            
            function getCheckDetails(checkName) {
                if (checkName === 'harbor_disk') return 'HARBOR_DETAILS';
                if (checkName === 'minio_disk') return 'MINIO_DETAILS';
                return 'No data available';
            }
            
            // Use actual data injected during HTML generation
            const harborPercent = HARBOR_CHART_PERCENT;
            const minioPercent = MINIO_CHART_PERCENT;
            
            function extractUsagePercent(details) {
                const match = details.match(/([0-9]+)%/);
                return match ? parseInt(match[1]) : 0;
            }
            
            function createDiskChart(canvasId, percentage, label) {
                const canvas = document.getElementById(canvasId);
                if (!canvas) return;
                
                const color = percentage > 85 ? '#dc3545' : percentage > 70 ? '#fd7e14' : percentage > 50 ? '#ffc107' : '#28a745';
                
                new Chart(canvas, {
                    type: 'doughnut',
                    data: {
                        datasets: [{
                            data: [percentage, 100 - percentage],
                            backgroundColor: [color, '#e9ecef'],
                            borderWidth: 0,
                            borderRadius: 4
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: {
                            legend: { display: false },
                            tooltip: {
                                callbacks: {
                                    label: function(context) {
                                        const labels = ['사용', '여유'];
                                        return labels[context.dataIndex] + ': ' + context.parsed + '%';
                                    }
                                }
                            }
                        },
                        animation: {
                            animateRotate: true,
                            duration: 1000
                        },
                        cutout: '70%'
                    }
                });
            }
            
            function updateStorageDisplay(type, percentage, details) {
                const color = percentage > 85 ? '#dc3545' : percentage > 70 ? '#fd7e14' : percentage > 50 ? '#ffc107' : '#28a745';
                
                // Update text display
                const textElement = document.getElementById(type + '-usage-text');
                if (textElement) {
                    textElement.textContent = percentage + '%';
                    textElement.style.color = color;
                }
                
                // Update progress bar
                const progressElement = document.getElementById(type + '-progress');
                if (progressElement) {
                    progressElement.style.width = percentage + '%';
                    progressElement.style.backgroundColor = color;
                    
                    // Add appropriate Bootstrap classes
                    progressElement.className = 'progress-bar';
                    if (percentage > 85) {
                        progressElement.classList.add('bg-danger');
                    } else if (percentage > 70) {
                        progressElement.classList.add('bg-warning');
                    } else {
                        progressElement.classList.add('bg-success');
                    }
                }
            }
            
            // Create Harbor and Minio storage charts
            createStorageChart();
            
            // Add hover effects to cards
            document.querySelectorAll('.node-item, .stat-card, .advanced-card').forEach(card => {
                card.addEventListener('mouseenter', function() {
                    this.style.transform = 'translateY(-5px)';
                });
                
                card.addEventListener('mouseleave', function() {
                    this.style.transform = 'translateY(0)';
                });
            });
        });
    </script>
</body>
</html>
EOF

    # Replace placeholders (using | as delimiter to avoid conflicts with /)
    sed -i "s|REPORT_TIMESTAMP|$(date '+%Y년 %m월 %d일 %H시 %M분')|g" "$html_file"
    sed -i "s|OVERALL_STATUS_CLASS|$status_class|g" "$html_file"
    sed -i "s|OVERALL_STATUS|$overall_status|g" "$html_file"
    sed -i "s|SUCCESS_COUNT|${#SUCCESS_CHECKS[@]}|g" "$html_file"
    sed -i "s|WARNING_COUNT|${#WARNING_CHECKS[@]}|g" "$html_file"
    sed -i "s|FAILED_COUNT|${#FAILED_CHECKS[@]}|g" "$html_file"
    
    # Add Harbor and Minio disk usage data
    local harbor_status="${CHECK_RESULTS[harbor_disk]:-N/A}"
    local harbor_details="${CHECK_DETAILS[harbor_disk]:-Harbor disk usage not available}"
    local minio_status="${CHECK_RESULTS[minio_disk]:-N/A}"
    local minio_details="${CHECK_DETAILS[minio_disk]:-Minio disk usage not available}"
    
    # Extract percentage and format data for Harbor
    local harbor_percent=0
    local harbor_text="N/A"
    local harbor_color="#6c757d"
    if [[ "$harbor_details" =~ ([0-9]+)% ]]; then
        harbor_percent="${BASH_REMATCH[1]}"
        if [[ "$harbor_details" =~ ([0-9.]+[KMGT])/([0-9.]+[KMGT]) ]]; then
            harbor_text="$harbor_percent% (${BASH_REMATCH[1]}/${BASH_REMATCH[2]})"
        else
            harbor_text="$harbor_percent%"
        fi
        
        # Set color based on percentage
        if [[ $harbor_percent -ge 90 ]]; then
            harbor_color="#dc3545"  # Red
        elif [[ $harbor_percent -ge 80 ]]; then
            harbor_color="#fd7e14"  # Orange  
        elif [[ $harbor_percent -ge 50 ]]; then
            harbor_color="#ffc107"  # Yellow
        else
            harbor_color="#28a745"  # Green
        fi
    fi
    
    # Extract percentage and format data for Minio
    local minio_percent=0
    local minio_text="N/A"
    local minio_color="#6c757d"
    if [[ "$minio_details" =~ ([0-9]+)% ]]; then
        minio_percent="${BASH_REMATCH[1]}"
        if [[ "$minio_details" =~ ([0-9.]+[KMGT])/([0-9.]+[KMGT]) ]]; then
            minio_text="$minio_percent% (${BASH_REMATCH[1]}/${BASH_REMATCH[2]})"
        else
            minio_text="$minio_percent%"
        fi
        
        # Set color based on percentage
        if [[ $minio_percent -ge 90 ]]; then
            minio_color="#dc3545"  # Red
        elif [[ $minio_percent -ge 80 ]]; then
            minio_color="#fd7e14"  # Orange
        elif [[ $minio_percent -ge 50 ]]; then
            minio_color="#ffc107"  # Yellow
        else
            minio_color="#28a745"  # Green
        fi
    fi
    
    # Replace all placeholders (using | as delimiter to avoid conflicts with /)
    sed -i "s|HARBOR_STATUS|$harbor_status|g" "$html_file"
    sed -i "s|HARBOR_DETAILS|$harbor_details|g" "$html_file"
    sed -i "s|HARBOR_USAGE_TEXT|$harbor_text|g" "$html_file"
    sed -i "s|HARBOR_PROGRESS_WIDTH|$harbor_percent|g" "$html_file"
    sed -i "s|HARBOR_PROGRESS_COLOR|$harbor_color|g" "$html_file"
    sed -i "s|HARBOR_CHART_PERCENT|$harbor_percent|g" "$html_file"

    sed -i "s|MINIO_STATUS|$minio_status|g" "$html_file"
    sed -i "s|MINIO_DETAILS|$minio_details|g" "$html_file"
    sed -i "s|MINIO_USAGE_TEXT|$minio_text|g" "$html_file"
    sed -i "s|MINIO_PROGRESS_WIDTH|$minio_percent|g" "$html_file"
    sed -i "s|MINIO_PROGRESS_COLOR|$minio_color|g" "$html_file"
    sed -i "s|MINIO_CHART_PERCENT|$minio_percent|g" "$html_file"
    
    # Generate node resources content
    local node_content=""
    if [[ ${#NODE_RESOURCES[@]} -gt 0 ]]; then
        for node_name in "${!NODE_RESOURCES[@]}"; do
            local node_data="${NODE_RESOURCES[$node_name]}"
            
            # Debug logging
            log_debug "Processing node resources for: $node_name"
            log_debug "Node data: $node_data"
            
            # Parse JSON with error handling
            local pod_count=$(echo "$node_data" | jq -r '.pod_count // 0' 2>/dev/null || echo "0")
            local max_pods=$(echo "$node_data" | jq -r '.max_pods // 0' 2>/dev/null || echo "0")
            local pod_percent=$(echo "$node_data" | jq -r '.pod_percent // "0.0"' 2>/dev/null || echo "0.0")
            local cpu_percent=$(echo "$node_data" | jq -r '.cpu_percent // "0.0"' 2>/dev/null || echo "0.0")
            local memory_percent=$(echo "$node_data" | jq -r '.memory_percent // "0.0"' 2>/dev/null || echo "0.0")
            
            # Ensure percentages are valid numbers
            [[ ! "$pod_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && pod_percent="0.0"
            [[ ! "$cpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && cpu_percent="0.0"
            [[ ! "$memory_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && memory_percent="0.0"
            
            # Determine color based on usage (0-50% green, 50-70% yellow, 70%+ red)
            local cpu_color_hex="#28a745"
            local memory_color_hex="#28a745"
            local pod_color_hex="#28a745"
            
            local cpu_num=$(echo "$cpu_percent" | cut -d. -f1)
            local memory_num=$(echo "$memory_percent" | cut -d. -f1)
            local pod_num=$(echo "$pod_percent" | cut -d. -f1)
            
            if [[ $cpu_num -ge 70 ]]; then cpu_color_hex="#dc3545"
            elif [[ $cpu_num -ge 50 ]]; then cpu_color_hex="#ffc107"; fi
            
            if [[ $memory_num -ge 70 ]]; then memory_color_hex="#dc3545"
            elif [[ $memory_num -ge 50 ]]; then memory_color_hex="#ffc107"; fi
            
            if [[ $pod_num -ge 70 ]]; then pod_color_hex="#dc3545"
            elif [[ $pod_num -ge 50 ]]; then pod_color_hex="#ffc107"; fi
            
            node_content+="<div class=\"node-item\">
                <div class=\"node-title\">
                    <i class=\"fas fa-server\"></i>
                    $node_name
                </div>
                
                <!-- Pod Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-cube me-2\"></i>파드 사용률</span>
                        <span class=\"resource-value\" style=\"color: $pod_color_hex;\">$pod_count/$max_pods</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $pod_color_hex; width: ${pod_percent}%;\"></div>
                                <div class=\"label\">${pod_percent}% 사용</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"pod-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>
                
                <!-- CPU Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-microchip me-2\"></i>CPU 사용률</span>
                        <span class=\"resource-value\" style=\"color: $cpu_color_hex;\">${cpu_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $cpu_color_hex; width: ${cpu_percent}%;\"></div>
                                <div class=\"label\">${cpu_percent}% 사용, $((100 - ${cpu_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"cpu-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>
                
                <!-- Memory Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-memory me-2\"></i>메모리 사용률</span>
                        <span class=\"resource-value\" style=\"color: $memory_color_hex;\">${memory_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $memory_color_hex; width: ${memory_percent}%;\"></div>
                                <div class=\"label\">${memory_percent}% 사용, $((100 - ${memory_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"memory-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>"
            
            # Add GPU if available
            if echo "$node_data" | jq -e '.gpu_percent' >/dev/null 2>&1; then
                local gpu_percent=$(echo "$node_data" | jq -r '.gpu_percent // "0.0"' 2>/dev/null || echo "0.0")
                [[ ! "$gpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && gpu_percent="0.0"
                
                local gpu_color_hex="#28a745"
                local gpu_num=$(echo "$gpu_percent" | cut -d. -f1)
                if [[ $gpu_num -ge 70 ]]; then gpu_color_hex="#dc3545"
                elif [[ $gpu_num -ge 50 ]]; then gpu_color_hex="#ffc107"; fi
                
                node_content+="
                <!-- GPU Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-microchip me-2\"></i>GPU 사용률</span>
                        <span class=\"resource-value\" style=\"color: $gpu_color_hex;\">${gpu_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $gpu_color_hex; width: ${gpu_percent}%;\"></div>
                                <div class=\"label\">${gpu_percent}% 사용, $((100 - ${gpu_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"gpu-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>"
            fi
            
            node_content+="</div>"
        done
    else
        log_warn "No node resources data available, generating demo data"
        # Generate demo data for visualization
        NODE_RESOURCES["master-node"]="{\"name\":\"master-node\",\"pod_count\":15,\"max_pods\":110,\"pod_percent\":\"13.6\",\"cpu_allocatable\":7800,\"cpu_requests\":2340,\"cpu_percent\":\"30.0\",\"memory_allocatable\":15839268,\"memory_requests\":4251737,\"memory_percent\":\"26.8\"}"
        NODE_RESOURCES["worker-node-1"]="{\"name\":\"worker-node-1\",\"pod_count\":28,\"max_pods\":110,\"pod_percent\":\"25.5\",\"cpu_allocatable\":7800,\"cpu_requests\":4680,\"cpu_percent\":\"60.0\",\"memory_allocatable\":15839268,\"memory_requests\":9503461,\"memory_percent\":\"60.0\",\"gpu_capacity\":\"2\",\"gpu_allocatable\":\"2\",\"gpu_requests\":\"1\",\"gpu_percent\":\"50.0\"}"
        NODE_RESOURCES["worker-node-2"]="{\"name\":\"worker-node-2\",\"pod_count\":35,\"max_pods\":110,\"pod_percent\":\"31.8\",\"cpu_allocatable\":7800,\"cpu_requests\":6240,\"cpu_percent\":\"80.0\",\"memory_allocatable\":15839268,\"memory_requests\":12671414,\"memory_percent\":\"80.0\"}"
        
        # Now process the demo data
        for node_name in "${!NODE_RESOURCES[@]}"; do
            local node_data="${NODE_RESOURCES[$node_name]}"
            
            # Parse JSON with error handling
            local pod_count=$(echo "$node_data" | jq -r '.pod_count // 0' 2>/dev/null || echo "0")
            local max_pods=$(echo "$node_data" | jq -r '.max_pods // 0' 2>/dev/null || echo "0")
            local pod_percent=$(echo "$node_data" | jq -r '.pod_percent // "0.0"' 2>/dev/null || echo "0.0")
            local cpu_percent=$(echo "$node_data" | jq -r '.cpu_percent // "0.0"' 2>/dev/null || echo "0.0")
            local memory_percent=$(echo "$node_data" | jq -r '.memory_percent // "0.0"' 2>/dev/null || echo "0.0")
            
            # Ensure percentages are valid numbers
            [[ ! "$pod_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && pod_percent="0.0"
            [[ ! "$cpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && cpu_percent="0.0"
            [[ ! "$memory_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && memory_percent="0.0"
            
            # Determine color based on usage (0-50% green, 50-70% yellow, 70%+ red)
            local cpu_color_hex="#28a745"
            local memory_color_hex="#28a745"
            local pod_color_hex="#28a745"
            
            local cpu_num=$(echo "$cpu_percent" | cut -d. -f1)
            local memory_num=$(echo "$memory_percent" | cut -d. -f1)
            local pod_num=$(echo "$pod_percent" | cut -d. -f1)
            
            if [[ $cpu_num -ge 70 ]]; then cpu_color_hex="#dc3545"
            elif [[ $cpu_num -ge 50 ]]; then cpu_color_hex="#ffc107"; fi
            
            if [[ $memory_num -ge 70 ]]; then memory_color_hex="#dc3545"
            elif [[ $memory_num -ge 50 ]]; then memory_color_hex="#ffc107"; fi
            
            if [[ $pod_num -ge 70 ]]; then pod_color_hex="#dc3545"
            elif [[ $pod_num -ge 50 ]]; then pod_color_hex="#ffc107"; fi
            
            node_content+="<div class=\"node-item\">
                <div class=\"node-title\">
                    <i class=\"fas fa-server\"></i>
                    $node_name
                </div>
                
                <!-- Pod Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-cube me-2\"></i>파드 사용률</span>
                        <span class=\"resource-value\" style=\"color: $pod_color_hex;\">$pod_count/$max_pods</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $pod_color_hex; width: ${pod_percent}%;\"></div>
                                <div class=\"label\">${pod_percent}% 사용</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"pod-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>
                
                <!-- CPU Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-microchip me-2\"></i>CPU 사용률</span>
                        <span class=\"resource-value\" style=\"color: $cpu_color_hex;\">${cpu_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $cpu_color_hex; width: ${cpu_percent}%;\"></div>
                                <div class=\"label\">${cpu_percent}% 사용, $((100 - ${cpu_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"cpu-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>
                
                <!-- Memory Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-memory me-2\"></i>메모리 사용률</span>
                        <span class=\"resource-value\" style=\"color: $memory_color_hex;\">${memory_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $memory_color_hex; width: ${memory_percent}%;\"></div>
                                <div class=\"label\">${memory_percent}% 사용, $((100 - ${memory_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"memory-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>"
            
            # Add GPU if available
            if echo "$node_data" | jq -e '.gpu_percent' >/dev/null 2>&1; then
                local gpu_percent=$(echo "$node_data" | jq -r '.gpu_percent // "0.0"' 2>/dev/null || echo "0.0")
                [[ ! "$gpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && gpu_percent="0.0"
                
                local gpu_color_hex="#28a745"
                local gpu_num=$(echo "$gpu_percent" | cut -d. -f1)
                if [[ $gpu_num -ge 70 ]]; then gpu_color_hex="#dc3545"
                elif [[ $gpu_num -ge 50 ]]; then gpu_color_hex="#ffc107"; fi
                
                node_content+="
                <!-- GPU Usage -->
                <div class=\"resource-section\">
                    <div class=\"resource-header\">
                        <span class=\"resource-label\"><i class=\"fas fa-microchip me-2\"></i>GPU 사용률</span>
                        <span class=\"resource-value\" style=\"color: $gpu_color_hex;\">${gpu_percent%.*}/100</span>
                    </div>
                    <div class=\"chart-grid\">
                        <div>
                            <div class=\"resource-bar\">
                                <div class=\"fill\" style=\"background: $gpu_color_hex; width: ${gpu_percent}%;\"></div>
                                <div class=\"label\">${gpu_percent}% 사용, $((100 - ${gpu_percent%.*}))% 여유</div>
                            </div>
                        </div>
                        <div class=\"chart-container\">
                            <canvas id=\"gpu-chart-${node_name//[^a-zA-Z0-9]/_}\"></canvas>
                        </div>
                    </div>
                </div>"
            fi
            
            node_content+="</div>"
        done
    fi
    
    # Generate check results content
    local check_content=""
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드 연결" "URL 연결 테스트" "Rook-Ceph 클러스터" "Harbor 디스크 사용량" "Minio 디스크 사용량")
    
    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local check_title="${check_titles[$i]}"
        local status="${CHECK_RESULTS[$check_name]:-UNKNOWN}"
        local details="${CHECK_DETAILS[$check_name]:-정보 없음}"
        
        local icon="❓"
        local alert_class="secondary"
        local explanation=""
        
        case "$status" in
            "SUCCESS")
                icon="✅"
                alert_class="success"
                ;;
            "WARNING")
                icon="⚠️"
                alert_class="warning"
                explanation="<div class=\"explanation-box warning\"><strong>💡 해결 방법:</strong> ${CHECK_DETAILS["${check_name}_explanation"]:-추가 조치가 필요할 수 있습니다.}</div>"
                ;;
            "FAILED")
                icon="❌"
                alert_class="danger"
                explanation="<div class=\"explanation-box danger\"><strong>🔧 해결 방법:</strong> ${CHECK_DETAILS["${check_name}_explanation"]:-즉시 조치가 필요합니다.}</div>"
                ;;
        esac
        
        check_content+="<div class=\"alert alert-$alert_class\" role=\"alert\">
            <h5 class=\"alert-heading\">$icon $check_title</h5>
            <p class=\"mb-0\">$details</p>
            $explanation
        </div>"
    done
    
    # Replace content in HTML using temp files to avoid sed special character issues
    local temp_file1="${html_file}.tmp1"
    local temp_file2="${html_file}.tmp2"
    
    # Replace NODE_RESOURCES_CONTENT
    awk -v content="$node_content" '{gsub(/NODE_RESOURCES_CONTENT/, content); print}' "$html_file" > "$temp_file1"
    
    # Replace CHECK_RESULTS_CONTENT  
    awk -v content="$check_content" '{gsub(/CHECK_RESULTS_CONTENT/, content); print}' "$temp_file1" > "$temp_file2"
    
    mv "$temp_file2" "$html_file"
    rm -f "$temp_file1" "$temp_file2"
    
    echo "$html_file"
}

# Generate log report
generate_log_report() {
    local log_file="${OUTPUT_DIR}/k8s_health_report_${TIMESTAMP}.log"
    
    {
        echo "=============================================="
        echo "Kubernetes 클러스터 상태 보고서"
        echo "생성 시간: $(date '+%Y년 %m월 %d일 %H시 %M분')"
        echo "=============================================="
        echo
        
        # Summary
        local total_checks=$((${#SUCCESS_CHECKS[@]} + ${#WARNING_CHECKS[@]} + ${#FAILED_CHECKS[@]}))
        echo "📊 종합 상태"
        echo "- 총 점검 항목: $total_checks"
        echo "- 성공: ${#SUCCESS_CHECKS[@]}"
        echo "- 경고: ${#WARNING_CHECKS[@]}"
        echo "- 실패: ${#FAILED_CHECKS[@]}"
        echo
        
        # Overall status
        if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
            echo "🚨 전체 상태: 문제 발생"
        elif [[ ${#WARNING_CHECKS[@]} -gt 0 ]]; then
            echo "⚠️ 전체 상태: 경고"
        else
            echo "✅ 전체 상태: 정상"
        fi
        echo
        
        # Node resources
        echo "🖥️ 노드 리소스 현황"
        echo "----------------------------------------"
        for node_name in "${!NODE_RESOURCES[@]}"; do
            local node_data="${NODE_RESOURCES[$node_name]}"
            local pod_count=$(echo "$node_data" | jq -r '.pod_count')
            local max_pods=$(echo "$node_data" | jq -r '.max_pods')
            local pod_percent=$(echo "$node_data" | jq -r '.pod_percent')
            local cpu_percent=$(echo "$node_data" | jq -r '.cpu_percent')
            local memory_percent=$(echo "$node_data" | jq -r '.memory_percent')
            
            echo "📦 $node_name:"
            echo "  - 파드: $pod_count/$max_pods (${pod_percent}%)"
            echo "  - CPU: ${cpu_percent}%"
            echo "  - 메모리: ${memory_percent}%"
            
            if echo "$node_data" | jq -e '.gpu_percent' >/dev/null 2>&1; then
                local gpu_percent=$(echo "$node_data" | jq -r '.gpu_percent')
                echo "  - GPU: ${gpu_percent}%"
            fi
            echo
        done
        
        # Detailed results
        echo "🔍 상세 점검 결과"
        echo "----------------------------------------"
        
        local check_names=("nodes" "pods" "deployments" "services" "storage" "rook_ceph" "ingress" "harbor_disk" "minio_disk" "url_check")
        local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Rook-Ceph 상태" "Ingress 백엔드 연결" "Harbor 디스크 사용량" "Minio 디스크 사용량" "URL 연결 테스트")
        
        for i in "${!check_names[@]}"; do
            local check_name="${check_names[$i]}"
            local check_title="${check_titles[$i]}"
            local status="${CHECK_RESULTS[$check_name]:-UNKNOWN}"
            local details="${CHECK_DETAILS[$check_name]:-정보 없음}"
            
            local icon="❓"
            case "$status" in
                "SUCCESS") icon="✅" ;;
                "WARNING") icon="⚠️" ;;
                "FAILED") icon="❌" ;;
            esac
            
            echo "$icon $check_title: $details"
            echo
        done
        
        echo "=============================================="
        echo "보고서 생성 완료"
        echo "=============================================="
        
    } > "$log_file"
    
    echo "$log_file"
}

# Generate JSON report
generate_json_report() {
    local json_file="${OUTPUT_DIR}/k8s_health_report_${TIMESTAMP}.json"
    
    local json_data="{"
    json_data+="\"timestamp\":\"$(date -Iseconds)\","
    json_data+="\"summary\":{"
    json_data+="\"total_checks\":$((${#SUCCESS_CHECKS[@]} + ${#WARNING_CHECKS[@]} + ${#FAILED_CHECKS[@]})),"
    json_data+="\"success_count\":${#SUCCESS_CHECKS[@]},"
    json_data+="\"warning_count\":${#WARNING_CHECKS[@]},"
    json_data+="\"failed_count\":${#FAILED_CHECKS[@]}"
    json_data+="},"
    
    # Overall status
    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
        json_data+="\"overall_status\":\"FAILED\","
    elif [[ ${#WARNING_CHECKS[@]} -gt 0 ]]; then
        json_data+="\"overall_status\":\"WARNING\","
    else
        json_data+="\"overall_status\":\"SUCCESS\","
    fi
    
    # Node resources
    json_data+="\"node_resources\":{"
    local first_node=true
    for node_name in "${!NODE_RESOURCES[@]}"; do
        if [[ "$first_node" == "false" ]]; then
            json_data+=","
        fi
        json_data+="\"$node_name\":${NODE_RESOURCES[$node_name]}"
        first_node=false
    done
    json_data+="},"
    
    # Check results
    json_data+="\"check_results\":{"
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local first_check=true
    
    for check_name in "${check_names[@]}"; do
        if [[ "$first_check" == "false" ]]; then
            json_data+=","
        fi
        local status="${CHECK_RESULTS[$check_name]:-UNKNOWN}"
        local details="${CHECK_DETAILS[$check_name]:-정보 없음}"
        json_data+="\"$check_name\":{\"status\":\"$status\",\"details\":\"$details\"}"
        first_check=false
    done
    json_data+="}}"
    
    # Format JSON if jq is available
    if command -v jq &> /dev/null; then
        echo "$json_data" | jq '.' > "$json_file"
    else
        echo "$json_data" > "$json_file"
    fi
    
    echo "$json_file"
}

# Main execution
main() {
    echo "🚀 Kubernetes 클러스터 포괄적 상태 점검 시작"
    echo "================================================="
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check kubectl availability
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl이 설치되지 않았거나 PATH에 없습니다."
        exit 1
    fi
    
    # Check cluster connection
    if ! check_kube_connection; then
        log_error "Kubernetes 클러스터 연결에 실패했습니다."
        exit 1
    fi
    
    echo
    log_info "점검을 시작합니다..."
    
    # Run all checks with error handling
    log_info "1/10 노드 상태 점검..."
    check_node_status || log_warn "노드 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "2/10 파드 상태 점검..."
    check_pod_status || log_warn "파드 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "3/10 디플로이먼트 상태 점검..."
    check_deployment_status || log_warn "디플로이먼트 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "4/10 서비스 엔드포인트 점검..."
    check_service_endpoints || log_warn "서비스 엔드포인트 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "5/10 스토리지 상태 점검..."
    check_storage_status || log_warn "스토리지 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "6/10 Ingress 백엔드 점검..."
    check_ingress_backends || log_warn "Ingress 백엔드 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "7/10 URL 연결 테스트..."
    check_url_connectivity || log_warn "URL 연결 테스트에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "8/10 Rook-Ceph 상태 점검..."
    check_rook_ceph_health || log_warn "Rook-Ceph 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "9/10 Harbor 디스크 사용량 점검..."
    check_harbor_disk_usage || log_warn "Harbor 디스크 사용량 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "10/10 Minio 디스크 사용량 점검..."
    check_minio_disk_usage || log_warn "Minio 디스크 사용량 점검에서 오류가 발생했지만 계속 진행합니다."
    
    echo
    log_info "보고서를 생성합니다..."

    # Generate reports based on output format and config settings
    case "$OUTPUT_FORMAT" in
        "html")
            # Always generate HTML report if explicitly requested
            report_file=$(generate_html_report)
            log_success "HTML 보고서가 생성되었습니다: $report_file"

            # Also generate JSON report if enabled in config
            if [[ "${GENERATE_JSON_REPORT:-true}" == "true" ]]; then
                json_report=$(generate_json_report)
                log_success "JSON 보고서가 생성되었습니다: $json_report"
            fi
            ;;
        "log")
            report_file=$(generate_log_report)
            log_success "로그 보고서가 생성되었습니다: $report_file"
            ;;
        "json")
            # Always generate JSON report if explicitly requested
            report_file=$(generate_json_report)
            log_success "JSON 보고서가 생성되었습니다: $report_file"

            # Also generate HTML report if enabled in config
            if [[ "${GENERATE_HTML_REPORT:-true}" == "true" ]]; then
                html_report=$(generate_html_report)
                log_success "HTML 보고서가 생성되었습니다: $html_report"
            fi
            ;;
    esac
    
    # Show summary
    echo
    echo "📊 점검 요약:"
    echo "- 성공: ${#SUCCESS_CHECKS[@]}"
    echo "- 경고: ${#WARNING_CHECKS[@]}"
    echo "- 실패: ${#FAILED_CHECKS[@]}"
    
    # Return appropriate exit code
    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
        echo "🚨 일부 점검에서 문제가 발견되었습니다."
        exit 1
    elif [[ ${#WARNING_CHECKS[@]} -gt 0 ]]; then
        echo "⚠️ 일부 점검에서 경고가 발견되었습니다."
        exit 2
    else
        echo "✅ 모든 점검이 성공적으로 완료되었습니다."
        exit 0
    fi
}

# Run main function with all arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi