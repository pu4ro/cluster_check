# Kubernetes Cluster Health Check

고급 Kubernetes 클러스터 상태 점검 스크립트입니다. 구조적 개선, 병렬 처리, 리소스 모니터링, HTML 리포트 생성 기능을 제공합니다.

## 🚀 주요 기능

### ⚡ 고급 기능
- **모듈화된 구조**: 각 점검 항목을 별도 함수로 분리
- **병렬 처리**: 독립적인 점검 항목들을 동시 실행으로 성능 최적화
- **리소스 모니터링**: 노드별 상세 리소스 사용률 분석
- **시각적 리포트**: HTML 대시보드와 JSON 데이터 출력
- **Chart.js 통합**: 실시간 도넛 차트와 진행률 바 시각화
- **스토리지 모니터링**: Harbor, Minio 디스크 사용량 실시간 추적

### 📊 모니터링 항목
- **노드별 Pod 사용률**: 현재 Pod 수 / 최대 Pod 수 (%)
- **CPU 사용률**: CPU 요청량 / 할당 가능 CPU (%)
- **Memory 사용률**: 메모리 요청량 / 할당 가능 메모리 (%)
- **GPU 사용률**: GPU 리소스 사용률 (GPU 노드의 경우)
- **Harbor 디스크 사용률**: Harbor Registry 스토리지 사용량
- **Minio 디스크 사용률**: Minio 오브젝트 스토리지 사용량

### 🔍 점검 항목 (총 10개)
1. **클러스터 노드 상태**: 모든 노드의 Ready 상태 확인
2. **파드 상태**: 전체 네임스페이스의 파드 상태 점검
3. **디플로이먼트 상태**: 디플로이먼트 복제본 상태 확인
4. **서비스 엔드포인트**: 서비스별 엔드포인트 연결 상태 검증
5. **스토리지 상태**: PV/PVC 바인딩 상태 확인
6. **Ingress 백엔드**: Ingress 규칙의 백엔드 서비스 연결성
7. **URL 연결 테스트**: 외부 URL 접근성 확인
8. **Rook-Ceph 클러스터**: Ceph 스토리지 클러스터 상태 모니터링
9. **Harbor 디스크 사용량**: 컨테이너 레지스트리 스토리지 모니터링
10. **Minio 디스크 사용량**: 오브젝트 스토리지 용량 모니터링

## 📁 파일 구성

```
cluster_check/
├── k8s_health_check.sh        # 메인 점검 스크립트 ⭐
├── k8s_check.sh               # 기본 점검 스크립트
├── k8s_check_advanced.sh      # 레거시 고도화 스크립트
├── config.conf                # 설정 파일 (자동 생성)
├── reports/                   # 리포트 저장 디렉토리
│   ├── k8s_check_*.log       # 상세 로그
│   ├── k8s_report_*.html     # HTML 리포트
│   └── k8s_report_*.json     # JSON 데이터
└── README.md                  # 이 파일
```

## 🛠️ 사용법

### 기본 실행
```bash
# 메인 스크립트 실행 (권장)
./k8s_health_check.sh

# HTML 리포트만 생성
./k8s_health_check.sh --format html

# JSON 리포트만 생성
./k8s_health_check.sh --format json

# URL 연결성 테스트 포함
./k8s_health_check.sh --url https://your-domain.com
```

### 고급 옵션
```bash
# 디버그 모드로 실행
DEBUG=true ./k8s_health_check.sh

# 특정 네임스페이스만 점검
./k8s_health_check.sh --namespace production

# 출력 디렉토리 지정
./k8s_health_check.sh --output-dir /custom/path

# 모든 옵션 보기
./k8s_health_check.sh --help
```

## ⚙️ 설정

스크립트 첫 실행 시 `config.conf` 파일이 자동으로 생성됩니다.

### 주요 설정 항목
```bash
# 점검 타임아웃 (초)
CHECK_TIMEOUT=60
NODE_CHECK_TIMEOUT=30
POD_CHECK_TIMEOUT=45

# 리소스 모니터링
ENABLE_RESOURCE_MONITORING=true
ENABLE_GPU_MONITORING=true
RESOURCE_THRESHOLD_CPU=80
RESOURCE_THRESHOLD_MEMORY=85
RESOURCE_THRESHOLD_DISK=90

# 네트워크 설정
FLANNEL_NAMESPACE="kube-flannel"
DEFAULT_PROTOCOL="https"

# 리포트 생성
GENERATE_HTML_REPORT=true
GENERATE_JSON_REPORT=true
INCLUDE_DEBUG_INFO=true

# 병렬 처리
MAX_PARALLEL_JOBS=10
```

## 📊 HTML 리포트 기능

### 대시보드 특징
- 📈 **Chart.js 도넛 차트**: 리소스 사용률을 원형 차트로 시각화
- 📊 **실시간 진행률 바**: 리소스 사용률을 막대 그래프로 표시
- 🎨 **Bootstrap 5 반응형 디자인**: 데스크톱/모바일 환경 모두 지원
- 🎯 **FontAwesome 아이콘**: 직관적인 아이콘 기반 UI
- 🔍 **상세 정보**: 각 점검 항목별 세부 결과와 해결 방법 제시
- 💾 **스토리지 모니터링**: Harbor/Minio 디스크 사용량 실시간 추적

### 리소스 표시 색상
- 🟢 **녹색 (0-50%)**: 안전 수준
- 🟡 **노란색 (50-70%)**: 주의 수준  
- 🟠 **주황색 (70-85%)**: 경고 수준
- 🔴 **빨간색 (85%+)**: 위험 수준

### 새로운 스토리지 모니터링 섹션
- **Harbor 디스크 사용량**: 컨테이너 레지스트리의 RBD 디스크 사용률
- **Minio 디스크 사용량**: 오브젝트 스토리지의 데이터 볼륨 사용률
- **실시간 차트**: 각 스토리지의 사용량을 도넛 차트와 진행률 바로 표시
- **임계값 알림**: 80% 이상 경고, 90% 이상 위험 상태로 표시

## 🔧 요구사항

### 필수 도구
- `kubectl`: Kubernetes 클러스터 접근
- `bash`: 스크립트 실행 환경
- `bc`: 퍼센트 계산용
- `jq`: JSON 처리
- `curl`: URL 연결성 테스트용

### 권한 요구사항
- Kubernetes 클러스터 읽기 권한
- 노드 정보 조회 권한
- 파드 및 리소스 조회 권한
- Rook-Ceph tools 파드 exec 권한 (Ceph 모니터링 시)
- Harbor/Minio 파드 exec 권한 (디스크 모니터링 시)

### 선택적 구성요소
- **Rook-Ceph**: `rook-ceph-tools` deployment 필요
- **Harbor**: `harbor-registry` deployment 필요  
- **Minio**: `minio` statefulset 필요

## 🎯 특수 기능

### Rook-Ceph 모니터링
- `ceph -s` 명령어를 통한 실제 Ceph 클러스터 상태 확인
- HEALTH_OK → SUCCESS, HEALTH_WARN → WARNING, HEALTH_ERR → FAILED 자동 매핑
- 상세한 Ceph 상태 정보 로깅

### 스토리지 디스크 모니터링  
- Harbor Registry와 Minio 파드에서 `df -h` 실행
- RBD 디스크 사용량 실시간 추적
- 임계값 기반 상태 판정 (80% 경고, 90% 위험)

### 서비스 엔드포인트 예외 처리
- `kserve/modelmesh-serving` 서비스 자동 제외
- 사용자 정의 제외 서비스 설정 가능

## 📝 출력 예시

### 콘솔 출력
```
🚀 Kubernetes 클러스터 포괄적 상태 점검 시작
=================================================

1/10 노드 상태 점검...
2/10 파드 상태 점검...
3/10 디플로이먼트 상태 점검...
4/10 서비스 엔드포인트 점검...
5/10 스토리지 상태 점검...
6/10 Ingress 백엔드 점검...
7/10 URL 연결 테스트...
8/10 Rook-Ceph 상태 점검...
9/10 Harbor 디스크 사용량 점검...
10/10 Minio 디스크 사용량 점검...

==================================
📊 CLUSTER HEALTH CHECK SUMMARY  
==================================
총 점검 항목: 10
✅ 성공: 9
⚠️  경고: 1
❌ 실패: 0
📈 성공률: 90.0%

📄 Reports generated:
  • HTML: ./reports/k8s_report_20250821_143022.html
  • JSON: ./reports/k8s_report_20250821_143022.json
  • Log:  ./reports/k8s_check_20250821_143022.log
==================================
```

### HTML 리포트 미리보기
- 📊 **요약 통계**: 총 점검 항목, 성공/경고/실패 수, 성공률
- 🖥️ **노드별 리소스**: Pod/CPU/Memory/GPU 사용률 도넛 차트 + 진행률 바
- 💾 **스토리지 모니터링**: Harbor/Minio 디스크 사용량 시각화
- 🔍 **상세 점검 결과**: 각 항목별 상태와 해결 방법

## 🔄 업그레이드 내역

### v3.0.0 (최신 - 스토리지 통합 모니터링)
- ✅ **Rook-Ceph 통합**: 실제 Ceph 클러스터 상태 모니터링
- ✅ **Harbor 디스크 모니터링**: 컨테이너 레지스트리 스토리지 추적
- ✅ **Minio 디스크 모니터링**: 오브젝트 스토리지 용량 모니터링  
- ✅ **Chart.js 대시보드**: 도넛 차트와 진행률 바 시각화
- ✅ **스토리지 섹션**: 전용 스토리지 모니터링 UI 추가
- ✅ **서비스 예외 처리**: kserve/modelmesh-serving 자동 제외
- ✅ **10개 점검 항목**: 기존 7개에서 3개 추가 확장
- ✅ **향상된 로깅**: 구조화된 로그와 파싱 기능

### v2.0.0 (고도화 버전)
- ✅ 구조적 개선: 모듈화된 함수 구조
- ✅ 병렬 처리: 성능 최적화된 동시 점검
- ✅ 리소스 모니터링: 노드별 상세 리소스 분석
- ✅ HTML 리포트: 시각적 대시보드 생성
- ✅ JSON 출력: 구조화된 데이터 제공

### v1.0.0 (기본 버전)
- ✅ 기본 클러스터 상태 점검
- ✅ 순차적 점검 실행
- ✅ 텍스트 기반 리포트

## 🚨 문제 해결

### 일반적인 문제들

**Q: Rook-Ceph 점검이 실패합니다**
```bash
# rook-ceph-tools 파드 확인
kubectl get pods -n rook-ceph -l app=rook-ceph-tools

# 수동으로 Ceph 상태 확인
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph -s
```

**Q: Harbor/Minio 디스크 모니터링이 동작하지 않습니다**
```bash
# Harbor 파드 확인
kubectl get pods -n harbor -l app=harbor,component=registry

# Minio 파드 확인  
kubectl get pods -n minio -l app=minio

# 수동으로 디스크 사용량 확인
kubectl exec -n harbor <pod-name> -- df -h
```

**Q: HTML 리포트가 제대로 표시되지 않습니다**
- 브라우저에서 JavaScript가 활성화되어 있는지 확인
- Chart.js CDN 연결 상태 확인
- 생성된 HTML 파일의 권한 확인

## 🤝 기여하기

이슈나 개선사항이 있으시면 언제든지 제안해주세요!

### 개발 가이드라인
- 새로운 점검 항목 추가 시 `store_result()` 함수 사용
- HTML 대시보드 수정 시 반응형 디자인 유지
- 모든 변경사항에 대해 충분한 테스트 수행

## 📄 라이선스

MIT License

---

**Made with ❤️ for Kubernetes Operations**

**Version: 3.0.0** | **Last Updated: 2025-08-21**