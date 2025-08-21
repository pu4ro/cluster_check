# Kubernetes Cluster Health Check

고급 Kubernetes 클러스터 상태 점검 스크립트입니다. 구조적 개선, 병렬 처리, 리소스 모니터링, HTML 리포트 생성 기능을 제공합니다.

## 🚀 주요 기능

### ⚡ 고급 기능
- **모듈화된 구조**: 각 점검 항목을 별도 함수로 분리
- **병렬 처리**: 독립적인 점검 항목들을 동시 실행으로 성능 최적화
- **리소스 모니터링**: 노드별 상세 리소스 사용률 분석
- **시각적 리포트**: HTML 대시보드와 JSON 데이터 출력

### 📊 모니터링 항목
- **노드별 Pod 사용률**: 현재 Pod 수 / 최대 Pod 수 (%)
- **CPU 사용률**: CPU 요청량 / 할당 가능 CPU (%)
- **Memory 사용률**: 메모리 요청량 / 할당 가능 메모리 (%)
- **GPU 사용률**: GPU 리소스 사용률 (GPU 노드의 경우)

### 🔍 점검 항목
1. **클러스터 노드 상태**: 모든 노드의 Ready 상태 확인
2. **파드 상태**: 전체 네임스페이스의 파드 상태 점검
3. **서비스 상태**: Kubernetes 서비스 접근성 확인
4. **CoreDNS 상태**: DNS 서비스 정상 동작 여부
5. **스토리지 상태**: PV/PVC 바인딩 상태 확인

## 📁 파일 구성

```
cluster_check/
├── k8s_check.sh              # 기본 점검 스크립트
├── k8s_check_advanced.sh     # 고도화된 점검 스크립트 ⭐
├── config.conf               # 설정 파일 (자동 생성)
├── reports/                  # 리포트 저장 디렉토리
│   ├── k8s_check_*.log      # 상세 로그
│   ├── k8s_report_*.html    # HTML 리포트
│   └── k8s_report_*.json    # JSON 데이터
└── README.md                 # 이 파일
```

## 🛠️ 사용법

### 기본 실행
```bash
# 고도화된 스크립트 실행 (권장)
./k8s_check_advanced.sh

# 기본 스크립트 실행
./k8s_check.sh
```

### 고급 옵션
```bash
# 디버그 모드로 실행
DEBUG=true ./k8s_check_advanced.sh

# 병렬 작업 수 조정
PARALLEL_JOBS=10 ./k8s_check_advanced.sh

# 점검 타임아웃 설정
CHECK_TIMEOUT=120 ./k8s_check_advanced.sh
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

# 리포트 생성
GENERATE_HTML_REPORT=true
GENERATE_JSON_REPORT=true

# 병렬 처리
MAX_PARALLEL_JOBS=10
```

## 📊 HTML 리포트 기능

### 대시보드 특징
- 📈 **실시간 진행률 바**: 리소스 사용률을 시각적으로 표시
- 🎨 **반응형 디자인**: 데스크톱/모바일 환경 모두 지원
- 📱 **현대적인 UI**: 직관적이고 깔끔한 인터페이스
- 🔍 **상세 정보**: 각 점검 항목별 세부 결과 표시

### 리소스 표시 색상
- 🟢 **녹색 (0-50%)**: 안전 수준
- 🟡 **노란색 (50-70%)**: 주의 수준  
- 🟠 **주황색 (70-85%)**: 경고 수준
- 🔴 **빨간색 (85%+)**: 위험 수준

## 🔧 요구사항

### 필수 도구
- `kubectl`: Kubernetes 클러스터 접근
- `bash`: 스크립트 실행 환경
- `bc`: 퍼센트 계산용
- `jq`: JSON 처리 (선택적)

### 권한 요구사항
- Kubernetes 클러스터 읽기 권한
- 노드 정보 조회 권한
- 파드 및 리소스 조회 권한

## 📝 출력 예시

### 콘솔 출력
```
==================================
📊 CLUSTER HEALTH CHECK SUMMARY
==================================
총 점검 항목: 5
✅ 성공: 5
❌ 실패: 0
📈 성공률: 100.0%

📄 Reports generated:
  • HTML: ./reports/k8s_report_20250821_143022.html
  • JSON: ./reports/k8s_report_20250821_143022.json
  • Log:  ./reports/k8s_check_20250821_143022.log
==================================
```

### HTML 리포트 미리보기
- 📊 요약 카드: 총 점검 항목, 성공/실패 수, 성공률
- 🖥️ 노드별 리소스: Pod/CPU/Memory/GPU 사용률 진행률 바
- 🔍 상세 점검 결과: 각 항목별 PASS/FAIL 상태와 세부 정보

## 🔄 업그레이드 내역

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

## 🤝 기여하기

이슈나 개선사항이 있으시면 언제든지 제안해주세요!

## 📄 라이선스

MIT License

---

**Made with ❤️ for Kubernetes Operations**