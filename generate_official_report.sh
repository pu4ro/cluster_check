#!/bin/bash

# Kubernetes 클러스터 및 Runway 플랫폼 기술 점검 공식 보고서 생성
# 한국수자원공사(K-water) 공공기관용 보고서
# Author: DevOps Team
# Version: 1.0.0

set -e

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
JSON_INPUT=""
REPORT_DATE=$(date +%Y-%m-%d)

# Load .env file if exists
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    source "${SCRIPT_DIR}/.env"
    echo "Loaded configuration from .env file"
fi

# Set default values (can be overridden by .env or command line)
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/reports}"
REPORT_VERSION="${REPORT_VERSION:-1.0}"
AUTHOR_NAME="${AUTHOR_NAME:-기술운영팀}"
ORGANIZATION="${ORGANIZATION:-}"
REPORT_DATE="${REPORT_DATE:-$(date +%Y-%m-%d)}"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-5}"
ENABLE_GPU_MONITORING="${ENABLE_GPU_MONITORING:-true}"
ENABLE_PDF_CONVERT="${ENABLE_PDF_CONVERT:-false}"
PDF_BUILD_MODE="${PDF_BUILD_MODE:-online}"        # online|offline
PDF_DOCKER_IMAGE="${PDF_DOCKER_IMAGE:-k8s-report-pdf:latest}"

# Inspection confirmation info (for cover page)
INSPECTOR_NAME="${INSPECTOR_NAME:-}"
INSPECTOR_DEPT="${INSPECTOR_DEPT:-}"
MANAGER_NAME="${MANAGER_NAME:-}"
MANAGER_DEPT="${MANAGER_DEPT:-}"

# Runway platform defaults (can be set in .env)
RUNWAY_VERSION_OVERRIDE="${RUNWAY_VERSION:-}"
RUNWAY_INSTALLED_OVERRIDE="${RUNWAY_INSTALLED:-}"

# Kubernetes cluster defaults (can be set in .env)
K8S_VERSION_OVERRIDE="${K8S_VERSION:-}"
CNI_TYPE_OVERRIDE="${CNI_TYPE:-}"
GPU_OPERATOR_STATUS_OVERRIDE="${GPU_OPERATOR_STATUS:-}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Usage function
show_usage() {
    cat << EOF
사용법: $0 [옵션]

옵션:
    --json FILE             입력 JSON 파일 경로 (기본값: 자동 생성)
    --org NAME              기관명 (기본값: 한국수자원공사)
    --author NAME           작성자명 (기본값: 기술운영팀)
    --version VER           문서 버전 (기본값: 1.0)
    --help                  이 도움말 표시

사용 예시:
    # 자동으로 클러스터 점검 및 보고서 생성
    $0

    # 기존 JSON 파일로 보고서 생성
    $0 --json reports/k8s_health_report_20250120_120000.json

    # 기관명 및 작성자 지정
    $0 --org "한국수자원공사" --author "김철수"

EOF
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                JSON_INPUT="$2"
                shift 2
                ;;
            --org)
                ORGANIZATION="$2"
                shift 2
                ;;
            --author)
                AUTHOR_NAME="$2"
                shift 2
                ;;
            --version)
                REPORT_VERSION="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Run health check if JSON not provided
run_health_check() {
    log_info "클러스터 상태 점검을 시작합니다..."

    if [[ ! -f "${SCRIPT_DIR}/k8s_health_check.sh" ]]; then
        log_error "k8s_health_check.sh 스크립트를 찾을 수 없습니다."
        exit 1
    fi

    # Run health check in JSON mode
    # Use --interactive only if running in a terminal
    local interactive_flag=""
    if [[ -t 0 ]]; then
        interactive_flag="--interactive"
    fi
    bash "${SCRIPT_DIR}/k8s_health_check.sh" --output json $interactive_flag

    # Find the latest JSON file
    JSON_INPUT=$(ls -t "${OUTPUT_DIR}"/k8s_health_report_*.json 2>/dev/null | head -1)

    if [[ -z "$JSON_INPUT" || ! -f "$JSON_INPUT" ]]; then
        log_error "JSON 보고서 파일을 찾을 수 없습니다."
        exit 1
    fi

    log_success "점검 완료: $JSON_INPUT"
}

find_latest_health_report() {
    ls -t "${OUTPUT_DIR}"/k8s_health_report_*.json 2>/dev/null | head -1 || true
}

ensure_json_input() {
    # 1) 사용자가 직접 지정한 JSON을 우선
    if [[ -n "$JSON_INPUT" ]]; then
        if [[ ! -f "$JSON_INPUT" ]]; then
            log_error "JSON 파일을 찾을 수 없습니다: $JSON_INPUT"
            exit 1
        fi
        log_info "제공된 JSON 파일을 사용합니다: $JSON_INPUT"
        return
    fi

    # 2) 최신 k8s_health_report_* JSON 자동 탐색
    local latest_json
    latest_json=$(find_latest_health_report)
    if [[ -n "$latest_json" && -f "$latest_json" ]]; then
        JSON_INPUT="$latest_json"
        log_info "가장 최근 점검 JSON을 사용합니다: $JSON_INPUT"
        return
    fi

    # 3) 없으면 새 점검 실행
    log_info "기존 점검 JSON을 찾지 못했습니다. 새 점검을 실행합니다."
    run_health_check
}

ensure_pdf_docker_image() {
    if [[ "$PDF_BUILD_MODE" == "offline" ]]; then
        if docker image inspect "$PDF_DOCKER_IMAGE" >/dev/null 2>&1; then
            log_info "오프라인 모드: 기존 PDF 변환 이미지 사용: $PDF_DOCKER_IMAGE"
        else
            log_error "오프라인 모드이며 PDF 변환 이미지가 없습니다: $PDF_DOCKER_IMAGE"
            exit 1
        fi
        return
    fi

    log_info "온라인 모드: PDF 변환용 Docker 이미지를 빌드합니다: $PDF_DOCKER_IMAGE"
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/Dockerfile" <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends wkhtmltopdf ca-certificates fonts-noto-cjk && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /work
ENTRYPOINT ["wkhtmltopdf"]
DOCKERFILE

    docker build -t "$PDF_DOCKER_IMAGE" "$tmpdir"
    rm -rf "$tmpdir"
}

convert_html_to_pdf() {
    local html_file="$1"
    local pdf_file="${html_file%.html}.pdf"

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker를 찾을 수 없습니다. PDF 변환을 위해 docker를 설치하거나 ENABLE_PDF_CONVERT를 false로 설정하세요."
        return 1
    fi

    ensure_pdf_docker_image

    log_info "PDF 변환을 시작합니다: $html_file -> $pdf_file"
    if docker run --rm -v "${OUTPUT_DIR}:${OUTPUT_DIR}" -w "${OUTPUT_DIR}" "$PDF_DOCKER_IMAGE" \
        "$(basename "$html_file")" "$(basename "$pdf_file")"; then
        log_success "PDF 보고서가 생성되었습니다: $pdf_file"
    else
        log_warn "PDF 변환에 실패했습니다. wkhtmltopdf 명령을 직접 실행해주세요."
        return 1
    fi
}

# Collect Kubernetes cluster information
collect_cluster_info() {
    log_info "클러스터 정보를 수집합니다..."

    # Kubernetes version (with timeout, use override if set)
    if [[ -n "$K8S_VERSION_OVERRIDE" ]]; then
        K8S_VERSION="$K8S_VERSION_OVERRIDE"
    else
        K8S_VERSION=$(timeout $KUBECTL_TIMEOUT kubectl version --short 2>/dev/null | grep "Server Version" | cut -d':' -f2 | xargs 2>/dev/null || echo "확인 불가")
    fi

    # Cluster info (with timeout) - remove ANSI color codes
    CLUSTER_ENDPOINT=$(timeout $KUBECTL_TIMEOUT kubectl cluster-info 2>/dev/null | grep "control plane" | awk '{print $NF}' | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null || echo "확인 불가")

    # Node count and details (with timeout)
    NODE_COUNT=$(timeout $KUBECTL_TIMEOUT kubectl get nodes --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")

    # Optimized: Get detailed node information with data pre-fetching (75-85% faster)
    # Format: name|cpu|memory|max_pods|allocatable_mem|gpu_info|current_pods|memory_used_percent|disk_used_percent
    NODE_DETAILS=""

    # Fetch all data once to avoid repeated kubectl calls
    local all_nodes_json=$(timeout 10 kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')
    local all_pods_json=$(timeout 10 kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
    # Use Flannel DaemonSet pods for disk usage (available on all nodes)
    local all_flannel_pods=$(timeout 5 kubectl get pods -n kube-flannel -l app=flannel -o json 2>/dev/null || echo '{"items":[]}')

    local node_list=$(echo "$all_nodes_json" | jq -r '.items[].metadata.name' 2>/dev/null || echo "")

    for node_name in $node_list; do
        [[ -z "$node_name" ]] && continue

        # Extract node info from pre-fetched data
        local node_info=$(echo "$all_nodes_json" | jq ".items[] | select(.metadata.name==\"$node_name\")" 2>/dev/null)
        local cpu=$(echo "$node_info" | jq -r '.status.capacity.cpu' 2>/dev/null || echo "0")
        local memory=$(echo "$node_info" | jq -r '.status.capacity.memory' 2>/dev/null || echo "0Ki")
        local max_pods=$(echo "$node_info" | jq -r '.status.capacity.pods' 2>/dev/null || echo "0")
        local allocatable_mem=$(echo "$node_info" | jq -r '.status.allocatable.memory' 2>/dev/null || echo "0Ki")

        # Count pods on this node from pre-fetched data
        local current_pods=$(echo "$all_pods_json" | jq -r "[.items[] | select(.spec.nodeName==\"$node_name\")] | length" 2>/dev/null || echo "0")

        # Get describe node output once for both GPU and memory usage
        local describe_output=$(timeout 5 kubectl describe node "$node_name" 2>/dev/null || echo "")

        # Get GPU info (use comma as internal separator to avoid conflict with pipe delimiter)
        local gpu_info="0,0,N/A"
        if [[ "$ENABLE_GPU_MONITORING" == "true" ]]; then
            local gpu_capacity=$(echo "$node_info" | jq -r '.status.capacity."nvidia.com/gpu" // "0"' 2>/dev/null || echo "0")
            if [[ "$gpu_capacity" != "0" ]]; then
                # Get GPU allocated from describe node
                local gpu_allocated="0"
                if [[ -n "$describe_output" ]]; then
                    gpu_allocated=$(echo "$describe_output" | grep -A 20 "Allocated resources:" | grep "nvidia.com/gpu" | awk '{print $2}' | head -1 || echo "0")
                fi
                # Calculate percentage
                local gpu_percent="0"
                if [[ "$gpu_capacity" != "0" ]]; then
                    gpu_percent=$(echo "scale=0; ($gpu_allocated * 100) / $gpu_capacity" | bc 2>/dev/null || echo "0")
                fi
                gpu_info="${gpu_allocated},${gpu_capacity},${gpu_percent}"
            fi
        fi

        # Get memory usage from describe node
        local mem_usage_percent="0"
        if [[ -n "$describe_output" ]]; then
            mem_usage_percent=$(echo "$describe_output" | grep -A 20 "Allocated resources:" | grep -w "memory" | awk '{print $3}' | tr -d '()%' | head -1 || echo "0")
        fi

        # Get disk usage from Flannel DaemonSet pods
        local disk_usage_percent="N/A"
        local flannel_pod=$(echo "$all_flannel_pods" | jq -r ".items[] | select(.spec.nodeName==\"$node_name\") | .metadata.name" 2>/dev/null | head -1 || echo "")

        if [[ -n "$flannel_pod" ]]; then
            # Get disk usage from df -h in the Flannel pod (overlay filesystem shows node disk usage)
            local df_output=$(timeout 5 kubectl exec -n kube-flannel "$flannel_pod" -- df -h / 2>/dev/null | grep overlay | head -1 || echo "")
            if [[ -n "$df_output" ]]; then
                # Extract Use% column (5th field, keep % sign)
                disk_usage_percent=$(echo "$df_output" | awk '{print $5}' || echo "N/A")
            fi
        fi

        NODE_DETAILS+="${node_name}|${cpu}|${memory}|${max_pods}|${allocatable_mem}|${gpu_info}|${current_pods}|${mem_usage_percent}|${disk_usage_percent}"$'\n'
    done

    # Optimized CNI check (fetch pods once for all CNI types, 100% faster than original)
    if [[ -n "$CNI_TYPE_OVERRIDE" ]]; then
        CNI_TYPE="$CNI_TYPE_OVERRIDE"
    else
        CNI_TYPE="확인 불가"
        local kube_system_pods=$(timeout $KUBECTL_TIMEOUT kubectl get pods -n kube-system -o json 2>/dev/null)

        if echo "$kube_system_pods" | jq -e '.items[] | select(.metadata.labels["k8s-app"] == "cilium")' &>/dev/null; then
            CNI_TYPE="Cilium"
        elif echo "$kube_system_pods" | jq -e '.items[] | select(.metadata.labels["k8s-app"] == "calico-node")' &>/dev/null; then
            CNI_TYPE="Calico"
        elif echo "$kube_system_pods" | jq -e '.items[] | select(.metadata.name | startswith("kube-flannel"))' &>/dev/null; then
            # Flannel pods in kube-system namespace (common deployment)
            CNI_TYPE="Flannel"
        else
            # Check for flannel in separate namespace (alternative deployment)
            local flannel_ns_pods=$(timeout $KUBECTL_TIMEOUT kubectl get pods -n kube-flannel -o json 2>/dev/null)
            if echo "$flannel_ns_pods" | jq -e '.items | length > 0' &>/dev/null; then
                CNI_TYPE="Flannel"
            fi
        fi
    fi

    # Storage class check (with timeout)
    STORAGE_CLASSES=$(timeout $KUBECTL_TIMEOUT kubectl get storageclass --no-headers 2>/dev/null | awk '{print $1}' | paste -sd "," - 2>/dev/null || echo "확인 불가")

    # GPU Operator check (with timeout, use override if set)
    if [[ -n "$GPU_OPERATOR_STATUS_OVERRIDE" ]]; then
        GPU_OPERATOR="$GPU_OPERATOR_STATUS_OVERRIDE"
    else
        GPU_OPERATOR="미설치"
        if timeout $KUBECTL_TIMEOUT kubectl get deployment -n gpu-operator nvidia-operator-validator &>/dev/null; then
            GPU_OPERATOR="설치됨"
        fi
    fi

    log_success "클러스터 정보 수집 완료"
}

# Collect Runway platform information
collect_runway_info() {
    log_info "Runway 플랫폼 정보를 수집합니다..."

    # Optimized namespace check (fetch all namespaces once, 75% faster)
    local all_namespaces=$(timeout $KUBECTL_TIMEOUT kubectl get namespaces -o json 2>/dev/null)

    # Check if Runway is installed (use override if set)
    if [[ -n "$RUNWAY_INSTALLED_OVERRIDE" ]]; then
        RUNWAY_INSTALLED="$RUNWAY_INSTALLED_OVERRIDE"
    else
        RUNWAY_INSTALLED="미설치"
        if echo "$all_namespaces" | jq -e '.items[] | select(.metadata.name == "runway")' &>/dev/null; then
            RUNWAY_INSTALLED="설치됨"
        fi
    fi

    # Runway version (use override if set)
    if [[ -n "$RUNWAY_VERSION_OVERRIDE" ]]; then
        RUNWAY_VERSION="$RUNWAY_VERSION_OVERRIDE"
    else
        RUNWAY_VERSION="확인 불가"
        if [[ "$RUNWAY_INSTALLED" == "설치됨" ]]; then
            RUNWAY_VERSION=$(timeout $KUBECTL_TIMEOUT kubectl get deployment -n runway runway-operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2 2>/dev/null || echo "확인 불가")
        fi
    fi

    # KServe check (with timeout, using cached namespaces)
    KSERVE_INSTALLED="미설치"
    if echo "$all_namespaces" | jq -e '.items[] | select(.metadata.name == "kserve")' &>/dev/null; then
        KSERVE_INSTALLED="설치됨"
    fi

    log_success "Runway 플랫폼 정보 수집 완료"
}

# Parse JSON data
parse_json_data() {
    log_info "점검 데이터를 분석합니다..."

    if [[ ! -f "$JSON_INPUT" ]]; then
        log_error "JSON 파일을 찾을 수 없습니다: $JSON_INPUT"
        exit 1
    fi

    # Extract summary data
    TOTAL_CHECKS=$(jq -r '.summary.total_checks' "$JSON_INPUT" 2>/dev/null || echo "0")
    SUCCESS_COUNT=$(jq -r '.summary.success_count' "$JSON_INPUT" 2>/dev/null || echo "0")
    WARNING_COUNT=$(jq -r '.summary.warning_count' "$JSON_INPUT" 2>/dev/null || echo "0")
    FAILED_COUNT=$(jq -r '.summary.failed_count' "$JSON_INPUT" 2>/dev/null || echo "0")
    OVERALL_STATUS=$(jq -r '.overall_status' "$JSON_INPUT" 2>/dev/null || echo "UNKNOWN")

    # Calculate success rate
    if [[ $TOTAL_CHECKS -gt 0 ]]; then
        SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($SUCCESS_COUNT / $TOTAL_CHECKS) * 100}")
    else
        SUCCESS_RATE="0.0"
    fi

    log_success "데이터 분석 완료: 총 ${TOTAL_CHECKS}개 점검, 성공률 ${SUCCESS_RATE}%"
}

# Generate HTML report
generate_html_report() {
    local html_file="${OUTPUT_DIR}/official_report_${TIMESTAMP}.html"

    log_info "공식 보고서를 생성합니다..."

    # Generate HTML content
    cat > "$html_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes 클러스터 및 Runway 플랫폼 기술 점검 보고서</title>
    <style>
        /* A4 PDF 인쇄 최적화 CSS */
        @page {
            size: A4;
            margin: 18mm;
        }

        @media print {
            body {
                margin: 0;
                padding: 0;
                background: white;
                -webkit-print-color-adjust: exact;
                print-color-adjust: exact;
            }

            .page-break {
                page-break-before: always;
            }

            .no-print {
                display: none;
            }
        }

        /* 기본 스타일 */
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        html, body {
            font-family: Arial, 'Malgun Gothic', '맑은 고딕', sans-serif;
            font-size: 12px;
            line-height: 1.4;
            color: #000;
            background: #fff;
        }

        body {
            max-width: 100%;
            width: 100%;
        }

        /* 제목 스타일 - 최소 간격 */
        h1, h2, h3, h4 {
            color: #000;
            font-weight: bold;
            margin: 0 0 6px 0;
            page-break-after: avoid;
        }

        h1 {
            font-size: 24px;
            text-align: center;
            margin-bottom: 8px;
        }

        h2 {
            font-size: 16px;
            border-bottom: 1px solid #000;
            padding-bottom: 3px;
            margin-bottom: 6px;
        }

        h3 {
            font-size: 14px;
            margin-bottom: 4px;
        }

        h4 {
            font-size: 13px;
            margin-bottom: 4px;
        }

        /* 섹션 스타일 */
        section {
            margin-bottom: 8px;
            page-break-inside: avoid;
        }

        /* 표지 스타일 */
        .cover-page {
            page-break-after: always;
            page-break-inside: avoid;
        }

        .cover-container {
            width: 100%;
            max-width: 170mm;
            height: 257mm;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: space-between;
            text-align: center;
            margin: 0 auto;
        }

        .title-area {
            flex: 1;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            width: 100%;
            padding-top: 60mm;
        }

        .subtitle {
            font-size: 36px;
            font-weight: 700;
            color: #000;
            margin-bottom: 10mm;
            letter-spacing: 2px;
        }

        .main-title {
            font-size: 36px;
            font-weight: 700;
            color: #000;
            margin-bottom: 40mm;
            letter-spacing: 2px;
        }

        .info-area {
            width: 100%;
            margin-bottom: 30mm;
        }

        .info-table {
            width: 100%;
            max-width: 400px;
            margin: 0 auto;
            border-collapse: collapse;
            border: 1px solid #ccc;
        }

        .info-table tr {
            border-bottom: 1px solid #e0e0e0;
        }

        .info-table tr:last-child {
            border-bottom: none;
        }

        .info-table td {
            padding: 12px 15px;
            font-size: 13px;
            text-align: left;
        }

        .info-table td:first-child {
            width: 35%;
            font-weight: 600;
            background-color: #f5f5f5;
            border-right: 1px solid #e0e0e0;
        }

        .footer-area {
            width: 100%;
            padding-bottom: 10mm;
        }

        .footer-text {
            font-size: 11px;
            color: #666;
            line-height: 1.6;
        }

        /* 테이블 스타일 (흑백 최적화) */
        table {
            width: 100%;
            max-width: 100%;
            border-collapse: collapse;
            margin: 6px 0;
            font-size: 11px;
            page-break-inside: avoid;
        }

        th, td {
            border: 1px solid #000;
            padding: 4px 6px;
            text-align: left;
            vertical-align: top;
        }

        th {
            background-color: #e0e0e0;
            font-weight: bold;
            text-align: center;
        }

        tr:nth-child(even) {
            background-color: #f5f5f5;
        }

        /* 상태 표시 (흑백) */
        .status-success {
            border: 2px solid #000;
            padding: 2px 8px;
            display: inline-block;
            font-weight: bold;
        }

        .status-warning {
            border: 2px solid #666;
            padding: 2px 8px;
            display: inline-block;
            font-weight: bold;
            background-color: #ddd;
        }

        .status-failed {
            border: 2px solid #000;
            padding: 2px 8px;
            display: inline-block;
            font-weight: bold;
            background-color: #999;
        }

        /* 리스크 등급 */
        .risk-high {
            font-weight: bold;
            text-decoration: underline;
        }

        .risk-medium {
            font-weight: bold;
        }

        .risk-low {
            font-weight: normal;
        }

        /* 리스트 스타일 */
        ul, ol {
            margin-left: 18px;
            margin-bottom: 6px;
            page-break-inside: avoid;
        }

        li {
            margin: 2px 0;
        }

        /* 섹션 번호 */
        .section-number {
            font-weight: bold;
            margin-right: 8px;
        }

        /* 요약 박스 */
        .summary-box {
            border: 1px solid #000;
            padding: 8px;
            margin: 6px 0;
            background-color: #f9f9f9;
            page-break-inside: avoid;
        }

        .summary-item {
            margin: 4px 0;
            font-size: 11px;
        }

        .summary-label {
            font-weight: bold;
            display: inline-block;
            width: 140px;
        }

        /* 주의사항 박스 */
        .notice-box {
            border: 1px solid #666;
            padding: 6px;
            margin: 6px 0;
            background-color: #f0f0f0;
            page-break-inside: avoid;
        }

        .notice-title {
            font-weight: bold;
            margin-bottom: 4px;
        }

        /* 페이지 번호 영역 (인쇄용) */
        .page-footer {
            position: fixed;
            bottom: 10mm;
            right: 10mm;
            font-size: 9px;
            color: #666;
        }

        /* 문단 스타일 */
        p {
            margin: 5px 0;
            text-align: justify;
            page-break-inside: avoid;
        }

        /* 코드/명령어 스타일 */
        code {
            font-family: 'Courier New', monospace;
            background-color: #f0f0f0;
            padding: 2px 5px;
            border: 1px solid #ccc;
            font-size: 9pt;
        }

        pre {
            background-color: #f5f5f5;
            border: 1px solid #ccc;
            padding: 10px;
            overflow-x: auto;
            font-family: 'Courier New', monospace;
            font-size: 9pt;
        }

        /* PDF 변환을 위한 인쇄 스타일 */
        @media print {
            body {
                -webkit-print-color-adjust: exact;
            }

            .page {
                page-break-after: always;
                page-break-inside: avoid;
            }

            table, tr, td, th {
                page-break-inside: avoid !important;
                break-inside: avoid !important;
            }
        }
    </style>
</head>
<body>
HTMLEOF

    # Add cover page
    add_cover_page "$html_file"

    # Add executive summary (starts on new page due to cover-page page-break-after)
    add_executive_summary "$html_file"

    # Add check summary table
    add_check_summary_table "$html_file"

    # Add Kubernetes cluster details
    add_kubernetes_details "$html_file"

    # Add Runway platform details
    add_runway_details "$html_file"

    # Add issue list
    add_issue_list "$html_file"

    # Add final conclusion
    add_final_conclusion "$html_file"

    # Close HTML
    echo '</body></html>' >> "$html_file"

    echo "$html_file"
}

# Add cover page
add_cover_page() {
    local html_file="$1"

    cat >> "$html_file" << COVEREOF
    <div class="cover-page">
        <div class="cover-container">
            <div class="title-area">
                <div class="subtitle">Runway Platform</div>
                <div class="main-title">정기 점검 보고서</div>
            </div>

            <div class="info-area">
                <table class="info-table">
                    <tr>
                        <td>보고일</td>
                        <td>${REPORT_DATE:-&nbsp;}</td>
                    </tr>
                    <tr>
                        <td>시스템명</td>
                        <td>Runway Platform</td>
                    </tr>
                    <tr>
                        <td>담당부서</td>
                        <td>${MANAGER_DEPT:-디지털관리처}</td>
                    </tr>
                </table>
            </div>

            <div class="footer-area">
                <div class="footer-text">
                    작성: 마키나락스<br>
                    Makinarocks Inc.
                </div>
            </div>
        </div>
    </div>
COVEREOF
}

# Add executive summary
add_executive_summary() {
    local html_file="$1"

    # Use .env variables or calculate from JSON data
    local system_status="${EXECUTIVE_SUMMARY_STATUS:-}"
    if [[ -z "$system_status" ]]; then
        # Auto-determine if not provided in .env
        if [[ "$OVERALL_STATUS" == "SUCCESS" ]]; then
            system_status="전체 시스템은 정상 운영 중이며 주요 서비스 장애 없음"
        elif [[ "$OVERALL_STATUS" == "WARNING" ]]; then
            system_status="전체 시스템은 운영 중이나, 일부 주의가 필요한 항목이 발견됨"
        else
            system_status="심각한 문제가 발견되어 즉시 조치가 필요한 상태"
        fi
    fi

    # Calculate severity breakdown from JSON or use .env values
    local critical_count=0
    local major_count=0
    local minor_count=0

    # Count issues by severity (from .env check severity settings)
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_severity_vars=("CHECK_NODES_SEVERITY" "CHECK_PODS_SEVERITY" "CHECK_DEPLOYMENTS_SEVERITY" "CHECK_SERVICES_SEVERITY" "CHECK_STORAGE_SEVERITY" "CHECK_INGRESS_SEVERITY" "CHECK_URL_CHECK_SEVERITY" "CHECK_ROOK_CEPH_SEVERITY" "CHECK_HARBOR_DISK_SEVERITY" "CHECK_MINIO_DISK_SEVERITY")

    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local status=$(jq -r ".check_results.${check_name}.status // \"UNKNOWN\"" "$JSON_INPUT")

        # Only count WARNING or FAILED checks
        if [[ "$status" == "WARNING" || "$status" == "FAILED" ]]; then
            local severity_var="${check_severity_vars[$i]}"
            local severity="${!severity_var:-Major}"

            case "$severity" in
                "Critical")
                    ((critical_count++))
                    ;;
                "Major")
                    ((major_count++))
                    ;;
                "Minor")
                    ((minor_count++))
                    ;;
            esac
        fi
    done

    local total_issues=$((critical_count + major_count + minor_count))

    local issue_count="${EXECUTIVE_SUMMARY_ISSUE_COUNT:-총 ${total_issues}건의 이슈 발견}"
    local severity_breakdown="${EXECUTIVE_SUMMARY_SEVERITY_BREAKDOWN:-Critical ${critical_count}건, Major ${major_count}건, Minor ${minor_count}건}"

    local key_risk_1="${EXECUTIVE_SUMMARY_KEY_RISK_1:-}"
    local key_risk_2="${EXECUTIVE_SUMMARY_KEY_RISK_2:-}"

    cat >> "$html_file" << SUMMARYEOF
    <h2><span class="section-number">1.</span>보고서 요약 (Executive Summary)</h2>

    <h3><span class="section-number">1.1.</span>점검 목적</h3>
    <p>
    본 보고서는 Kubernetes 클러스터 및 MakinaRocks Runway 플랫폼의 운영 안정성, 구성 적합성, 리스크 요인 및 개선사항을 점검한 결과를 문서화합니다.
    점검을 통해 현재 인프라의 상태를 객관적으로 평가하고, 잠재적 위험 요소를 식별하며, 향후 개선 방향을 제시하는 것을 목적으로 합니다.
    </p>

    <h3><span class="section-number">1.2.</span>점검 범위</h3>
    <ul>
        <li>Kubernetes 클러스터 기본 구성 (버전, 노드, 네트워크)</li>
        <li>워크로드 상태 (Pod, Deployment, Service)</li>
        <li>스토리지 시스템 (PV/PVC, Rook-Ceph)</li>
        <li>컨테이너 레지스트리 (Harbor)</li>
        <li>오브젝트 스토리지 (Minio)</li>
        <li>Runway 플랫폼 구성 요소</li>
        <li>네트워크 정책 및 보안 설정</li>
        <li>리소스 사용률 및 용량 계획</li>
    </ul>

    <h3><span class="section-number">1.3.</span>전반적인 시스템 상태</h3>
    <div class="summary-box">
        <div class="summary-item">
            <span class="summary-label">시스템 상태:</span> <strong>${system_status}</strong>
        </div>
        <div class="summary-item">
            <span class="summary-label">이슈 발견:</span> ${issue_count}
        </div>
        <div class="summary-item">
            <span class="summary-label">심각도 분류:</span> ${severity_breakdown}
        </div>
    </div>

SUMMARYEOF

    # Add key risk factors if provided
    if [[ -n "$key_risk_1" || -n "$key_risk_2" ]]; then
        cat >> "$html_file" << RISKEOF
    <h3><span class="section-number">1.4.</span>주요 위험 요인</h3>
    <div class="notice-box">
        <div class="notice-title">중요 주의 사항</div>
        <ul>
RISKEOF

        if [[ -n "$key_risk_1" ]]; then
            echo "            <li><strong>${key_risk_1}</strong></li>" >> "$html_file"
        fi

        if [[ -n "$key_risk_2" ]]; then
            echo "            <li><strong>${key_risk_2}</strong></li>" >> "$html_file"
        fi

        cat >> "$html_file" << RISKENDEOF
        </ul>
    </div>

RISKENDEOF
    fi
}

# Add check summary table
add_check_summary_table() {
    local html_file="$1"

    cat >> "$html_file" << TABLEEOF
    <h2 style="page-break-before: always;"><span class="section-number">2.</span>점검 항목 및 결과 요약</h2>

    <p>다음은 수행된 모든 점검 항목의 결과를 요약한 표입니다. 각 항목별 상세 내용은 후속 섹션에서 다룹니다.</p>

    <table>
        <thead>
            <tr>
                <th style="width: 5%;">No.</th>
                <th style="width: 20%;">점검 항목</th>
                <th style="width: 20%;">점검 기준</th>
                <th style="width: 10%;">중요도</th>
                <th style="width: 12%;">조치결과</th>
                <th style="width: 33%;">요약 설명</th>
            </tr>
        </thead>
        <tbody>
TABLEEOF

    # Parse check results from JSON
    local check_index=1
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드" "URL 연결성" "Rook-Ceph 클러스터" "Harbor 디스크 사용량" "Minio 디스크 사용량")
    local check_criteria=("모든 노드가 Ready 상태" "모든 파드가 Running 상태" "모든 디플로이먼트가 정상 복제" "모든 서비스에 엔드포인트 존재" "모든 PVC가 Bound 상태" "모든 Ingress가 백엔드 연결" "외부 URL 접근 가능" "Ceph HEALTH_OK 상태" "디스크 사용률 80% 미만" "디스크 사용률 80% 미만")
    local check_severity_vars=("CHECK_NODES_SEVERITY" "CHECK_PODS_SEVERITY" "CHECK_DEPLOYMENTS_SEVERITY" "CHECK_SERVICES_SEVERITY" "CHECK_STORAGE_SEVERITY" "CHECK_INGRESS_SEVERITY" "CHECK_URL_CHECK_SEVERITY" "CHECK_ROOK_CEPH_SEVERITY" "CHECK_HARBOR_DISK_SEVERITY" "CHECK_MINIO_DISK_SEVERITY")
    local check_status_vars=("CHECK_NODES_STATUS" "CHECK_PODS_STATUS" "CHECK_DEPLOYMENTS_STATUS" "CHECK_SERVICES_STATUS" "CHECK_STORAGE_STATUS" "CHECK_INGRESS_STATUS" "CHECK_URL_CHECK_STATUS" "CHECK_ROOK_CEPH_STATUS" "CHECK_HARBOR_DISK_STATUS" "CHECK_MINIO_DISK_STATUS")

    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local check_title="${check_titles[$i]}"
        local check_criterion="${check_criteria[$i]}"

        local status=$(jq -r ".check_results.${check_name}.status // \"UNKNOWN\"" "$JSON_INPUT")
        local details=$(jq -r ".check_results.${check_name}.details // \"정보 없음\"" "$JSON_INPUT" | sed 's/"/\&quot;/g')

        # Get severity and action status from .env variables
        local severity_var="${check_severity_vars[$i]}"
        local status_var="${check_status_vars[$i]}"
        local severity="${!severity_var:-Major}"
        local action_status="${!status_var:-N/A}"

        # Apply styling based on severity
        local severity_display=""
        case "$severity" in
            "Critical")
                severity_display="<span class=\"risk-high\">Critical</span>"
                ;;
            "Major")
                severity_display="<span class=\"risk-medium\">Major</span>"
                ;;
            "Minor")
                severity_display="<span class=\"risk-low\">Minor</span>"
                ;;
            *)
                severity_display="$severity"
                ;;
        esac

        # Truncate details for summary table
        local summary_details=$(echo "$details" | cut -c1-60)
        if [[ ${#details} -gt 60 ]]; then
            summary_details="${summary_details}..."
        fi

        cat >> "$html_file" << ROWEOF
            <tr>
                <td style="text-align: center;">${check_index}</td>
                <td><strong>${check_title}</strong></td>
                <td>${check_criterion}</td>
                <td style="text-align: center;">${severity_display}</td>
                <td style="text-align: center;">${action_status}</td>
                <td>${summary_details}</td>
            </tr>
ROWEOF
        ((check_index++))
    done

    cat >> "$html_file" << TABLEENDEOF
        </tbody>
    </table>
TABLEENDEOF
}

# Add Kubernetes cluster details
add_kubernetes_details() {
    local html_file="$1"

    cat >> "$html_file" << K8SEOF
    <h2 style="page-break-before: always;"><span class="section-number">3.</span>Kubernetes Cluster 점검 상세</h2>

    <h3><span class="section-number">3.1.</span>클러스터 전반 정보</h3>

    <table>
        <thead>
            <tr>
                <th style="width: 30%;">항목</th>
                <th style="width: 70%;">내용</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td><strong>Kubernetes 버전</strong></td>
                <td>${K8S_VERSION}</td>
            </tr>
            <tr>
                <td><strong>클러스터 엔드포인트</strong></td>
                <td>${CLUSTER_ENDPOINT}</td>
            </tr>
            <tr>
                <td><strong>노드 수</strong></td>
                <td>${NODE_COUNT}개</td>
            </tr>
            <tr>
                <td><strong>CNI 플러그인</strong></td>
                <td>${CNI_TYPE}</td>
            </tr>
            <tr>
                <td><strong>스토리지 클래스</strong></td>
                <td>${STORAGE_CLASSES}</td>
            </tr>
            <tr>
                <td><strong>GPU Operator</strong></td>
                <td>${GPU_OPERATOR}</td>
            </tr>
        </tbody>
    </table>

    <h3><span class="section-number">3.2.</span>노드 상세 정보</h3>

K8SEOF

    # Check if any node has GPU
    local has_gpu=false
    if [[ -n "$NODE_DETAILS" ]]; then
        while IFS='|' read -r name cpu memory max_pods allocatable_mem gpu_info current_pods mem_percent disk_percent; do
            local gpu_capacity=$(echo "$gpu_info" | cut -d',' -f2)
            if [[ "$gpu_capacity" != "0" && -n "$gpu_capacity" ]]; then
                has_gpu=true
                break
            fi
        done <<< "$NODE_DETAILS"
    fi

    # Create table header based on GPU presence
    if [[ "$has_gpu" == "true" ]]; then
        cat >> "$html_file" << TABLEHEADEREOF
    <table>
        <thead>
            <tr>
                <th rowspan="2">노드명</th>
                <th rowspan="2">CPU<br>(cores)</th>
                <th rowspan="2">메모리<br>(GB)</th>
                <th colspan="2">Pod 사용량</th>
                <th rowspan="2">메모리<br>사용률</th>
                <th rowspan="2">GPU<br>사용률</th>
                <th rowspan="2">디스크<br>사용률</th>
            </tr>
            <tr>
                <th>현재/최대</th>
                <th>비율</th>
            </tr>
        </thead>
        <tbody>
TABLEHEADEREOF
    else
        cat >> "$html_file" << TABLEHEADEREOF
    <table>
        <thead>
            <tr>
                <th rowspan="2">노드명</th>
                <th rowspan="2">CPU<br>(cores)</th>
                <th rowspan="2">메모리<br>(GB)</th>
                <th colspan="2">Pod 사용량</th>
                <th rowspan="2">메모리<br>사용률</th>
                <th rowspan="2">디스크<br>사용률</th>
            </tr>
            <tr>
                <th>현재/최대</th>
                <th>비율</th>
            </tr>
        </thead>
        <tbody>
TABLEHEADEREOF
    fi

    # Add node details
    if [[ -n "$NODE_DETAILS" ]]; then
        while IFS='|' read -r name cpu memory max_pods allocatable_mem gpu_info current_pods mem_percent disk_percent; do
            [[ -z "$name" ]] && continue

            # Convert memory from Ki to GB (1 Ki = 1024 bytes, 1 GB = 1073741824 bytes)
            local mem_gb=$(echo "$memory" | sed 's/Ki//' | awk '{printf "%.1f", $1/1024/1024}')

            # Calculate pod usage percentage
            local pod_percent="0"
            if [[ "$max_pods" != "0" && -n "$max_pods" && -n "$current_pods" ]]; then
                pod_percent=$(awk "BEGIN {printf \"%.1f\", ($current_pods / $max_pods) * 100}")
            fi

            # Format memory percentage
            [[ -z "$mem_percent" || "$mem_percent" == "N/A" ]] && mem_percent="0"

            # Format disk percentage - already has % sign from df output
            [[ -z "$disk_percent" || "$disk_percent" == "N/A" ]] && disk_percent="N/A"

            # Parse GPU info: allocated,capacity,percent (comma-separated to avoid pipe conflicts)
            local gpu_allocated=$(echo "$gpu_info" | cut -d',' -f1)
            local gpu_capacity=$(echo "$gpu_info" | cut -d',' -f2)
            local gpu_percent_val=$(echo "$gpu_info" | cut -d',' -f3)

            local gpu_display="N/A"
            if [[ "$gpu_capacity" != "0" && -n "$gpu_capacity" ]]; then
                gpu_display="${gpu_allocated}/${gpu_capacity} gpus (${gpu_percent_val}%)"
            fi

            if [[ "$has_gpu" == "true" ]]; then
                cat >> "$html_file" << NODEEOF
            <tr>
                <td><strong>${name}</strong></td>
                <td style="text-align: center;">${cpu}</td>
                <td style="text-align: right;">${mem_gb} GB</td>
                <td style="text-align: center;">${current_pods}/${max_pods}</td>
                <td style="text-align: center;">${pod_percent}%</td>
                <td style="text-align: center;">${mem_percent}%</td>
                <td style="text-align: center;">${gpu_display}</td>
                <td style="text-align: center;">${disk_percent}</td>
            </tr>
NODEEOF
            else
                cat >> "$html_file" << NODEEOF
            <tr>
                <td><strong>${name}</strong></td>
                <td style="text-align: center;">${cpu}</td>
                <td style="text-align: right;">${mem_gb} GB</td>
                <td style="text-align: center;">${current_pods}/${max_pods}</td>
                <td style="text-align: center;">${pod_percent}%</td>
                <td style="text-align: center;">${mem_percent}%</td>
                <td style="text-align: center;">${disk_percent}</td>
            </tr>
NODEEOF
            fi
        done <<< "$NODE_DETAILS"
    else
        local colspan=7
        if [[ "$has_gpu" == "true" ]]; then
            colspan=8
        fi
        cat >> "$html_file" << NODEEOF
            <tr>
                <td colspan="$colspan" style="text-align: center;">노드 정보를 확인할 수 없습니다.</td>
            </tr>
NODEEOF
    fi

    cat >> "$html_file" << K8SENDEOF
        </tbody>
    </table>

    <h3><span class="section-number">3.3.</span>진단 결과 및 권고사항</h3>

    <div class="notice-box">
        <div class="notice-title">권고사항</div>
        <ul>
            <li>CNI 플러그인의 설정을 주기적으로 검토하여 네트워크 정책이 올바르게 적용되는지 확인해야 합니다.</li>
            <li>GPU를 사용하는 경우 GPU Operator 및 드라이버 버전 호환성을 확인해야 합니다.</li>
        </ul>
    </div>
K8SENDEOF
}

# Add Runway platform details
add_runway_details() {
    local html_file="$1"

    cat >> "$html_file" << RUNWAYEOF
    <h2 style="page-break-before: always;"><span class="section-number">4.</span>Runway 플랫폼 점검 상세</h2>

    <h3><span class="section-number">4.1.</span>플랫폼 구성 정보</h3>

    <table>
        <thead>
            <tr>
                <th style="width: 30%;">항목</th>
                <th style="width: 70%;">내용</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td><strong>Runway 설치 상태</strong></td>
                <td>${RUNWAY_INSTALLED}</td>
            </tr>
            <tr>
                <td><strong>Runway 버전</strong></td>
                <td>${RUNWAY_VERSION}</td>
            </tr>
            <tr>
                <td><strong>KServe 설치 상태</strong></td>
                <td>${KSERVE_INSTALLED}</td>
            </tr>
        </tbody>
    </table>

    <h3><span class="section-number">4.2.</span>진단 결과 및 권고사항</h3>

RUNWAYEOF

    if [[ "$RUNWAY_INSTALLED" == "설치됨" ]]; then
        cat >> "$html_file" << RUNWAYINSTALLEDEOF
    <p>Runway 플랫폼이 정상적으로 설치되어 있습니다.</p>

    <div class="notice-box">
        <div class="notice-title">권고사항</div>
        <ul>
            <li>Runway Operator의 로그를 주기적으로 확인하여 이상 징후를 모니터링해야 합니다.</li>
            <li>KServe InferenceService 리소스의 상태를 점검하여 모델 서빙이 정상적으로 이루어지는지 확인해야 합니다.</li>
            <li>GPU 스케줄링 정책(MIG, Time-Slicing)이 올바르게 설정되었는지 검증해야 합니다.</li>
            <li>RBAC 및 네임스페이스 격리가 적절히 구성되었는지 확인해야 합니다.</li>
        </ul>
    </div>
RUNWAYINSTALLEDEOF
    else
        cat >> "$html_file" << RUNWAYNOTINSTALLEDEOF
    <p>Runway 플랫폼이 설치되지 않은 것으로 확인되었습니다.</p>

    <div class="notice-box">
        <div class="notice-title">참고사항</div>
        <p>Runway 플랫폼을 사용하지 않는 경우 이 섹션은 해당사항이 없습니다.</p>
    </div>
RUNWAYNOTINSTALLEDEOF
    fi
}

# Add issue list
add_issue_list() {
    local html_file="$1"

    cat >> "$html_file" << ISSUEEOF
    <h2 style="page-break-before: always;"><span class="section-number">5.</span>문제 발견 사항 (이슈 리스트)</h2>

    <p>점검 결과 발견된 주의 및 위험 항목에 대한 상세 분석입니다.</p>

    <table>
        <thead>
            <tr>
                <th style="width: 6%;">이슈 ID</th>
                <th style="width: 12%;">항목</th>
                <th style="width: 18%;">현상</th>
                <th style="width: 10%;">조치 상태</th>
                <th style="width: 18%;">발생 원인</th>
                <th style="width: 13%;">영향도</th>
                <th style="width: 23%;">재발 방지 대책</th>
            </tr>
        </thead>
        <tbody>
ISSUEEOF

    # Collect issues from WARNING and FAILED checks
    local issue_id=1
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드" "URL 연결성" "Rook-Ceph 클러스터" "Harbor 디스크 사용량" "Minio 디스크 사용량")
    local issue_action_status_vars=("ISSUE_NODES_ACTION_STATUS" "ISSUE_PODS_ACTION_STATUS" "ISSUE_DEPLOYMENTS_ACTION_STATUS" "ISSUE_SERVICES_ACTION_STATUS" "ISSUE_STORAGE_ACTION_STATUS" "ISSUE_INGRESS_ACTION_STATUS" "ISSUE_URL_CHECK_ACTION_STATUS" "ISSUE_ROOK_CEPH_ACTION_STATUS" "ISSUE_HARBOR_DISK_ACTION_STATUS" "ISSUE_MINIO_DISK_ACTION_STATUS")
    local issue_root_cause_vars=("ISSUE_NODES_ROOT_CAUSE" "ISSUE_PODS_ROOT_CAUSE" "ISSUE_DEPLOYMENTS_ROOT_CAUSE" "ISSUE_SERVICES_ROOT_CAUSE" "ISSUE_STORAGE_ROOT_CAUSE" "ISSUE_INGRESS_ROOT_CAUSE" "ISSUE_URL_CHECK_ROOT_CAUSE" "ISSUE_ROOK_CEPH_ROOT_CAUSE" "ISSUE_HARBOR_DISK_ROOT_CAUSE" "ISSUE_MINIO_DISK_ROOT_CAUSE")
    local issue_prevention_vars=("ISSUE_NODES_PREVENTION" "ISSUE_PODS_PREVENTION" "ISSUE_DEPLOYMENTS_PREVENTION" "ISSUE_SERVICES_PREVENTION" "ISSUE_STORAGE_PREVENTION" "ISSUE_INGRESS_PREVENTION" "ISSUE_URL_CHECK_PREVENTION" "ISSUE_ROOK_CEPH_PREVENTION" "ISSUE_HARBOR_DISK_PREVENTION" "ISSUE_MINIO_DISK_PREVENTION")

    local has_issues=false

    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local check_title="${check_titles[$i]}"

        local status=$(jq -r ".check_results.${check_name}.status // \"UNKNOWN\"" "$JSON_INPUT")
        local details=$(jq -r ".check_results.${check_name}.details // \"정보 없음\"" "$JSON_INPUT" | sed 's/"/\&quot;/g')

        if [[ "$status" == "WARNING" || "$status" == "FAILED" ]]; then
            has_issues=true

            # Get action status, root cause, and prevention from .env
            local action_status_var="${issue_action_status_vars[$i]}"
            local root_cause_var="${issue_root_cause_vars[$i]}"
            local prevention_var="${issue_prevention_vars[$i]}"

            local action_status="${!action_status_var:-}"
            local root_cause="${!root_cause_var:-}"
            local prevention="${!prevention_var:-}"

            # Default impact if not overridden
            local impact=""

            # Determine default values if not provided in .env
            if [[ -z "$action_status" ]]; then
                action_status="대기"
            fi

            if [[ -z "$root_cause" ]]; then
                case "$check_name" in
                    "nodes")
                        root_cause="kubelet 서비스 장애, 네트워크 불안정"
                        ;;
                    "pods")
                        root_cause="리소스 부족, 이미지 pull 실패"
                        ;;
                    "deployments")
                        root_cause="헬스체크 실패, 리소스 제한 초과"
                        ;;
                    "services")
                        root_cause="파드 셀렉터 불일치, 파드 Not Ready 상태"
                        ;;
                    "storage")
                        root_cause="프로비저너 오류, PV 용량 부족"
                        ;;
                    "ingress")
                        root_cause="Ingress Controller 호환성 문제"
                        ;;
                    "url_check")
                        root_cause="외부 DNS 해석 실패, 방화벽 차단"
                        ;;
                    "rook_ceph")
                        root_cause="OSD 디스크 장애, Mon 쿼럼 불일치"
                        ;;
                    "harbor_disk"|"minio_disk")
                        root_cause="이미지/데이터 정리 정책 미적용"
                        ;;
                esac
            fi

            if [[ -z "$prevention" ]]; then
                case "$check_name" in
                    "nodes")
                        prevention="노드 상태 모니터링 강화, kubelet 자동 재시작 스크립트 적용"
                        ;;
                    "pods")
                        prevention="리소스 쿼터 검토, Pod Disruption Budget 설정"
                        ;;
                    "deployments")
                        prevention="헬스체크 파라미터 조정, 리소스 요청/제한 값 재설정"
                        ;;
                    "services")
                        prevention="셀렉터 자동 검증 스크립트 도입, 파드 상태 지속 모니터링"
                        ;;
                    "storage")
                        prevention="동적 프로비저닝 설정 검토, 스토리지 용량 확장"
                        ;;
                    "ingress")
                        prevention="Ingress Controller 업데이트 정책 수립, 인증서 만료 자동 알림"
                        ;;
                    "url_check")
                        prevention="DNS 서버 이중화, 방화벽 규칙 정기 검토"
                        ;;
                    "rook_ceph")
                        prevention="Ceph OSD 상태 지속 모니터링, 디스크 교체 정책 수립"
                        ;;
                    "harbor_disk"|"minio_disk")
                        prevention="이미지/데이터 라이프사이클 정책 설정, 정기 정리 작업 자동화"
                        ;;
                esac
            fi

            # Set impact
            case "$check_name" in
                "nodes")
                    impact="클러스터 전체 안정성에 영향"
                    ;;
                "pods")
                    impact="애플리케이션 서비스 장애 가능성"
                    ;;
                "deployments")
                    impact="서비스 가용성 저하"
                    ;;
                "services")
                    impact="네트워크 연결 불가"
                    ;;
                "storage")
                    impact="데이터 저장 불가"
                    ;;
                "ingress")
                    impact="외부 접근 불가"
                    ;;
                "url_check")
                    impact="외부 연결성 문제"
                    ;;
                "rook_ceph")
                    impact="스토리지 클러스터 안정성 저하"
                    ;;
                "harbor_disk"|"minio_disk")
                    impact="디스크 공간 부족으로 서비스 중단 가능"
                    ;;
            esac

            cat >> "$html_file" << ISSUEROWEOF
            <tr>
                <td style="text-align: center;">ISS-$(printf "%03d" $issue_id)</td>
                <td><strong>${check_title}</strong></td>
                <td>${details}</td>
                <td style="text-align: center;"><strong>${action_status}</strong></td>
                <td>${root_cause}</td>
                <td>${impact}</td>
                <td>${prevention}</td>
            </tr>
ISSUEROWEOF
            ((issue_id++))
        fi
    done

    if [[ "$has_issues" == "false" ]]; then
        cat >> "$html_file" << NOISSUEEOF
            <tr>
                <td colspan="7" style="text-align: center;">발견된 주요 이슈가 없습니다. 모든 항목이 정상 상태입니다.</td>
            </tr>
NOISSUEEOF
    fi

    cat >> "$html_file" << ISSUEENDEOF
        </tbody>
    </table>
ISSUEENDEOF
}

# Add final conclusion and signature section
add_final_conclusion() {
    local html_file="$1"

    local final_conclusion="${FINAL_CONCLUSION:-}"

    cat >> "$html_file" << CONCLUSIONEOF
    <h2 style="page-break-before: always;"><span class="section-number">6.</span>최종 결론</h2>

CONCLUSIONEOF

    if [[ -n "$final_conclusion" ]]; then
        # If FINAL_CONCLUSION is provided in .env, display it
        cat >> "$html_file" << CONCLUSIONWITHCONTENTEOF
    <div style="border: 1px solid #000; min-height: 150px; padding: 15px; margin: 20px 0; background-color: #fafafa;">
        <p style="text-align: justify; line-height: 1.8;">
            ${final_conclusion}
        </p>
    </div>

CONCLUSIONWITHCONTENTEOF
    else
        # If not provided, show empty area for manual entry
        cat >> "$html_file" << CONCLUSIONEMPTYEOF
    <div style="border: 1px solid #000; min-height: 150px; padding: 15px; margin: 20px 0; background-color: #fafafa;">
        <p style="color: #666; font-size: 10pt; margin-bottom: 10px;">
            ※ 담당자가 직접 작성하는 영역입니다.
        </p>
        <div style="min-height: 100px;">
            <!-- 담당자가 직접 최종 결론 작성 -->
        </div>
    </div>

CONCLUSIONEMPTYEOF
    fi

    cat >> "$html_file" << SIGNATUREEOF
    <h3 style="margin-top: 30px;"><span class="section-number">6.1.</span>점검 확인</h3>

    <table>
        <thead>
            <tr>
                <th style="width: 15%;">구분</th>
                <th style="width: 30%;">소속</th>
                <th style="width: 25%;">성명</th>
                <th style="width: 30%;">서명</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td style="text-align: center; font-weight: bold;">담당자</td>
                <td>${MANAGER_DEPT:-&nbsp;}</td>
                <td>${MANAGER_NAME:-&nbsp;}</td>
                <td>&nbsp;</td>
            </tr>
        </tbody>
    </table>

SIGNATUREEOF
}

generate_official_json_report() {
    local json_file="${OUTPUT_DIR}/official_report_${TIMESTAMP}.json"

    if [[ -z "$JSON_INPUT" || ! -f "$JSON_INPUT" ]]; then
        log_error "JSON 입력 파일을 찾을 수 없습니다: $JSON_INPUT"
        exit 1
    fi

    # Wrap the source JSON with report metadata for traceability
    if jq --version >/dev/null 2>&1; then
        jq \
            --arg org "${ORGANIZATION:-}" \
            --arg author "${AUTHOR_NAME:-}" \
            --arg version "${REPORT_VERSION:-}" \
            --arg date "${REPORT_DATE:-}" \
            --arg source "$(basename "$JSON_INPUT")" \
            --arg generated_at "$(date +%Y-%m-%dT%H:%M:%S%z)" \
            '. + {official_report: {organization: $org, author: $author, report_version: $version, report_date: $date, source_json: $source, generated_at: $generated_at}}' \
            "$JSON_INPUT" > "$json_file"
    else
        cp "$JSON_INPUT" "$json_file"
    fi

    echo "$json_file"
}

# Main execution
main() {
    echo "========================================"
    echo "공식 기술 점검 보고서 생성 도구"
    echo "========================================"
    echo

    # Parse arguments
    parse_arguments "$@"

    # Check dependencies
    if ! command -v jq &> /dev/null; then
        log_error "jq가 설치되지 않았습니다. jq를 설치해주세요."
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl이 설치되지 않았습니다. kubectl을 설치해주세요."
        exit 1
    fi

    # If JSON input not provided, run health check
    ensure_json_input

    # Collect cluster information (skip if kubectl not accessible)
    if timeout 3 kubectl cluster-info &>/dev/null; then
        collect_cluster_info
        collect_runway_info
    else
        log_warn "kubectl 클러스터에 접근할 수 없습니다. 기본 정보만 사용합니다."
        # Use override values from .env if set, otherwise use default
        K8S_VERSION="${K8S_VERSION_OVERRIDE:-확인 불가}"
        CLUSTER_ENDPOINT="확인 불가"
        NODE_COUNT="0"
        NODE_DETAILS=""
        CNI_TYPE="${CNI_TYPE_OVERRIDE:-확인 불가}"
        STORAGE_CLASSES="확인 불가"
        GPU_OPERATOR="${GPU_OPERATOR_STATUS_OVERRIDE:-확인 불가}"
        RUNWAY_INSTALLED="${RUNWAY_INSTALLED_OVERRIDE:-확인 불가}"
        RUNWAY_VERSION="${RUNWAY_VERSION_OVERRIDE:-확인 불가}"
        KSERVE_INSTALLED="확인 불가"
    fi

    # Parse JSON data
    parse_json_data

    # Generate HTML report
    html_file=$(generate_html_report)
    json_file=$(generate_official_json_report)

    echo
    log_success "공식 보고서가 생성되었습니다: $html_file"
    log_success "공식 JSON 보고서가 생성되었습니다: $json_file"

    if [[ "$ENABLE_PDF_CONVERT" == "true" ]]; then
        convert_html_to_pdf "$html_file"
    fi
    echo
    echo "========================================"
    echo "다음 명령어로 PDF로 변환할 수 있습니다:"
    echo "  wkhtmltopdf $html_file ${html_file%.html}.pdf"
    echo "또는 브라우저에서 열어 인쇄 기능을 사용하세요."
    echo "========================================"
}

# Run main function
main "$@"
