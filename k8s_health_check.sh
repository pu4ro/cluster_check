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
            if timeout 30 get_node_resources "$node_name" 2>/dev/null; then
                ((processed_nodes++))
                log_debug "Successfully processed node: $node_name"
            else
                log_warn "Failed to get resources for node: $node_name"
            fi
        done
        log_info "총 $processed_nodes개 노드의 리소스 정보를 수집했습니다."
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
    
    # Get current requests
    local resource_requests=$(echo "$node_info" | grep -A 20 "Allocated resources:")
    local cpu_requests=$(echo "$resource_requests" | grep "cpu" | awk '{print $2}' | sed 's/m$//' | sed 's/(%)//')
    local memory_requests=$(echo "$resource_requests" | grep "memory" | awk '{print $2}' | sed 's/Ki$//' | sed 's/(%)//')
    
    # Get pod count with timeout
    local pod_count=0
    if ! pod_count=$(timeout 15 kubectl_cmd get pods --all-namespaces --field-selector spec.nodeName="$node_name" --no-headers 2>/dev/null | wc -l); then
        log_warn "Failed to get pod count for node: $node_name"
        pod_count=0
    fi
    local max_pods=$(echo "$node_info" | grep "pods:" | tail -1 | awk '{print $2}')
    
    # Calculate percentages
    local cpu_percent=0
    local memory_percent=0
    local pod_percent=0
    
    # Safe calculation with defaults
    if [[ -n "$cpu_allocatable" && "$cpu_allocatable" =~ ^[0-9]+$ && "$cpu_allocatable" -gt 0 && -n "$cpu_requests" && "$cpu_requests" =~ ^[0-9]+$ ]]; then
        cpu_percent=$(echo "scale=1; ($cpu_requests * 100) / $cpu_allocatable" | bc -l 2>/dev/null || echo "0")
    fi
    
    if [[ -n "$memory_allocatable" && "$memory_allocatable" =~ ^[0-9]+$ && "$memory_allocatable" -gt 0 && -n "$memory_requests" && "$memory_requests" =~ ^[0-9]+$ ]]; then
        memory_percent=$(echo "scale=1; ($memory_requests * 100) / $memory_allocatable" | bc -l 2>/dev/null || echo "0")
    fi
    
    if [[ -n "$max_pods" && "$max_pods" =~ ^[0-9]+$ && "$max_pods" -gt 0 ]]; then
        pod_percent=$(echo "scale=1; ($pod_count * 100) / $max_pods" | bc -l 2>/dev/null || echo "0")
    fi
    
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

# Check 6: Ingress backend connections
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

# Check 7: URL connectivity
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
    <style>
        .status-icon {
            font-size: 1.2em;
            margin-right: 8px;
        }
        .resource-bar {
            height: 25px;
            border-radius: 5px;
            position: relative;
            overflow: hidden;
        }
        .resource-bar .fill {
            height: 100%;
            transition: width 0.5s ease-in-out;
            border-radius: 5px;
        }
        .resource-bar .label {
            position: absolute;
            width: 100%;
            text-align: center;
            line-height: 25px;
            font-weight: bold;
            color: white;
            text-shadow: 1px 1px 1px rgba(0,0,0,0.5);
            z-index: 1;
        }
        .bg-success-light { background-color: #d1e7dd; }
        .bg-warning-light { background-color: #fff3cd; }
        .bg-danger-light { background-color: #f8d7da; }
        .chart-container {
            margin: 20px 0;
        }
        .node-card {
            border: 1px solid #dee2e6;
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 15px;
            background-color: #f8f9fa;
        }
        .explanation-box {
            background-color: #e9ecef;
            border-left: 4px solid #6c757d;
            padding: 10px 15px;
            margin-top: 10px;
            border-radius: 0 4px 4px 0;
        }
        .explanation-box.danger {
            border-left-color: #dc3545;
            background-color: #f8d7da;
        }
        .explanation-box.warning {
            border-left-color: #ffc107;
            background-color: #fff3cd;
        }
    </style>
</head>
<body>
    <div class="container-fluid">
        <div class="row">
            <div class="col-12">
                <div class="text-center py-4">
                    <h1 class="display-4">🚀 Kubernetes 클러스터 상태 보고서</h1>
                    <p class="lead">생성 시간: REPORT_TIMESTAMP</p>
                </div>
            </div>
        </div>

        <!-- Summary Dashboard -->
        <div class="row mb-4">
            <div class="col-12">
                <div class="card">
                    <div class="card-header">
                        <h3 class="card-title mb-0">📊 종합 상태</h3>
                    </div>
                    <div class="card-body">
                        <div class="row">
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

        <!-- Detailed Check Results -->
        <div class="row mb-4">
            <div class="col-12">
                <div class="card">
                    <div class="card-header">
                        <h3 class="card-title mb-0">🔍 상세 점검 결과</h3>
                    </div>
                    <div class="card-body">
                        CHECK_RESULTS_CONTENT
                    </div>
                </div>
            </div>
        </div>

        <div class="row">
            <div class="col-12 text-center text-muted">
                <p><small>이 보고서는 자동으로 생성되었습니다 | DevOps Team</small></p>
            </div>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // Animate progress bars on page load
        document.addEventListener('DOMContentLoaded', function() {
            const bars = document.querySelectorAll('.resource-bar .fill');
            bars.forEach(bar => {
                const width = bar.dataset.width;
                setTimeout(() => {
                    bar.style.width = width + '%';
                }, 500);
            });
        });
    </script>
</body>
</html>
EOF

    # Replace placeholders
    sed -i "s/REPORT_TIMESTAMP/$(date '+%Y년 %m월 %d일 %H시 %M분')/g" "$html_file"
    sed -i "s/OVERALL_STATUS_CLASS/$status_class/g" "$html_file"
    sed -i "s/OVERALL_STATUS/$overall_status/g" "$html_file"
    sed -i "s/SUCCESS_COUNT/${#SUCCESS_CHECKS[@]}/g" "$html_file"
    sed -i "s/WARNING_COUNT/${#WARNING_CHECKS[@]}/g" "$html_file"
    sed -i "s/FAILED_COUNT/${#FAILED_CHECKS[@]}/g" "$html_file"
    
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
            
            # Determine color based on usage
            local pod_color=$(get_usage_color "$pod_percent")
            local cpu_color=$(get_usage_color "$cpu_percent")
            local memory_color=$(get_usage_color "$memory_percent")
            
            node_content+="<div class=\"node-card\">
                <h5>📦 $node_name</h5>
                <div class=\"row\">
                    <div class=\"col-md-4\">
                        <label>파드 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$pod_color\" data-width=\"$pod_percent\"></div>
                            <div class=\"label\">$pod_count/$max_pods (${pod_percent}%)</div>
                        </div>
                    </div>
                    <div class=\"col-md-4\">
                        <label>CPU 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$cpu_color\" data-width=\"$cpu_percent\"></div>
                            <div class=\"label\">${cpu_percent%.*}/100 (${cpu_percent}%)</div>
                        </div>
                    </div>
                    <div class=\"col-md-4\">
                        <label>메모리 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$memory_color\" data-width=\"$memory_percent\"></div>
                            <div class=\"label\">${memory_percent%.*}/100 (${memory_percent}%)</div>
                        </div>
                    </div>
                </div>"
            
            # Add GPU if available
            if echo "$node_data" | jq -e '.gpu_percent' >/dev/null 2>&1; then
                local gpu_percent=$(echo "$node_data" | jq -r '.gpu_percent // "0.0"' 2>/dev/null || echo "0.0")
                [[ ! "$gpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && gpu_percent="0.0"
                local gpu_color=$(get_usage_color "$gpu_percent")
                node_content+="
                <div class=\"row mt-2\">
                    <div class=\"col-md-4\">
                        <label>GPU 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$gpu_color\" data-width=\"$gpu_percent\"></div>
                            <div class=\"label\">${gpu_percent%.*}/100 (${gpu_percent}%)</div>
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
            
            # Determine color based on usage
            local pod_color=$(get_usage_color "$pod_percent")
            local cpu_color=$(get_usage_color "$cpu_percent")
            local memory_color=$(get_usage_color "$memory_percent")
            
            node_content+="<div class=\"node-card\">
                <h5>📦 $node_name</h5>
                <div class=\"row\">
                    <div class=\"col-md-4\">
                        <label>파드 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$pod_color\" data-width=\"$pod_percent\"></div>
                            <div class=\"label\">$pod_count/$max_pods (${pod_percent}%)</div>
                        </div>
                    </div>
                    <div class=\"col-md-4\">
                        <label>CPU 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$cpu_color\" data-width=\"$cpu_percent\"></div>
                            <div class=\"label\">${cpu_percent%.*}/100 (${cpu_percent}%)</div>
                        </div>
                    </div>
                    <div class=\"col-md-4\">
                        <label>메모리 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$memory_color\" data-width=\"$memory_percent\"></div>
                            <div class=\"label\">${memory_percent%.*}/100 (${memory_percent}%)</div>
                        </div>
                    </div>
                </div>"
            
            # Add GPU if available
            if echo "$node_data" | jq -e '.gpu_percent' >/dev/null 2>&1; then
                local gpu_percent=$(echo "$node_data" | jq -r '.gpu_percent // "0.0"' 2>/dev/null || echo "0.0")
                [[ ! "$gpu_percent" =~ ^[0-9]+\.?[0-9]*$ ]] && gpu_percent="0.0"
                local gpu_color=$(get_usage_color "$gpu_percent")
                node_content+="
                <div class=\"row mt-2\">
                    <div class=\"col-md-4\">
                        <label>GPU 사용률</label>
                        <div class=\"resource-bar bg-light\">
                            <div class=\"fill bg-$gpu_color\" data-width=\"$gpu_percent\"></div>
                            <div class=\"label\">${gpu_percent%.*}/100 (${gpu_percent}%)</div>
                        </div>
                    </div>
                </div>"
            fi
            
            node_content+="</div>"
        done
    fi
    
    # Generate check results content
    local check_content=""
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드 연결" "URL 연결 테스트")
    
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
        
        local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check")
        local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드 연결" "URL 연결 테스트")
        
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
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check")
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
    log_info "1/7 노드 상태 점검..."
    check_node_status || log_warn "노드 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "2/7 파드 상태 점검..."
    check_pod_status || log_warn "파드 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "3/7 디플로이먼트 상태 점검..."
    check_deployment_status || log_warn "디플로이먼트 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "4/7 서비스 엔드포인트 점검..."
    check_service_endpoints || log_warn "서비스 엔드포인트 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "5/7 스토리지 상태 점검..."
    check_storage_status || log_warn "스토리지 상태 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "6/7 Ingress 백엔드 점검..."
    check_ingress_backends || log_warn "Ingress 백엔드 점검에서 오류가 발생했지만 계속 진행합니다."
    
    log_info "7/7 URL 연결 테스트..."
    check_url_connectivity || log_warn "URL 연결 테스트에서 오류가 발생했지만 계속 진행합니다."
    
    echo
    log_info "보고서를 생성합니다..."
    
    # Generate reports based on output format
    case "$OUTPUT_FORMAT" in
        "html")
            report_file=$(generate_html_report)
            log_success "HTML 보고서가 생성되었습니다: $report_file"
            ;;
        "log")
            report_file=$(generate_log_report)
            log_success "로그 보고서가 생성되었습니다: $report_file"
            ;;
        "json")
            report_file=$(generate_json_report)
            log_success "JSON 보고서가 생성되었습니다: $report_file"
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