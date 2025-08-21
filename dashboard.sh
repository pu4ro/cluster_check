#!/bin/bash

# 실시간 Kubernetes 클러스터 대시보드
# 터미널에서 실시간 모니터링을 위한 대시보드

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# 진행률 바 생성 함수
create_progress_bar() {
    local percentage=$1
    local width=20
    local filled=$(( percentage * width / 100 ))
    local empty=$(( width - filled ))
    
    local color
    if [[ $percentage -ge 90 ]]; then
        color=$RED
    elif [[ $percentage -ge 80 ]]; then
        color=$YELLOW
    elif [[ $percentage -ge 50 ]]; then
        color=$BLUE
    else
        color=$GREEN
    fi
    
    printf "${color}["
    printf "%*s" "$filled" | tr ' ' '█'
    printf "%*s" "$empty" | tr ' ' '░'
    printf "] %3d%%${NC}" "$percentage"
}

# 상태 아이콘 반환
get_status_icon() {
    local status=$1
    case "$status" in
        "SUCCESS") echo -e "${GREEN}✅${NC}" ;;
        "WARNING") echo -e "${YELLOW}⚠️${NC}" ;;
        "FAILED") echo -e "${RED}❌${NC}" ;;
        *) echo -e "${BLUE}❓${NC}" ;;
    esac
}

# kubectl 명령어 실행 함수
kubectl_cmd() {
    kubectl "$@" 2>/dev/null
}

# 노드 상태 확인
check_nodes() {
    echo -e "\n${BOLD}🖥️  노드 상태${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local nodes_info=$(kubectl_cmd get nodes -o json)
    local node_count=$(echo "$nodes_info" | jq -r '.items | length')
    local ready_count=0
    
    echo "$nodes_info" | jq -r '.items[] | "\(.metadata.name) \(.status.conditions[-1].type) \(.status.conditions[-1].status)"' | while read -r name condition status; do
        if [[ "$condition" == "Ready" && "$status" == "True" ]]; then
            echo -e "  ${GREEN}✅${NC} $name - Ready"
            ((ready_count++))
        else
            echo -e "  ${RED}❌${NC} $name - $condition/$status"
        fi
    done
    
    echo -e "\n  📊 총 노드: $node_count개"
}

# 파드 상태 확인
check_pods() {
    echo -e "\n${BOLD}📦 파드 상태${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pod_stats=$(kubectl_cmd get pods -A --no-headers | awk '{print $4}' | sort | uniq -c)
    local total_pods=$(kubectl_cmd get pods -A --no-headers | wc -l)
    local running_pods=$(kubectl_cmd get pods -A --no-headers | grep "Running" | wc -l)
    
    echo "$pod_stats" | while read -r count status; do
        local icon
        case "$status" in
            "Running") icon="${GREEN}🟢${NC}" ;;
            "Pending") icon="${YELLOW}🟡${NC}" ;;
            "Failed"|"Error"|"CrashLoopBackOff") icon="${RED}🔴${NC}" ;;
            *) icon="${BLUE}🟦${NC}" ;;
        esac
        echo -e "  $icon $status: $count개"
    done
    
    local success_rate=$(( running_pods * 100 / total_pods ))
    echo -e "\n  📊 전체 파드: $total_pods개 | 실행 중: $running_pods개"
    echo -e "  🎯 성공률: $(create_progress_bar $success_rate)"
}

# Rook-Ceph 상태 확인
check_rook_ceph() {
    echo -e "\n${BOLD}💿 Rook-Ceph 클러스터${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local tools_pod=$(kubectl_cmd get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$tools_pod" ]]; then
        echo -e "  ${YELLOW}⚠️${NC} rook-ceph-tools 파드를 찾을 수 없음"
        return
    fi
    
    local ceph_status=$(kubectl_cmd exec -n rook-ceph "$tools_pod" -- ceph -s --format json 2>/dev/null)
    local health_status=$(echo "$ceph_status" | jq -r '.health.status // "UNKNOWN"')
    
    case "$health_status" in
        "HEALTH_OK") echo -e "  ${GREEN}✅${NC} Ceph 클러스터: 정상 (HEALTH_OK)" ;;
        "HEALTH_WARN") echo -e "  ${YELLOW}⚠️${NC} Ceph 클러스터: 경고 (HEALTH_WARN)" ;;
        "HEALTH_ERR") echo -e "  ${RED}❌${NC} Ceph 클러스터: 오류 (HEALTH_ERR)" ;;
        *) echo -e "  ${BLUE}❓${NC} Ceph 클러스터: 상태 확인 불가" ;;
    esac
}

# 스토리지 디스크 사용량 확인
check_storage_usage() {
    echo -e "\n${BOLD}💾 스토리지 디스크 사용량${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Harbor 디스크 사용량
    echo -e "  ${CYAN}⚓${NC} Harbor Registry:"
    local harbor_pod=$(kubectl_cmd get pods -n harbor -l app=harbor,component=registry -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "$harbor_pod" ]]; then
        local harbor_disk=$(kubectl_cmd exec -n harbor "$harbor_pod" -- df -h 2>/dev/null | grep "rbd" | head -1)
        if [[ -n "$harbor_disk" ]]; then
            local harbor_percent=$(echo "$harbor_disk" | awk '{print $5}' | sed 's/%//')
            local harbor_used=$(echo "$harbor_disk" | awk '{print $3}')
            local harbor_total=$(echo "$harbor_disk" | awk '{print $2}')
            echo -e "    $(create_progress_bar $harbor_percent) ($harbor_used/$harbor_total)"
        else
            echo -e "    ${YELLOW}⚠️${NC} 디스크 사용량 확인 불가"
        fi
    else
        echo -e "    ${YELLOW}⚠️${NC} Harbor 파드를 찾을 수 없음"
    fi
    
    # Minio 디스크 사용량
    echo -e "  ${PURPLE}🗄️${NC} Minio Storage:"
    local minio_pod=$(kubectl_cmd get pods -n minio -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "$minio_pod" ]]; then
        local minio_disk=$(kubectl_cmd exec -n minio "$minio_pod" -- df -h 2>/dev/null | grep "rbd" | head -1)
        if [[ -n "$minio_disk" ]]; then
            local minio_percent=$(echo "$minio_disk" | awk '{print $5}' | sed 's/%//')
            local minio_used=$(echo "$minio_disk" | awk '{print $3}')
            local minio_total=$(echo "$minio_disk" | awk '{print $2}')
            echo -e "    $(create_progress_bar $minio_percent) ($minio_used/$minio_total)"
        else
            echo -e "    ${YELLOW}⚠️${NC} 디스크 사용량 확인 불가"
        fi
    else
        echo -e "    ${YELLOW}⚠️${NC} Minio 파드를 찾을 수 없음"
    fi
}

# 네임스페이스별 리소스 요약
check_namespace_summary() {
    echo -e "\n${BOLD}🏷️  네임스페이스별 리소스${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    kubectl_cmd get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | while read -r count namespace; do
        local running=$(kubectl_cmd get pods -n "$namespace" --no-headers | grep "Running" | wc -l)
        local total=$count
        local percentage=$(( running * 100 / total ))
        
        printf "  %-20s " "$namespace:"
        create_progress_bar $percentage
        echo " ($running/$total)"
    done
}

# 최근 이벤트 확인
check_recent_events() {
    echo -e "\n${BOLD}📋 최근 이벤트 (최근 10분)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local events=$(kubectl_cmd get events -A --sort-by='.firstTimestamp' --no-headers | tail -5)
    
    if [[ -z "$events" ]]; then
        echo -e "  ${GREEN}✅${NC} 최근 중요한 이벤트 없음"
    else
        echo "$events" | while IFS= read -r line; do
            local type=$(echo "$line" | awk '{print $6}')
            local icon
            case "$type" in
                "Normal") icon="${GREEN}ℹ️${NC}" ;;
                "Warning") icon="${YELLOW}⚠️${NC}" ;;
                *) icon="${RED}❗${NC}" ;;
            esac
            echo -e "  $icon $(echo "$line" | awk '{print $1, $2, $6, $7, $8}')"
        done
    fi
}

# 헤더 출력
print_header() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local cluster_info=$(kubectl_cmd cluster-info | head -1 | grep -o 'https://[^[:space:]]*')
    
    clear
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║                       🚀 Kubernetes 클러스터 실시간 대시보드                        ║${NC}"
    echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${BLUE}║${NC} ⏰ $timestamp                                                          ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}║${NC} 🌐 클러스터: ${cluster_info:-Local}                                         ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

# 푸터 출력
print_footer() {
    echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}💡 실시간 모드: 30초마다 자동 새로고침 | Ctrl+C로 종료${NC}"
    echo -e "${BOLD}${BLUE}📊 상세 리포트: ./k8s_health_check.sh --format html${NC}"
}

# 메인 대시보드 함수
show_dashboard() {
    print_header
    
    check_nodes
    check_pods
    check_rook_ceph
    check_storage_usage
    check_namespace_summary
    check_recent_events
    
    print_footer
}

# 사용법 출력
show_usage() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  -w, --watch     실시간 모드 (30초마다 새로고침)"
    echo "  -o, --once      한 번만 실행"
    echo "  -h, --help      도움말 출력"
    echo ""
    echo "예시:"
    echo "  $0 --watch      # 실시간 대시보드 시작"
    echo "  $0 --once       # 현재 상태만 표시"
}

# 실시간 모드
watch_mode() {
    echo -e "${GREEN}🚀 실시간 대시보드를 시작합니다... (Ctrl+C로 종료)${NC}"
    sleep 2
    
    while true; do
        show_dashboard
        sleep 30
    done
}

# 메인 실행부
main() {
    case "${1:-}" in
        -w|--watch)
            watch_mode
            ;;
        -o|--once)
            show_dashboard
            ;;
        -h|--help)
            show_usage
            ;;
        "")
            # 기본적으로 한 번 실행
            show_dashboard
            ;;
        *)
            echo "알 수 없는 옵션: $1"
            show_usage
            exit 1
            ;;
    esac
}

# 시그널 처리 (Ctrl+C)
trap 'echo -e "\n${GREEN}👋 대시보드를 종료합니다.${NC}"; exit 0' SIGINT SIGTERM

# 스크립트 실행
main "$@"