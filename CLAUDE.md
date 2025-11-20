# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a comprehensive Kubernetes cluster health check system written in Bash. The project monitors cluster health, resource utilization, and storage systems (Rook-Ceph, Harbor, Minio), generating interactive HTML dashboards, JSON reports, and real-time terminal monitoring.

**Primary Script**: `k8s_health_check.sh` - Main health check script with 10 comprehensive check items
**Official Report**: `generate_official_report.sh` - Public sector official technical report generator (A4 PDF optimized)
**Dashboard**: `dashboard.sh` - Real-time terminal-based monitoring dashboard
**Config**: `config.conf` - Configuration file for timeouts, thresholds, and monitoring settings

## Architecture

### Core Components

1. **Check System** (`k8s_health_check.sh`)
   - Modular check functions that execute sequentially with error isolation
   - Each check function follows the pattern: `check_<component>_<aspect>()`
   - Results stored in associative arrays: `CHECK_RESULTS`, `CHECK_DETAILS`, `NODE_RESOURCES`
   - Results categorized into: `SUCCESS_CHECKS`, `WARNING_CHECKS`, `FAILED_CHECKS`
   - All checks call `store_result()` to record status and details

2. **Report Generation**
   - Three output formats: HTML (default), JSON, and text log
   - HTML reports embed Chart.js for interactive visualizations
   - Reports generated via: `generate_html_report()`, `generate_json_report()`, `generate_log_report()`
   - All reports saved to `reports/` directory with timestamps

3. **Resource Monitoring**
   - Node-level resource tracking (CPU, Memory, GPU, Pod usage)
   - Storage monitoring for Harbor and Minio pods via `df -h` exec
   - Rook-Ceph health via `rook-ceph-tools` deployment
   - Resource data stored in `NODE_RESOURCES` associative array

### Ten Health Check Items

1. **check_node_status()** - Verifies all nodes are in Ready state
2. **check_pod_status()** - Checks pod states across all namespaces
3. **check_deployment_status()** - Validates deployment replica counts
4. **check_service_endpoints()** - Ensures services have valid endpoints (skips kserve/modelmesh-serving)
5. **check_storage_status()** - Verifies PV/PVC binding status
6. **check_ingress_backends()** - Tests Ingress backend service connectivity
7. **check_url_connectivity()** - Tests external URL accessibility (configurable)
8. **check_rook_ceph_health()** - Monitors Ceph cluster health (HEALTH_OK/WARN/ERR)
9. **check_harbor_disk_usage()** - Tracks Harbor registry disk usage via pod exec
10. **check_minio_disk_usage()** - Monitors Minio storage disk usage via pod exec

### Key Design Patterns

- **Error Isolation**: Each check wrapped with `|| log_warn` to continue execution on failure
- **Result Storage**: Centralized `store_result()` function for consistent status tracking
- **kubectl Wrapper**: `kubectl_cmd()` function handles kubeconfig and context parameters
- **Interactive Mode**: Script prompts for URL input if not provided via CLI arguments
- **Graceful Degradation**: Uses `set -e` but allows individual checks to fail without stopping execution

## Common Commands

### Running Health Checks

```bash
# Interactive mode (prompts for URL)
./k8s_health_check.sh

# With URL argument
./k8s_health_check.sh https://example.com

# Specify output format
./k8s_health_check.sh --output html
./k8s_health_check.sh --output json
./k8s_health_check.sh --output log

# Use specific kubeconfig/context
./k8s_health_check.sh --kubeconfig /path/to/config --context prod-cluster

# Debug mode
DEBUG=true ./k8s_health_check.sh
```

### Real-Time Terminal Dashboard

```bash
# Single snapshot
./dashboard.sh
./dashboard.sh --once

# Auto-refresh every 30 seconds
./dashboard.sh --watch
./dashboard.sh -w
```

### Official Report Generation (Public Sector)

```bash
# Auto-generate report (runs health check first)
./generate_official_report.sh

# Generate from existing JSON
./generate_official_report.sh --json reports/k8s_health_report_20250120_120000.json

# Specify organization and author
./generate_official_report.sh --org "K-water" --author "DevOps Team"

# Specify document version
./generate_official_report.sh --version "2.0"

# Convert to PDF (requires wkhtmltopdf)
wkhtmltopdf reports/official_report_*.html reports/official_report.pdf
```

### Testing

```bash
# Test kubectl connectivity
kubectl cluster-info

# Verify required tools
command -v kubectl jq bc curl

# Manual check of storage pods
kubectl get pods -n harbor -l app=harbor,component=registry
kubectl get pods -n minio -l app=minio
kubectl get deployment -n rook-ceph rook-ceph-tools

# Test Ceph cluster status
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph -s

# Test storage disk usage
kubectl exec -n harbor <pod-name> -- df -h
kubectl exec -n minio <pod-name> -- df -h
```

## Configuration

The `config.conf` file controls:
- **Timeouts**: `CHECK_TIMEOUT`, `NODE_CHECK_TIMEOUT`, `POD_CHECK_TIMEOUT`
- **Resource Thresholds**: `RESOURCE_THRESHOLD_CPU/MEMORY/DISK` (percentage values)
- **Feature Flags**: `ENABLE_RESOURCE_MONITORING`, `ENABLE_GPU_MONITORING`
- **Report Options**: `GENERATE_HTML_REPORT`, `GENERATE_JSON_REPORT`
- **Parallelism**: `MAX_PARALLEL_JOBS` (currently declared but not fully implemented)

## Important Implementation Details

### Storage Monitoring Specifics

- **Harbor**: Targets pods with labels `app=harbor,component=registry` in `harbor` namespace
  - Checks RBD disk mount usage
  - Threshold: 80% warning, 90% critical

- **Minio**: Targets pods with label `app=minio` in `minio` namespace
  - Checks data volume disk usage
  - Threshold: 80% warning, 90% critical

- **Rook-Ceph**: Requires `rook-ceph-tools` deployment in `rook-ceph` namespace
  - Executes `ceph -s` command to get cluster health
  - Maps: HEALTH_OK → SUCCESS, HEALTH_WARN → WARNING, HEALTH_ERR → FAILED

### Service Endpoint Exclusions

The `check_service_endpoints()` function explicitly skips:
- `kserve/modelmesh-serving` service (known to not have endpoints in certain configurations)
- ExternalName type services

When adding more exclusions, update the skip logic at k8s_health_check.sh:520-525.

### HTML Report Generation

- Uses Bootstrap 5 for responsive design
- Integrates Chart.js via CDN for donut charts and progress bars
- Color coding: Green (0-50%), Yellow (50-70%), Orange (70-85%), Red (85%+)
- Embeds complete check details inline with placeholder replacement
- Generated HTML is fully self-contained (except CDN resources)

### Terminal Dashboard Features

- Uses ANSI color codes and Unicode box-drawing characters
- Requires UTF-8 locale support
- 20-character progress bars using `#` and `-` characters
- Auto-refresh mode clears screen between updates
- Lightweight design with minimal kubectl calls

### Official Report Generation (generate_official_report.sh)

**Purpose**: Generates formal technical inspection reports for public sector organizations (e.g., K-water)

**Features**:
- A4 PDF print optimization with automatic page breaks
- Black & white printing optimized (grayscale-based differentiation)
- Formal language suitable for government/public sector reports
- Automatic risk level assessment (High/Medium/Low)
- Automated improvement recommendations per issue

**Report Structure**:
1. Cover page (organization, author, date, version)
2. Executive Summary (objectives, scope, key findings)
3. Check items summary table (10 items with risk levels)
4. Kubernetes cluster details (version, nodes, CNI, storage)
5. Runway platform details (if installed)
6. Issue list (detailed analysis with impact and solutions)
7. Final conclusion and comprehensive recommendations

**Technical Details**:
- Reads JSON output from `k8s_health_check.sh` (or runs it automatically)
- Collects additional cluster info via `kubectl` commands (with 5s timeouts)
- Detects CNI type (Cilium/Calico/Flannel), GPU Operator, Runway platform
- Maps check statuses to risk levels and generates appropriate recommendations
- CSS uses `@page` rules for proper PDF pagination
- All table borders use simple black lines for B&W printing

**Customization**:
- Organization name: `--org` parameter (default: "한국수자원공사")
- Author name: `--author` parameter (default: "기술운영팀")
- Document version: `--version` parameter (default: "1.0")

## Dependencies

**Required Tools**:
- `kubectl` - Kubernetes cluster access
- `bash` 4.0+ - Script execution
- `bc` - Percentage calculations
- `jq` - JSON parsing
- `curl` - URL connectivity testing

**Optional Kubernetes Resources**:
- `rook-ceph-tools` deployment in `rook-ceph` namespace
- `harbor-registry` pods in `harbor` namespace
- `minio` statefulset in `minio` namespace

**Kubernetes Permissions**:
- Read access to nodes, pods, deployments, services, endpoints, PV/PVC, ingresses
- Pod exec permission for rook-ceph-tools, harbor-registry, and minio pods

## Output Files

All reports are timestamped and saved to `reports/`:
- `k8s_report_YYYYMMDD_HHMMSS.html` - Interactive HTML dashboard (k8s_health_check.sh)
- `k8s_report_YYYYMMDD_HHMMSS.json` - Structured JSON data (k8s_health_check.sh)
- `k8s_check_YYYYMMDD_HHMMSS.log` - Detailed text log (k8s_health_check.sh --output log)
- `official_report_YYYYMMDD_HHMMSS.html` - Formal technical report (generate_official_report.sh)

## Exit Codes

- `0` - All checks successful
- `1` - One or more checks failed
- `2` - One or more checks returned warnings
