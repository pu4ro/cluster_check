# Kubernetes Cluster Health Check - Makefile
# Author: DevOps Team
# Version: 3.2.0

.PHONY: all check report pdf clean help install-deps docker-build

# Default target
all: report

# Run health check only (HTML output)
check:
	@echo "=== Kubernetes 클러스터 상태 점검 ==="
	@./k8s_health_check.sh --output html

# Run health check with JSON output
check-json:
	@echo "=== Kubernetes 클러스터 상태 점검 (JSON) ==="
	@./k8s_health_check.sh --output json

# Generate official report directly
report:
	@echo "=== 공식 기술 점검 보고서 생성 ==="
	@./generate_official_report.sh

# Generate report from existing JSON
report-from-json:
	@echo "=== 기존 JSON으로 보고서 생성 ==="
	@if [ -z "$(JSON)" ]; then \
		echo "사용법: make report-from-json JSON=reports/k8s_health_report_*.json"; \
		exit 1; \
	fi
	@./generate_official_report.sh --json $(JSON)

# Convert latest HTML report to PDF
pdf:
	@echo "=== PDF 변환 ==="
	@latest_html=$$(ls -t reports/official_report_*.html 2>/dev/null | head -1); \
	if [ -z "$$latest_html" ]; then \
		echo "HTML 보고서가 없습니다. 먼저 'make report'를 실행하세요."; \
		exit 1; \
	fi; \
	pdf_file=$${latest_html%.html}.pdf; \
	if command -v wkhtmltopdf >/dev/null 2>&1; then \
		echo "wkhtmltopdf로 변환 중: $$latest_html -> $$pdf_file"; \
		wkhtmltopdf --page-size A4 --margin-top 20mm --margin-bottom 20mm \
			--margin-left 18mm --margin-right 18mm \
			--enable-local-file-access "$$latest_html" "$$pdf_file"; \
		echo "PDF 생성 완료: $$pdf_file"; \
	elif command -v docker >/dev/null 2>&1; then \
		echo "Docker로 PDF 변환 중..."; \
		$(MAKE) docker-pdf HTML="$$latest_html"; \
	else \
		echo "wkhtmltopdf 또는 docker가 필요합니다."; \
		echo "설치: make install-deps"; \
		exit 1; \
	fi

# Convert specific HTML to PDF
pdf-file:
	@if [ -z "$(HTML)" ]; then \
		echo "사용법: make pdf-file HTML=reports/official_report_*.html"; \
		exit 1; \
	fi
	@pdf_file=$${HTML%.html}.pdf; \
	wkhtmltopdf --page-size A4 --margin-top 20mm --margin-bottom 20mm \
		--margin-left 18mm --margin-right 18mm \
		--enable-local-file-access "$(HTML)" "$$pdf_file"; \
	echo "PDF 생성 완료: $$pdf_file"

# Generate report and convert to PDF in one step
report-pdf: report pdf
	@echo "=== 보고서 및 PDF 생성 완료 ==="

# Docker-based PDF conversion
docker-pdf:
	@if [ -z "$(HTML)" ]; then \
		echo "사용법: make docker-pdf HTML=reports/official_report_*.html"; \
		exit 1; \
	fi
	@echo "Docker 이미지 빌드 중..."
	@docker build -t k8s-report-pdf:latest -f Dockerfile.pdf . 2>/dev/null || \
		$(MAKE) docker-build
	@pdf_file=$$(basename $(HTML) .html).pdf; \
	docker run --rm -v "$$(pwd)/reports:/reports" k8s-report-pdf:latest \
		"/reports/$$(basename $(HTML))" "/reports/$$pdf_file"
	@echo "PDF 생성 완료: reports/$$pdf_file"

# Build PDF conversion Docker image
docker-build:
	@echo "=== PDF 변환용 Docker 이미지 빌드 ==="
	@if [ ! -f Dockerfile.pdf ]; then \
		echo "Dockerfile.pdf 생성 중..."; \
		$(MAKE) create-dockerfile; \
	fi
	@docker build -t k8s-report-pdf:latest -f Dockerfile.pdf .

# Create Dockerfile for PDF conversion
create-dockerfile:
	@echo 'FROM ubuntu:22.04' > Dockerfile.pdf
	@echo 'RUN apt-get update && apt-get install -y wkhtmltopdf fonts-nanum && rm -rf /var/lib/apt/lists/*' >> Dockerfile.pdf
	@echo 'WORKDIR /reports' >> Dockerfile.pdf
	@echo 'ENTRYPOINT ["wkhtmltopdf", "--page-size", "A4", "--margin-top", "20mm", "--margin-bottom", "20mm", "--margin-left", "18mm", "--margin-right", "18mm", "--enable-local-file-access"]' >> Dockerfile.pdf

# Install dependencies
install-deps:
	@echo "=== 의존성 설치 ==="
	@if command -v apt-get >/dev/null 2>&1; then \
		echo "Ubuntu/Debian 시스템 감지"; \
		sudo apt-get update && sudo apt-get install -y wkhtmltopdf jq; \
	elif command -v yum >/dev/null 2>&1; then \
		echo "RHEL/CentOS 시스템 감지"; \
		sudo yum install -y wkhtmltopdf jq; \
	elif command -v brew >/dev/null 2>&1; then \
		echo "macOS 시스템 감지"; \
		brew install wkhtmltopdf jq; \
	else \
		echo "패키지 관리자를 찾을 수 없습니다. 수동으로 wkhtmltopdf와 jq를 설치하세요."; \
	fi

# Clean generated reports
clean:
	@echo "=== 생성된 보고서 정리 ==="
	@rm -f reports/*.html reports/*.pdf reports/*.json reports/*.log
	@echo "정리 완료"

# Clean only PDF files
clean-pdf:
	@rm -f reports/*.pdf
	@echo "PDF 파일 정리 완료"

# Show help
help:
	@echo "Kubernetes Cluster Health Check - 사용 가능한 명령어"
	@echo ""
	@echo "  make              - 공식 보고서 생성 (기본)"
	@echo "  make check        - 클러스터 상태 점검만 실행"
	@echo "  make check-json   - JSON 형식으로 점검 결과 생성"
	@echo "  make report       - 공식 기술 점검 보고서 생성"
	@echo "  make report-pdf   - 보고서 생성 후 PDF 변환"
	@echo "  make pdf          - 최신 HTML 보고서를 PDF로 변환"
	@echo "  make pdf-file HTML=파일경로  - 특정 HTML을 PDF로 변환"
	@echo ""
	@echo "  make docker-build - PDF 변환용 Docker 이미지 빌드"
	@echo "  make docker-pdf HTML=파일경로  - Docker로 PDF 변환"
	@echo ""
	@echo "  make install-deps - 의존성 설치 (wkhtmltopdf, jq)"
	@echo "  make clean        - 생성된 보고서 삭제"
	@echo "  make clean-pdf    - PDF 파일만 삭제"
	@echo "  make help         - 이 도움말 표시"
	@echo ""
	@echo "예시:"
	@echo "  make report-pdf                    # 보고서 생성 + PDF 변환"
	@echo "  make pdf-file HTML=reports/official_report_20250101_120000.html"
