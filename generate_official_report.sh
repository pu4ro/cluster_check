#!/bin/bash

# Kubernetes 클러스터 및 Runway 플랫폼 기술 점검 공식 보고서 생성
# 한국수자원공사(K-water) 공공기관용 보고서
# Author: DevOps Team
# Version: 1.0.0

set -e

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${SCRIPT_DIR}/reports"
JSON_INPUT=""
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_VERSION="1.0"
AUTHOR_NAME="${AUTHOR_NAME:-기술운영팀}"
ORGANIZATION="${ORGANIZATION:-한국수자원공사}"

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
    bash "${SCRIPT_DIR}/k8s_health_check.sh" --output json --interactive

    # Find the latest JSON file
    JSON_INPUT=$(ls -t "${OUTPUT_DIR}"/k8s_health_report_*.json 2>/dev/null | head -1)

    if [[ -z "$JSON_INPUT" || ! -f "$JSON_INPUT" ]]; then
        log_error "JSON 보고서 파일을 찾을 수 없습니다."
        exit 1
    fi

    log_success "점검 완료: $JSON_INPUT"
}

# Collect Kubernetes cluster information
collect_cluster_info() {
    log_info "클러스터 정보를 수집합니다..."

    # Kubernetes version (with timeout)
    K8S_VERSION=$(timeout 5 kubectl version --short 2>/dev/null | grep "Server Version" | cut -d':' -f2 | xargs 2>/dev/null || echo "확인 불가")

    # Cluster info (with timeout)
    CLUSTER_ENDPOINT=$(timeout 5 kubectl cluster-info 2>/dev/null | grep "control plane" | awk '{print $NF}' 2>/dev/null || echo "확인 불가")

    # Node count and details (with timeout)
    NODE_COUNT=$(timeout 5 kubectl get nodes --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")

    # Get node details (with timeout)
    NODE_DETAILS=$(timeout 5 kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.name)|\(.status.nodeInfo.osImage)|\(.status.nodeInfo.kernelVersion)|\(.status.capacity.cpu)|\(.status.capacity.memory)"' 2>/dev/null || echo "")

    # CNI check (with timeout)
    CNI_TYPE="확인 불가"
    if timeout 5 kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null; then
        CNI_TYPE="Cilium"
    elif timeout 5 kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
        CNI_TYPE="Calico"
    elif timeout 5 kubectl get pods -n kube-flannel &>/dev/null; then
        CNI_TYPE="Flannel"
    fi

    # Storage class check (with timeout)
    STORAGE_CLASSES=$(timeout 5 kubectl get storageclass --no-headers 2>/dev/null | awk '{print $1}' | paste -sd "," - 2>/dev/null || echo "확인 불가")

    # GPU Operator check (with timeout)
    GPU_OPERATOR="미설치"
    if timeout 5 kubectl get deployment -n gpu-operator nvidia-operator-validator &>/dev/null; then
        GPU_OPERATOR="설치됨"
    fi

    log_success "클러스터 정보 수집 완료"
}

# Collect Runway platform information
collect_runway_info() {
    log_info "Runway 플랫폼 정보를 수집합니다..."

    # Check if Runway is installed (with timeout)
    RUNWAY_INSTALLED="미설치"
    RUNWAY_VERSION="확인 불가"

    if timeout 5 kubectl get namespace runway &>/dev/null; then
        RUNWAY_INSTALLED="설치됨"
        RUNWAY_VERSION=$(timeout 5 kubectl get deployment -n runway runway-operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2 2>/dev/null || echo "확인 불가")
    fi

    # KServe check (with timeout)
    KSERVE_INSTALLED="미설치"
    if timeout 5 kubectl get namespace kserve &>/dev/null; then
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
            margin: 20mm;
        }

        @media print {
            body {
                margin: 0;
                padding: 0;
                background: white;
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

        body {
            font-family: 'Malgun Gothic', '맑은 고딕', sans-serif;
            font-size: 11pt;
            line-height: 1.6;
            color: #000;
            background: #fff;
            max-width: 210mm;
            margin: 0 auto;
            padding: 20mm;
        }

        /* 흑백 출력 최적화 */
        h1, h2, h3, h4, h5, h6 {
            color: #000;
            font-weight: bold;
            margin-top: 1.5em;
            margin-bottom: 0.5em;
        }

        h1 {
            font-size: 24pt;
            text-align: center;
            border-bottom: 2px solid #000;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }

        h2 {
            font-size: 16pt;
            border-bottom: 1px solid #000;
            padding-bottom: 5px;
        }

        h3 {
            font-size: 13pt;
        }

        h4 {
            font-size: 12pt;
        }

        /* 표지 스타일 */
        .cover-page {
            text-align: center;
            padding: 50mm 0;
        }

        .cover-title {
            font-size: 28pt;
            font-weight: bold;
            margin-bottom: 30mm;
            border: none;
        }

        .cover-info {
            font-size: 14pt;
            line-height: 2.5;
            margin-top: 30mm;
        }

        .cover-info-row {
            margin: 10px 0;
        }

        .cover-label {
            display: inline-block;
            width: 100px;
            font-weight: bold;
            text-align: right;
            margin-right: 20px;
        }

        /* 테이블 스타일 (흑백 최적화) */
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 15px 0;
            font-size: 10pt;
        }

        th, td {
            border: 1px solid #000;
            padding: 8px;
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
            margin-left: 20px;
            margin-bottom: 10px;
        }

        li {
            margin: 5px 0;
        }

        /* 섹션 번호 */
        .section-number {
            font-weight: bold;
            margin-right: 10px;
        }

        /* 요약 박스 */
        .summary-box {
            border: 2px solid #000;
            padding: 15px;
            margin: 20px 0;
            background-color: #f9f9f9;
        }

        .summary-item {
            margin: 8px 0;
            font-size: 11pt;
        }

        .summary-label {
            font-weight: bold;
            display: inline-block;
            width: 150px;
        }

        /* 주의사항 박스 */
        .notice-box {
            border: 1px solid #666;
            padding: 10px;
            margin: 15px 0;
            background-color: #f0f0f0;
        }

        .notice-title {
            font-weight: bold;
            margin-bottom: 5px;
        }

        /* 페이지 번호 영역 (인쇄용) */
        .page-footer {
            position: fixed;
            bottom: 10mm;
            right: 10mm;
            font-size: 9pt;
            color: #666;
        }

        /* 문단 스타일 */
        p {
            margin: 10px 0;
            text-align: justify;
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
    </style>
</head>
<body>
HTMLEOF

    # Add cover page
    add_cover_page "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

    # Add executive summary
    add_executive_summary "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

    # Add check summary table
    add_check_summary_table "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

    # Add Kubernetes cluster details
    add_kubernetes_details "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

    # Add Runway platform details
    add_runway_details "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

    # Add issue list
    add_issue_list "$html_file"

    # Add page break
    echo '<div class="page-break"></div>' >> "$html_file"

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
        <h1 class="cover-title">Kubernetes 클러스터 및<br>Runway 플랫폼<br>기술 점검 보고서</h1>

        <div class="cover-info">
            <div class="cover-info-row">
                <span class="cover-label">대상 기관:</span>
                <span>${ORGANIZATION}</span>
            </div>
            <div class="cover-info-row">
                <span class="cover-label">작성자:</span>
                <span>${AUTHOR_NAME}</span>
            </div>
            <div class="cover-info-row">
                <span class="cover-label">작성일:</span>
                <span>${REPORT_DATE}</span>
            </div>
            <div class="cover-info-row">
                <span class="cover-label">문서 버전:</span>
                <span>${REPORT_VERSION}</span>
            </div>
        </div>
    </div>
COVEREOF
}

# Add executive summary
add_executive_summary() {
    local html_file="$1"

    # Determine overall assessment
    local assessment=""
    if [[ "$OVERALL_STATUS" == "SUCCESS" ]]; then
        assessment="전체적으로 클러스터 상태가 양호합니다."
    elif [[ "$OVERALL_STATUS" == "WARNING" ]]; then
        assessment="일부 주의가 필요한 항목이 발견되었습니다."
    else
        assessment="심각한 문제가 발견되어 즉시 조치가 필요합니다."
    fi

    cat >> "$html_file" << SUMMARYEOF
    <h2><span class="section-number">1.</span>보고서 요약 (Executive Summary)</h2>

    <h3><span class="section-number">1.1.</span>점검 목적</h3>
    <p>
    본 보고서는 ${ORGANIZATION}의 Kubernetes 클러스터 및 MakinaRocks Runway 플랫폼의 운영 안정성, 구성 적합성, 리스크 요인 및 개선사항을 점검한 결과를 문서화합니다.
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

    <h3><span class="section-number">1.3.</span>핵심 결론</h3>
    <div class="summary-box">
        <div class="summary-item">
            <span class="summary-label">점검 일시:</span>${REPORT_DATE}
        </div>
        <div class="summary-item">
            <span class="summary-label">총 점검 항목:</span>${TOTAL_CHECKS}개
        </div>
        <div class="summary-item">
            <span class="summary-label">정상:</span>${SUCCESS_COUNT}개
        </div>
        <div class="summary-item">
            <span class="summary-label">주의:</span>${WARNING_COUNT}개
        </div>
        <div class="summary-item">
            <span class="summary-label">위험:</span>${FAILED_COUNT}개
        </div>
        <div class="summary-item">
            <span class="summary-label">정상률:</span>${SUCCESS_RATE}%
        </div>
        <div class="summary-item">
            <span class="summary-label">종합 평가:</span>${assessment}
        </div>
    </div>

    <h3><span class="section-number">1.4.</span>주요 리스크 및 개선 권고 요약</h3>
SUMMARYEOF

    # Add risk summary based on check results
    if [[ $FAILED_COUNT -gt 0 ]]; then
        cat >> "$html_file" << RISKEOF
    <ul>
        <li><strong>고위험:</strong> ${FAILED_COUNT}개 항목에서 심각한 문제가 발견되었습니다. 즉시 조치가 필요합니다.</li>
RISKEOF
    fi

    if [[ $WARNING_COUNT -gt 0 ]]; then
        cat >> "$html_file" << RISKEOF
        <li><strong>중위험:</strong> ${WARNING_COUNT}개 항목에서 주의가 필요한 상태가 확인되었습니다. 모니터링 및 개선 계획 수립이 권장됩니다.</li>
RISKEOF
    fi

    cat >> "$html_file" << RISKEOF
        <li><strong>지속적 모니터링:</strong> 정상 항목도 주기적인 점검을 통해 안정성을 유지해야 합니다.</li>
        <li><strong>용량 계획:</strong> 리소스 사용률 추이를 분석하여 중장기 확장 계획을 수립해야 합니다.</li>
    </ul>
RISKEOF
}

# Add check summary table
add_check_summary_table() {
    local html_file="$1"

    cat >> "$html_file" << TABLEEOF
    <h2><span class="section-number">2.</span>점검 항목 및 결과 요약</h2>

    <p>다음은 수행된 모든 점검 항목의 결과를 요약한 표입니다. 각 항목별 상세 내용은 후속 섹션에서 다룹니다.</p>

    <table>
        <thead>
            <tr>
                <th style="width: 5%;">No.</th>
                <th style="width: 20%;">점검 항목</th>
                <th style="width: 25%;">점검 기준</th>
                <th style="width: 10%;">점검 결과</th>
                <th style="width: 30%;">요약 설명</th>
                <th style="width: 10%;">리스크 등급</th>
            </tr>
        </thead>
        <tbody>
TABLEEOF

    # Parse check results from JSON
    local check_index=1
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드" "URL 연결성" "Rook-Ceph 클러스터" "Harbor 디스크 사용량" "Minio 디스크 사용량")
    local check_criteria=("모든 노드가 Ready 상태" "모든 파드가 Running 상태" "모든 디플로이먼트가 정상 복제" "모든 서비스에 엔드포인트 존재" "모든 PVC가 Bound 상태" "모든 Ingress가 백엔드 연결" "외부 URL 접근 가능" "Ceph HEALTH_OK 상태" "디스크 사용률 80% 미만" "디스크 사용률 80% 미만")

    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local check_title="${check_titles[$i]}"
        local check_criterion="${check_criteria[$i]}"

        local status=$(jq -r ".check_results.${check_name}.status // \"UNKNOWN\"" "$JSON_INPUT")
        local details=$(jq -r ".check_results.${check_name}.details // \"정보 없음\"" "$JSON_INPUT" | sed 's/"/\&quot;/g')

        # Determine status display and risk level
        local status_display=""
        local risk_level=""

        case "$status" in
            "SUCCESS")
                status_display='<span class="status-success">정상</span>'
                risk_level='<span class="risk-low">하</span>'
                ;;
            "WARNING")
                status_display='<span class="status-warning">주의</span>'
                risk_level='<span class="risk-medium">중</span>'
                ;;
            "FAILED")
                status_display='<span class="status-failed">위험</span>'
                risk_level='<span class="risk-high">상</span>'
                ;;
            *)
                status_display='<span>미확인</span>'
                risk_level='<span class="risk-medium">중</span>'
                ;;
        esac

        # Truncate details for summary table
        local summary_details=$(echo "$details" | cut -c1-100)
        if [[ ${#details} -gt 100 ]]; then
            summary_details="${summary_details}..."
        fi

        cat >> "$html_file" << ROWEOF
            <tr>
                <td style="text-align: center;">${check_index}</td>
                <td><strong>${check_title}</strong></td>
                <td>${check_criterion}</td>
                <td style="text-align: center;">${status_display}</td>
                <td>${summary_details}</td>
                <td style="text-align: center;">${risk_level}</td>
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
    <h2><span class="section-number">3.</span>Kubernetes Cluster 점검 상세</h2>

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

    <table>
        <thead>
            <tr>
                <th>노드명</th>
                <th>OS</th>
                <th>커널 버전</th>
                <th>CPU</th>
                <th>메모리</th>
            </tr>
        </thead>
        <tbody>
K8SEOF

    # Add node details
    if [[ -n "$NODE_DETAILS" ]]; then
        while IFS='|' read -r name os kernel cpu memory; do
            cat >> "$html_file" << NODEEOF
            <tr>
                <td>${name}</td>
                <td>${os}</td>
                <td>${kernel}</td>
                <td>${cpu} cores</td>
                <td>${memory}</td>
            </tr>
NODEEOF
        done <<< "$NODE_DETAILS"
    else
        cat >> "$html_file" << NODEEOF
            <tr>
                <td colspan="5" style="text-align: center;">노드 정보를 확인할 수 없습니다.</td>
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
            <li>Kubernetes 버전은 정기적으로 업데이트하여 보안 패치를 적용해야 합니다.</li>
            <li>노드의 OS 및 커널 버전도 최신 상태를 유지하는 것이 권장됩니다.</li>
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
    <h2><span class="section-number">4.</span>Runway 플랫폼 점검 상세</h2>

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
    <h2><span class="section-number">5.</span>문제 발견 사항 (이슈 리스트)</h2>

    <p>점검 결과 발견된 주의 및 위험 항목에 대한 상세 분석입니다.</p>

    <table>
        <thead>
            <tr>
                <th style="width: 8%;">이슈 ID</th>
                <th style="width: 15%;">항목</th>
                <th style="width: 30%;">현상</th>
                <th style="width: 20%;">영향도</th>
                <th style="width: 27%;">개선 방안</th>
            </tr>
        </thead>
        <tbody>
ISSUEEOF

    # Collect issues from WARNING and FAILED checks
    local issue_id=1
    local check_names=("nodes" "pods" "deployments" "services" "storage" "ingress" "url_check" "rook_ceph" "harbor_disk" "minio_disk")
    local check_titles=("노드 상태" "파드 상태" "디플로이먼트 상태" "서비스 엔드포인트" "스토리지 (PV/PVC)" "Ingress 백엔드" "URL 연결성" "Rook-Ceph 클러스터" "Harbor 디스크 사용량" "Minio 디스크 사용량")

    local has_issues=false

    for i in "${!check_names[@]}"; do
        local check_name="${check_names[$i]}"
        local check_title="${check_titles[$i]}"

        local status=$(jq -r ".check_results.${check_name}.status // \"UNKNOWN\"" "$JSON_INPUT")
        local details=$(jq -r ".check_results.${check_name}.details // \"정보 없음\"" "$JSON_INPUT" | sed 's/"/\&quot;/g')

        if [[ "$status" == "WARNING" || "$status" == "FAILED" ]]; then
            has_issues=true

            local impact=""
            local solution=""

            # Determine impact and solution based on check type
            case "$check_name" in
                "nodes")
                    impact="클러스터 전체 안정성에 영향"
                    solution="노드 상태 점검 및 재시작, kubelet 로그 확인"
                    ;;
                "pods")
                    impact="애플리케이션 서비스 장애 가능성"
                    solution="파드 로그 확인, 리소스 부족 여부 점검"
                    ;;
                "deployments")
                    impact="서비스 가용성 저하"
                    solution="디플로이먼트 설정 검토, 이미지 및 리소스 확인"
                    ;;
                "services")
                    impact="네트워크 연결 불가"
                    solution="파드 셀렉터 확인, 파드 상태 점검"
                    ;;
                "storage")
                    impact="데이터 저장 불가"
                    solution="PV/PVC 바인딩 상태 확인, 스토리지 클래스 검토"
                    ;;
                "ingress")
                    impact="외부 접근 불가"
                    solution="Ingress 컨트롤러 상태 확인, 백엔드 서비스 점검"
                    ;;
                "url_check")
                    impact="외부 연결성 문제"
                    solution="네트워크 정책, DNS 설정, 방화벽 규칙 확인"
                    ;;
                "rook_ceph")
                    impact="스토리지 클러스터 안정성 저하"
                    solution="Ceph 클러스터 상태 점검, OSD 및 Mon 상태 확인"
                    ;;
                "harbor_disk"|"minio_disk")
                    impact="디스크 공간 부족으로 서비스 중단 가능"
                    solution="디스크 용량 확장, 불필요한 데이터 정리"
                    ;;
            esac

            cat >> "$html_file" << ISSUEROWEOF
            <tr>
                <td style="text-align: center;">ISS-$(printf "%03d" $issue_id)</td>
                <td><strong>${check_title}</strong></td>
                <td>${details}</td>
                <td>${impact}</td>
                <td>${solution}</td>
            </tr>
ISSUEROWEOF
            ((issue_id++))
        fi
    done

    if [[ "$has_issues" == "false" ]]; then
        cat >> "$html_file" << NOISSUEEOF
            <tr>
                <td colspan="5" style="text-align: center;">발견된 주요 이슈가 없습니다. 모든 항목이 정상 상태입니다.</td>
            </tr>
NOISSUEEOF
    fi

    cat >> "$html_file" << ISSUEENDEOF
        </tbody>
    </table>
ISSUEENDEOF
}

# Add final conclusion
add_final_conclusion() {
    local html_file="$1"

    cat >> "$html_file" << CONCLUSIONEOF
    <h2><span class="section-number">6.</span>최종 결론 및 종합 권고사항</h2>

    <h3><span class="section-number">6.1.</span>안정성</h3>
    <p>
CONCLUSIONEOF

    if [[ $FAILED_COUNT -eq 0 && $WARNING_COUNT -eq 0 ]]; then
        cat >> "$html_file" << STABILITYEOF
    클러스터의 모든 구성 요소가 정상적으로 동작하고 있으며, 현재 안정성은 양호한 것으로 평가됩니다.
    다만, 지속적인 모니터링을 통해 안정성을 유지하는 것이 중요합니다.
STABILITYEOF
    elif [[ $FAILED_COUNT -eq 0 ]]; then
        cat >> "$html_file" << STABILITYEOF
    클러스터의 전반적인 안정성은 양호하나, 일부 주의가 필요한 항목이 발견되었습니다.
    해당 항목들에 대한 모니터링을 강화하고, 필요 시 개선 조치를 취해야 합니다.
STABILITYEOF
    else
        cat >> "$html_file" << STABILITYEOF
    클러스터에서 ${FAILED_COUNT}개의 심각한 문제가 발견되었습니다.
    이는 안정성에 직접적인 영향을 미칠 수 있으므로 즉시 조치가 필요합니다.
STABILITYEOF
    fi

    cat >> "$html_file" << PERFEOF
    </p>

    <h3><span class="section-number">6.2.</span>성능</h3>
    <p>
    현재 점검에서는 기본적인 상태 확인을 수행하였으며, 성능 관련 세부 메트릭(CPU/메모리 사용률, 응답 시간 등)은
    별도의 모니터링 시스템(Prometheus, Grafana 등)을 통해 지속적으로 추적해야 합니다.
    리소스 사용률이 지속적으로 높은 경우 스케일링 계획을 수립해야 합니다.
    </p>

    <h3><span class="section-number">6.3.</span>보안</h3>
    <p>
    본 점검에서는 기본적인 구성 요소의 상태만을 확인하였습니다.
    보안 강화를 위해 다음 사항을 추가로 점검할 것을 권장합니다:
    </p>
    <ul>
        <li>Network Policy 적용 현황 및 Pod 간 통신 제한</li>
        <li>RBAC 설정 검토 및 최소 권한 원칙 적용</li>
        <li>Pod Security Standards (PSS) 적용</li>
        <li>컨테이너 이미지 취약점 스캔</li>
        <li>Secrets 관리 방식 (외부 Vault 연동 등)</li>
        <li>감사 로그 (Audit Log) 활성화 및 모니터링</li>
    </ul>

    <h3><span class="section-number">6.4.</span>운영 관점</h3>
    <p>
    효율적인 운영을 위해 다음 사항을 권장합니다:
    </p>
    <ul>
        <li>정기적인 클러스터 상태 점검 자동화 (일일/주간 점검)</li>
        <li>로그 중앙화 및 장기 보관 정책 수립</li>
        <li>알림 체계 구축 (Slack, Email 등 연동)</li>
        <li>백업 및 재해 복구 계획 수립</li>
        <li>운영 문서화 및 런북(Runbook) 작성</li>
    </ul>

    <h3><span class="section-number">6.5.</span>확장성</h3>
    <p>
    향후 워크로드 증가에 대비하여 다음과 같은 확장 계획을 수립할 것을 권장합니다:
    </p>
    <ul>
        <li>노드 Auto-scaling 구성 (Cluster Autoscaler)</li>
        <li>워크로드 Auto-scaling 구성 (HPA, VPA)</li>
        <li>스토리지 용량 증설 계획 (현재 사용률 기반)</li>
        <li>네트워크 대역폭 모니터링 및 확장 계획</li>
    </ul>

    <h3><span class="section-number">6.6.</span>중장기 개선 제안</h3>
    <ul>
        <li><strong>모니터링 강화:</strong> Prometheus, Grafana, Loki 등을 통한 종합 모니터링 시스템 구축</li>
        <li><strong>GitOps 도입:</strong> ArgoCD, FluxCD 등을 활용한 선언적 배포 자동화</li>
        <li><strong>서비스 메시:</strong> Istio, Linkerd 등을 통한 마이크로서비스 관리 고도화</li>
        <li><strong>비용 최적화:</strong> 리소스 사용률 분석 및 Right-sizing 수행</li>
        <li><strong>멀티 클러스터 관리:</strong> 클러스터 확장 시 통합 관리 방안 검토</li>
    </ul>

    <div class="summary-box" style="margin-top: 30px;">
        <h4>종합 평가</h4>
        <p>
        ${ORGANIZATION}의 Kubernetes 클러스터는 전반적으로
PERFEOF

    if [[ "$OVERALL_STATUS" == "SUCCESS" ]]; then
        echo "안정적으로 운영되고 있는 것으로 평가됩니다." >> "$html_file"
    elif [[ "$OVERALL_STATUS" == "WARNING" ]]; then
        echo "대체로 양호하나 일부 개선이 필요한 것으로 평가됩니다." >> "$html_file"
    else
        echo "즉각적인 조치가 필요한 것으로 평가됩니다." >> "$html_file"
    fi

    cat >> "$html_file" << CONCLUSIONENDEOF
        본 보고서에서 제시한 권고사항들을 단계적으로 적용하여 안정성, 보안, 성능을 지속적으로 개선할 것을 권장합니다.
        </p>
    </div>

    <div style="margin-top: 50px; text-align: right;">
        <p><strong>보고서 작성자: ${AUTHOR_NAME}</strong></p>
        <p>작성일: ${REPORT_DATE}</p>
    </div>
CONCLUSIONENDEOF
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
    if [[ -z "$JSON_INPUT" ]]; then
        run_health_check
    else
        if [[ ! -f "$JSON_INPUT" ]]; then
            log_error "JSON 파일을 찾을 수 없습니다: $JSON_INPUT"
            exit 1
        fi
        log_info "입력 JSON 파일: $JSON_INPUT"
    fi

    # Collect cluster information
    collect_cluster_info

    # Collect Runway information
    collect_runway_info

    # Parse JSON data
    parse_json_data

    # Generate HTML report
    html_file=$(generate_html_report)

    echo
    log_success "공식 보고서가 생성되었습니다: $html_file"
    echo
    echo "========================================"
    echo "다음 명령어로 PDF로 변환할 수 있습니다:"
    echo "  wkhtmltopdf $html_file ${html_file%.html}.pdf"
    echo "또는 브라우저에서 열어 인쇄 기능을 사용하세요."
    echo "========================================"
}

# Run main function
main "$@"
