#!/bin/bash

# 점검 항목 결과 저장 변수
results=()

# 함수: 점검 결과를 저장
check_result() {
  local number=$1
  local name=$2
  local status=$3
  if [ "$status" -eq 0 ]; then
    results+=("$number. $name: PASS")
  else
    results+=("$number. $name: FAIL")
  fi
}

# 각 점검 항목별 디버그 설정 (true: 디버깅 활성화, false: 비활성화)
DEBUG_1=true   # 클러스터 노드 상태 확인
DEBUG_2=true   # 클러스터 파드 상태 확인
DEBUG_3=true   # 서비스 상태 확인
DEBUG_4=true   # CoreDNS 상태 확인
DEBUG_5=true   # PersistentVolume 상태 확인
DEBUG_6=true   # PersistentVolumeClaim 상태 확인
DEBUG_7=true   # 모니터링 도구 상태 확인
DEBUG_8=true   # 클러스터 이벤트 확인
DEBUG_9=true   # 네트워크 CNI 상태 확인
DEBUG_10=true  # Kubernetes 버전 상태 확인
DEBUG_11=true  # Ingress 도메인 점검
DEBUG_12=true  # Harbor 도메인 점검
DEBUG_13=true  # Runway 백엔드 서비스 점검
DEBUG_14=true  # Rook-Ceph 클러스터 상태 확인

# Ingress 서비스에 사용할 점검 도메인 입력
read -p "Ingress 점검 도메인을 입력하세요 (예: example.com): " domain
if [ -z "$domain" ]; then
  echo "도메인을 입력하지 않아 점검을 종료합니다."
  exit 1
fi

# Backend 도메인 입력 (기본값: Ingress 도메인)
read -p "Backend 도메인을 입력하세요 (기본: $domain): " backend_domain
if [ -z "$backend_domain" ]; then
  backend_domain="$domain"
fi

# Harbor 도메인을 별도 변수로 입력 받기
read -p "Harbor 도메인을 입력하세요 (예: harbor.example.com): " harbor_domain
if [ -z "$harbor_domain" ]; then
  echo "Harbor 도메인을 입력하지 않아 점검을 종료합니다."
  exit 1
fi

# Flannel 네임스페이스 입력 (기본: kube-flannel)
read -p "Flannel 네임스페이스를 입력하세요 (기본: kube-flannel): " flannel_namespace
if [ -z "$flannel_namespace" ]; then
  flannel_namespace="kube-flannel"
fi

# http 또는 https 선택
read -p "프로토콜을 선택하세요 (http 또는 https): " protocol
if [[ "$protocol" != "http" && "$protocol" != "https" ]]; then
  echo "잘못된 프로토콜 입력입니다. 'http' 또는 'https' 중 하나를 선택하세요."
  exit 1
fi

# Rook-Ceph 클러스터 점검 여부 선택
read -p "Rook-Ceph 클러스터 점검을 진행하시겠습니까? (yes/no): " ceph_choice
ceph_check=false
if [[ "$ceph_choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  ceph_check=true
fi

# 현재 날짜와 시간으로 파일 이름 생성
output_file="k8s_check_result_$(date +%Y%m%d).txt"

# 1. 노드 상태 확인
if [ "$DEBUG_1" = true ]; then echo "🔍 클러스터 노드 상태를 확인합니다..."; fi

node_status=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[-1].type} {.status.conditions[-1].status}{"\n"}{end}')
node_check="PASS"

if [ "$DEBUG_1" = true ]; then
    echo "📢 전체 노드 상태 (kubectl get nodes -o wide):"
    kubectl get nodes -o wide
    echo "📢 JSONPath 결과 (노드별 Ready 상태):"
    echo "$node_status"
fi

while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  condition=$(echo "$line" | awk '{print $2}')
  status=$(echo "$line" | awk '{print $3}')
  
  if [[ "$condition" != "Ready" || "$status" != "True" ]]; then
    node_check="FAIL"
    if [ "$DEBUG_1" = true ]; then echo "❌ 문제 발생: $name 상태 -> $condition / $status"; fi
    break
  fi
done <<< "$node_status"

check_result 1 "클러스터 노드 상태 확인" $(test "$node_check" = "PASS"; echo $?)

# 2. 클러스터 파드 상태 확인
if [ "$DEBUG_2" = true ]; then echo "🔍 클러스터 파드 상태를 확인합니다..."; fi

pod_status=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.phase}{"\n"}{end}')
pod_check="PASS"

if [ "$DEBUG_2" = true ]; then
    echo "📢 전체 파드 상태 (kubectl get pods -A -o wide):"
    kubectl get pods -A -o wide
    echo "📢 JSONPath 결과 (네임스페이스, 파드명, 상태):"
    echo "$pod_status"
fi

while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  phase=$(echo "$line" | awk '{print $3}')
  
  if [[ "$phase" != "Running" && "$phase" != "Succeeded" ]]; then
    pod_check="FAIL"
    if [ "$DEBUG_2" = true ]; then echo "❌ 문제 발생: [$ns] $name 상태 -> $phase"; fi
    break
  fi
done <<< "$pod_status"

check_result 2 "클러스터 파드 상태 확인" $(test "$pod_check" = "PASS"; echo $?)

# 3. 네트워크 - 서비스 상태 확인
kubectl get svc -A &> /dev/null
check_result 3 "서비스 상태 확인" $?

# 4. CoreDNS 상태 확인
if [ "$DEBUG_4" = true ]; then echo "🔍 CoreDNS 상태를 확인합니다..."; fi

coredns_status=$(kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep coredns)
coredns_check="PASS"

if [ "$DEBUG_4" = true ]; then
    echo "📢 전체 CoreDNS 파드 상태 (kubectl get pods -n kube-system -o wide | grep coredns):"
    kubectl get pods -n kube-system -o wide | grep coredns
    echo "📢 JSONPath 결과 (파드명, 상태):"
    echo "$coredns_status"
fi

while IFS= read -r line; do
  pod_name=$(echo "$line" | awk '{print $1}')
  phase=$(echo "$line" | awk '{print $2}')
  
  if [[ "$phase" != "Running" ]]; then
    coredns_check="FAIL"
    if [ "$DEBUG_4" = true ]; then echo "❌ 문제 발생: CoreDNS 파드 ($pod_name) 상태 -> $phase"; fi
    break
  fi
done <<< "$coredns_status"

check_result 4 "CoreDNS 상태 확인" $(test "$coredns_check" = "PASS"; echo $?)

# 5. PersistentVolume 상태 확인
pv_status=$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}')
pv_check="PASS"
while IFS= read -r line; do
  pv_name=$(echo "$line" | awk '{print $1}')
  phase=$(echo "$line" | awk '{print $2}')
  if [[ "$phase" != "Bound" ]]; then
    pv_check="FAIL"
    break
  fi
done <<< "$pv_status"
check_result 5 "PersistentVolume 상태 확인" $(test "$pv_check" = "PASS"; echo $?) "$pv_status"

# 6. PersistentVolumeClaim 상태 확인
pvc_status=$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.phase}{"\n"}{end}')
pvc_check="PASS"
while IFS= read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  pvc_name=$(echo "$line" | awk '{print $2}')
  phase=$(echo "$line" | awk '{print $3}')
  if [[ "$phase" != "Bound" ]]; then
    pvc_check="FAIL"
    break
  fi
done <<< "$pvc_status"
check_result 6 "PersistentVolumeClaim 상태 확인" $(test "$pvc_check" = "PASS"; echo $?) "$pvc_status"

# 7. 모니터링 도구 상태 확인 (Prometheus API를 통한 확인)
if [ "$DEBUG_7" = true ]; then echo "🔍 Prometheus API를 호출하여 모니터링 도구 상태를 조회합니다..."; fi
POD_NAME=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
PROMETHEUS_URL="http://localhost:9090/api/v1/query?query=up"
RESPONSE=$(kubectl exec -n monitoring "$POD_NAME" -- sh -c "wget -qO- $PROMETHEUS_URL" 2>/dev/null)
monitoring_check="PASS"
if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | jq -e .data.result >/dev/null 2>&1; then
    echo "❌ Prometheus API 응답이 없거나 올바른 JSON이 아닙니다."
    monitoring_check="FAIL"
else
    if [ "$DEBUG_7" = true ]; then echo "📋 Prometheus 응답 JSON 데이터:"; echo "$RESPONSE" | jq .; fi
    UNHEALTHY=$(echo "$RESPONSE" | jq -r '.data.result[]? | select(.metric.job | test("prometheus|grafana|datadog|alertmanager|pushgateway") and (.value[1] | tonumber == 0)) | "\(.metric.instance) - \(.metric.job)"' 2>/dev/null)
    if [ -n "$UNHEALTHY" ]; then
        echo "❗ 비정상 서비스 발견:"
        echo "$UNHEALTHY"
        monitoring_check="FAIL"
    else
        echo "✅ 모든 모니터링 도구가 정상적으로 동작하고 있습니다."
    fi
fi
check_result 7 "모니터링 도구 상태 확인" $(test "$monitoring_check" = "PASS"; echo $?) "$UNHEALTHY"

# 8. 로깅 - 클러스터 이벤트 확인
kubectl get events -A &> /dev/null
check_result 8 "클러스터 이벤트 확인" $?

# 9. 네트워크 상태 확인 (Flannel 점검)
if [ "$DEBUG_9" = true ]; then echo "🔍 네트워크 CNI (Flannel) 상태를 확인합니다..."; fi
# check-jh 버전: flannel 네임스페이스를 변수로 지정하여 사용
flannel_pods=$(kubectl get pods -n "$flannel_namespace" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep flannel)
flannel_check="PASS"
if [ "$DEBUG_9" = true ]; then
    echo "📢 전체 Flannel 파드 상태 (kubectl get pods -n $flannel_namespace -o wide | grep flannel):"
    kubectl get pods -n "$flannel_namespace" -o wide | grep flannel
fi
while IFS= read -r line; do
  pod_name=$(echo "$line" | awk '{print $1}')
  phase=$(echo "$line" | awk '{print $2}')
  if [[ "$phase" != "Running" ]]; then
    echo "❌ Flannel 파드 비정상 감지: $pod_name ($phase)"
    flannel_check="FAIL"
    break
  fi
done <<< "$flannel_pods"
if ! ip link show | grep -q flannel.1; then
  echo "❌ Flannel 네트워크 인터페이스 (flannel.1) 없음"
  flannel_check="FAIL"
fi
flannel_logs=$(kubectl logs -n "$flannel_namespace" -l app=flannel 2>&1 | grep -E "error|fail")
if [ -n "$flannel_logs" ]; then
  echo "❌ Flannel 로그에서 오류 감지"
  echo "$flannel_logs"
  flannel_check="FAIL"
fi
check_result 9 "네트워크 CNI 상태 확인" $(test "$flannel_check" = "PASS"; echo $?) "$flannel_pods"

# 10. Kubernetes 버전 상태 확인
if [ "$DEBUG_10" = true ]; then echo "🔍 Kubernetes 버전을 확인합니다..."; fi
kubectl_version=$(kubectl version --short 2>&1)
check_result 10 "Kubernetes 버전 상태 확인" $? "$kubectl_version"

# 11. Ingress 도메인 점검
if [ "$DEBUG_11" = true ]; then echo "🔍 Ingress 도메인($domain) 상태를 점검합니다..."; fi
ingress_status=$(curl -s -o /dev/null -w "%{http_code}" "$protocol://$domain")
if [ "$DEBUG_11" = true ]; then echo "📢 Ingress 응답 코드: $ingress_status"; fi
check_result 11 "Ingress 도메인($domain) 점검" $(test "$ingress_status" = "200"; echo $?) "$ingress_status"

# 12. Harbor 도메인 점검 (별도 변수 harbor_domain 사용)
if [ "$DEBUG_12" = true ]; then echo "🔍 Harbor 도메인($harbor_domain) 상태를 점검합니다..."; fi
harbor_status=$(curl -s -o /dev/null -w "%{http_code}" "$protocol://$harbor_domain")
if [ "$DEBUG_12" = true ]; then echo "📢 Harbor 응답 코드: $harbor_status"; fi
check_result 12 "Harbor 도메인($harbor_domain) 점검" $(test "$harbor_status" = "200"; echo $?) "$harbor_status"

# 13. Runway 백엔드 서비스 점검 (backend_domain 사용)
if [ "$DEBUG_13" = true ]; then echo "🔍 Runway 백엔드 서비스($backend_domain) 상태를 점검합니다..."; fi
runway_status=$(curl -s -o /dev/null -w "%{http_code}" -X 'GET' \
  "$protocol://$backend_domain/v1/healthz/livez" -H 'accept: application/json')
if [ "$DEBUG_13" = true ]; then echo "�� Runway 응답 코드: $runway_status"; fi
check_result 13 "Runway 백엔드 서비스($backend_domain) 점검" $(test "$runway_status" = "200"; echo $?) "$runway_status"

# 14. Rook-Ceph 클러스터 상태 확인 (사용자 선택에 따라 실행)
if [ "$ceph_check" = true ]; then
  if [ "$DEBUG_14" = true ]; then echo "🔍 Rook-Ceph 클러스터 상태를 확인합니다..."; fi
  CEPH_TOOLBOX_POD=$(kubectl get pod -n rook-ceph -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$CEPH_TOOLBOX_POD" ]; then
      echo "❌ Rook-Ceph Toolbox Pod을 찾을 수 없습니다."
      check_result 14 "스토리지 Rook-Ceph 클러스터 상태 확인" 1 "Rook-Ceph Toolbox Pod 없음"
  else
      CEPH_STATUS=$(kubectl exec -n rook-ceph "$CEPH_TOOLBOX_POD" -- ceph status --format json 2>/dev/null)
      if [ "$DEBUG_14" = true ]; then echo "📢 Rook-Ceph 클러스터 상태(raw JSON):"; echo "$CEPH_STATUS" | jq .; fi
      CEPH_HEALTH=$(echo "$CEPH_STATUS" | jq -r '.health.status' 2>/dev/null)
      if [ "$CEPH_HEALTH" == "HEALTH_OK" ]; then
          echo "✅ Rook-Ceph 클러스터가 정상적으로 운영 중입니다. (HEALTH_OK)"
          check_result 14 "스토리지 Rook-Ceph 클러스터 상태 확인" 0 "HEALTH_OK"
      else
          echo "❗ Rook-Ceph 클러스터 이상 감지: 상태 -> $CEPH_HEALTH"
          check_result 14 "스토리지 Rook-Ceph 클러스터 상태 확인" 1 "$CEPH_HEALTH"
      fi
  fi
else
  echo "ℹ️ Rook-Ceph 클러스터 점검을 건너뜁니다."
  results+=("14. 스토리지 Rook-Ceph 클러스터 상태 확인: SKIPPED")
fi

# 결과 출력
echo "=== Runway 클러스터 점검 결과 ==="
for result in "${results[@]}"; do
  echo "$result"
done

# 정확한 PASS/FAIL 계산
pass_count=0
fail_count=0
for result in "${results[@]}"; do
  if [[ $result == *"PASS"* ]]; then
    ((pass_count++))
  elif [[ $result == *"FAIL"* ]]; then
    ((fail_count++))
  fi
done

# 요약본 작성
echo "===  Runway 클러스터 점검 요약 ===" > "$output_file"
echo "총 점검 항목: ${#results[@]}" >> "$output_file"
echo "PASS: $pass_count" >> "$output_file"
echo "FAIL: $fail_count" >> "$output_file"
echo "=====================================" >> "$output_file"
for result in "${results[@]}"; do
  echo "$result" >> "$output_file"
done

# 화면에 요약본 출력
echo "====================================="
echo "총 점검 항목: ${#results[@]}"
echo "PASS: $pass_count"
echo "FAIL: $fail_count"
echo "결과가 파일로 저장되었습니다: $output_file"

