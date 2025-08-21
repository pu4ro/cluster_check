#!/bin/bash

# Advanced Kubernetes Cluster Health Check Script
# Features: Modular structure, parallel processing, resource monitoring, HTML reporting

set -euo pipefail

# Global variables
declare -A CHECK_RESULTS=()
declare -A CHECK_DETAILS=()
declare -A NODE_RESOURCES=()
declare -a PARALLEL_PIDS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${OUTPUT_DIR}/k8s_check_${TIMESTAMP}.log"
HTML_REPORT="${OUTPUT_DIR}/k8s_report_${TIMESTAMP}.html"
JSON_REPORT="${OUTPUT_DIR}/k8s_report_${TIMESTAMP}.json"

# Configuration
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
DEBUG=${DEBUG:-true}
PARALLEL_JOBS=${PARALLEL_JOBS:-5}
CHECK_TIMEOUT=${CHECK_TIMEOUT:-60}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [ "$DEBUG" = "true" ] && log "DEBUG" "$@" || true; }

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    local percent=$((current * 100 / total))
    printf "\r[%3d%%] %s" "$percent" "$task"
    [ "$current" -eq "$total" ] && echo
}

# Configuration loader
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    else
        log_warn "Configuration file not found, using defaults"
        create_default_config
    fi
}

create_default_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# Kubernetes Cluster Check Configuration

# Check timeouts (seconds)
CHECK_TIMEOUT=60
NODE_CHECK_TIMEOUT=30
POD_CHECK_TIMEOUT=45

# Monitoring settings
ENABLE_RESOURCE_MONITORING=true
ENABLE_GPU_MONITORING=true
RESOURCE_THRESHOLD_CPU=80
RESOURCE_THRESHOLD_MEMORY=85
RESOURCE_THRESHOLD_DISK=90

# Network settings
FLANNEL_NAMESPACE="kube-flannel"
DEFAULT_PROTOCOL="https"

# Report settings
GENERATE_HTML_REPORT=true
GENERATE_JSON_REPORT=true
INCLUDE_DEBUG_INFO=true

# Parallel processing
MAX_PARALLEL_JOBS=10
EOF
    log_info "Default configuration created at $CONFIG_FILE"
}

# Resource monitoring functions
get_node_resources() {
    local node_name=$1
    log_debug "Getting resources for node: $node_name"
    
    # Get node capacity and allocatable resources
    local node_info=$(kubectl describe node "$node_name" 2>/dev/null)
    
    # Extract capacity
    local cpu_capacity=$(echo "$node_info" | grep -A 10 "Capacity:" | grep "cpu:" | awk '{print $2}' | sed 's/m$//')
    local memory_capacity=$(echo "$node_info" | grep -A 10 "Capacity:" | grep "memory:" | awk '{print $2}' | sed 's/Ki$//')
    
    # Extract allocatable
    local cpu_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "cpu:" | awk '{print $2}' | sed 's/m$//')
    local memory_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "memory:" | awk '{print $2}' | sed 's/Ki$//')
    
    # Get current resource requests
    local resource_requests=$(kubectl describe node "$node_name" | grep -A 20 "Allocated resources:")
    local cpu_requests=$(echo "$resource_requests" | grep "cpu" | awk '{print $2}' | sed 's/m$//' | sed 's/(%)//')
    local memory_requests=$(echo "$resource_requests" | grep "memory" | awk '{print $2}' | sed 's/Ki$//' | sed 's/(%)//')
    
    # Get pod count
    local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" --no-headers | wc -l)
    local max_pods=$(echo "$node_info" | grep "pods:" | tail -1 | awk '{print $2}')
    
    # Calculate percentages
    local cpu_used_percent=0
    local memory_used_percent=0
    local pod_used_percent=0
    
    if [[ -n "$cpu_allocatable" && "$cpu_allocatable" -gt 0 ]]; then
        cpu_used_percent=$(echo "scale=1; ($cpu_requests * 100) / $cpu_allocatable" | bc -l 2>/dev/null || echo "0")
    fi
    
    if [[ -n "$memory_allocatable" && "$memory_allocatable" -gt 0 ]]; then
        memory_used_percent=$(echo "scale=1; ($memory_requests * 100) / $memory_allocatable" | bc -l 2>/dev/null || echo "0")
    fi
    
    if [[ -n "$max_pods" && "$max_pods" -gt 0 ]]; then
        pod_used_percent=$(echo "scale=1; ($pod_count * 100) / $max_pods" | bc -l 2>/dev/null || echo "0")
    fi
    
    # Check for GPU resources
    local gpu_info=""
    if kubectl describe node "$node_name" | grep -q "nvidia.com/gpu"; then
        local gpu_capacity=$(echo "$node_info" | grep "nvidia.com/gpu:" | awk '{print $2}')
        local gpu_allocatable=$(echo "$node_info" | grep -A 10 "Allocatable:" | grep "nvidia.com/gpu:" | awk '{print $2}')
        local gpu_requests=$(echo "$resource_requests" | grep "nvidia.com/gpu" | awk '{print $2}' || echo "0")
        local gpu_used_percent=0
        
        if [[ -n "$gpu_allocatable" && "$gpu_allocatable" -gt 0 ]]; then
            gpu_used_percent=$(echo "scale=1; ($gpu_requests * 100) / $gpu_allocatable" | bc -l 2>/dev/null || echo "0")
        fi
        
        gpu_info="\"gpu_capacity\":\"$gpu_capacity\",\"gpu_allocatable\":\"$gpu_allocatable\",\"gpu_requests\":\"$gpu_requests\",\"gpu_used_percent\":\"$gpu_used_percent\","
    fi
    
    # Store results in JSON format
    NODE_RESOURCES["$node_name"]="{\"node\":\"$node_name\",\"pod_count\":\"$pod_count\",\"max_pods\":\"$max_pods\",\"pod_used_percent\":\"$pod_used_percent\",\"cpu_allocatable\":\"$cpu_allocatable\",\"cpu_requests\":\"$cpu_requests\",\"cpu_used_percent\":\"$cpu_used_percent\",\"memory_allocatable\":\"$memory_allocatable\",\"memory_requests\":\"$memory_requests\",\"memory_used_percent\":\"$memory_used_percent\",$gpu_info\"status\":\"active\"}"
    
    log_debug "Node $node_name: Pods: $pod_count/$max_pods (${pod_used_percent}%), CPU: ${cpu_used_percent}%, Memory: ${memory_used_percent}%"
}

# Check functions
check_node_status() {
    local check_name="node_status"
    log_info "Checking cluster node status..."
    
    local node_status=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[-1].type} {.status.conditions[-1].status}{"\n"}{end}' 2>/dev/null)
    local result="PASS"
    local details=""
    local node_count=0
    local ready_count=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name=$(echo "$line" | awk '{print $1}')
        local condition=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        
        ((node_count++))
        
        if [[ "$condition" == "Ready" && "$status" == "True" ]]; then
            ((ready_count++))
            # Get detailed resource information for this node
            get_node_resources "$name"
        else
            result="FAIL"
            details+="Node $name: $condition/$status; "
        fi
    done <<< "$node_status"
    
    if [[ "$result" == "PASS" ]]; then
        details="All $node_count nodes are ready and healthy"
    fi
    
    CHECK_RESULTS["$check_name"]="$result"
    CHECK_DETAILS["$check_name"]="$details"
    
    log_info "Node status check completed: $result ($ready_count/$node_count nodes ready)"
}

check_pod_status() {
    local check_name="pod_status"
    log_info "Checking cluster pod status..."
    
    local pod_status=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.phase} {.spec.nodeName}{"\n"}{end}' 2>/dev/null)
    local result="PASS"
    local details=""
    local total_pods=0
    local running_pods=0
    local failed_pods=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local ns=$(echo "$line" | awk '{print $1}')
        local name=$(echo "$line" | awk '{print $2}')
        local phase=$(echo "$line" | awk '{print $3}')
        local node=$(echo "$line" | awk '{print $4}')
        
        ((total_pods++))
        
        if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
            ((running_pods++))
        else
            ((failed_pods++))
            result="FAIL"
            details+="[$ns] $name: $phase (node: $node); "
        fi
    done <<< "$pod_status"
    
    if [[ "$result" == "PASS" ]]; then
        details="All $total_pods pods are running successfully"
    else
        details="$failed_pods out of $total_pods pods are not running properly: $details"
    fi
    
    CHECK_RESULTS["$check_name"]="$result"
    CHECK_DETAILS["$check_name"]="$details"
    
    log_info "Pod status check completed: $result ($running_pods/$total_pods pods running)"
}

check_services() {
    local check_name="services"
    log_info "Checking services status..."
    
    if kubectl get svc -A &>/dev/null; then
        CHECK_RESULTS["$check_name"]="PASS"
        local svc_count=$(kubectl get svc -A --no-headers | wc -l)
        CHECK_DETAILS["$check_name"]="All $svc_count services are accessible"
    else
        CHECK_RESULTS["$check_name"]="FAIL"
        CHECK_DETAILS["$check_name"]="Unable to access services"
    fi
    
    log_info "Services check completed: ${CHECK_RESULTS[$check_name]}"
}

check_coredns() {
    local check_name="coredns"
    log_info "Checking CoreDNS status..."
    
    local coredns_status=$(kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep coredns 2>/dev/null)
    local result="PASS"
    local details=""
    local dns_pod_count=0
    local running_dns_pods=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pod_name=$(echo "$line" | awk '{print $1}')
        local phase=$(echo "$line" | awk '{print $2}')
        
        ((dns_pod_count++))
        
        if [[ "$phase" == "Running" ]]; then
            ((running_dns_pods++))
        else
            result="FAIL"
            details+="CoreDNS pod $pod_name: $phase; "
        fi
    done <<< "$coredns_status"
    
    if [[ "$result" == "PASS" ]]; then
        details="All $dns_pod_count CoreDNS pods are running"
    fi
    
    CHECK_RESULTS["$check_name"]="$result"
    CHECK_DETAILS["$check_name"]="$details"
    
    log_info "CoreDNS check completed: $result ($running_dns_pods/$dns_pod_count pods running)"
}

check_storage() {
    local check_name="storage"
    log_info "Checking storage (PV/PVC) status..."
    
    local pv_status=$(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
    local pvc_status=$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
    
    local result="PASS"
    local details=""
    local pv_count=0
    local bound_pv=0
    local pvc_count=0
    local bound_pvc=0
    
    # Check PVs
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pv_name=$(echo "$line" | awk '{print $1}')
        local phase=$(echo "$line" | awk '{print $2}')
        
        ((pv_count++))
        
        if [[ "$phase" == "Bound" ]]; then
            ((bound_pv++))
        else
            result="FAIL"
            details+="PV $pv_name: $phase; "
        fi
    done <<< "$pv_status"
    
    # Check PVCs
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local ns=$(echo "$line" | awk '{print $1}')
        local pvc_name=$(echo "$line" | awk '{print $2}')
        local phase=$(echo "$line" | awk '{print $3}')
        
        ((pvc_count++))
        
        if [[ "$phase" == "Bound" ]]; then
            ((bound_pvc++))
        else
            result="FAIL"
            details+="PVC [$ns] $pvc_name: $phase; "
        fi
    done <<< "$pvc_status"
    
    if [[ "$result" == "PASS" ]]; then
        details="Storage healthy: $bound_pv/$pv_count PVs bound, $bound_pvc/$pvc_count PVCs bound"
    fi
    
    CHECK_RESULTS["$check_name"]="$result"
    CHECK_DETAILS["$check_name"]="$details"
    
    log_info "Storage check completed: $result"
}

# Parallel execution wrapper
run_check_parallel() {
    local check_function=$1
    local check_name=$2
    
    log_debug "Starting parallel check: $check_name"
    
    # Run check in background with timeout
    (
        timeout "$CHECK_TIMEOUT" "$check_function" 2>&1
        echo "CHECK_COMPLETED:$check_name:$?"
    ) &
    
    local pid=$!
    PARALLEL_PIDS+=("$pid")
    
    return 0
}

# Wait for all parallel jobs to complete
wait_for_parallel_jobs() {
    local completed=0
    local total=${#PARALLEL_PIDS[@]}
    
    for pid in "${PARALLEL_PIDS[@]}"; do
        if wait "$pid"; then
            ((completed++))
            show_progress "$completed" "$total" "Waiting for checks to complete..."
        else
            log_warn "Check process $pid failed or timed out"
            ((completed++))
            show_progress "$completed" "$total" "Waiting for checks to complete..."
        fi
    done
    
    PARALLEL_PIDS=()
    log_info "All parallel checks completed"
}

# HTML Report generation
generate_html_report() {
    log_info "Generating HTML report..."
    
    local total_checks=${#CHECK_RESULTS[@]}
    local passed_checks=0
    local failed_checks=0
    
    for result in "${CHECK_RESULTS[@]}"; do
        if [[ "$result" == "PASS" ]]; then
            ((passed_checks++))
        else
            ((failed_checks++))
        fi
    done
    
    cat > "$HTML_REPORT" << EOF
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes Cluster Health Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f7fa;
            color: #333;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            text-align: center;
        }
        .header h1 {
            margin: 0;
            font-size: 2.5em;
        }
        .header .subtitle {
            margin: 10px 0 0 0;
            opacity: 0.9;
            font-size: 1.1em;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .summary-card {
            background: white;
            padding: 25px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            text-align: center;
            border-left: 5px solid #667eea;
        }
        .summary-card h3 {
            margin: 0 0 10px 0;
            color: #667eea;
        }
        .summary-card .number {
            font-size: 2.5em;
            font-weight: bold;
            margin: 10px 0;
        }
        .pass { color: #28a745; }
        .fail { color: #dc3545; }
        .resource-section {
            background: white;
            padding: 25px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            margin-bottom: 30px;
        }
        .resource-section h2 {
            color: #667eea;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        .node-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }
        .node-card {
            border: 1px solid #e9ecef;
            border-radius: 8px;
            padding: 20px;
            background: #f8f9fa;
        }
        .node-card h4 {
            margin: 0 0 15px 0;
            color: #495057;
            font-size: 1.2em;
        }
        .resource-bar {
            margin: 10px 0;
        }
        .resource-bar .label {
            display: flex;
            justify-content: space-between;
            margin-bottom: 5px;
            font-size: 0.9em;
            color: #666;
        }
        .progress-bar {
            background-color: #e9ecef;
            border-radius: 4px;
            height: 8px;
            overflow: hidden;
        }
        .progress-fill {
            height: 100%;
            transition: width 0.3s ease;
        }
        .progress-fill.low { background-color: #28a745; }
        .progress-fill.medium { background-color: #ffc107; }
        .progress-fill.high { background-color: #fd7e14; }
        .progress-fill.critical { background-color: #dc3545; }
        .checks-section {
            background: white;
            padding: 25px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .checks-section h2 {
            color: #667eea;
            border-bottom: 2px solid #667eea;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        .check-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 15px;
            margin: 10px 0;
            border-radius: 8px;
            border-left: 5px solid;
        }
        .check-item.pass {
            background-color: #d4edda;
            border-left-color: #28a745;
        }
        .check-item.fail {
            background-color: #f8d7da;
            border-left-color: #dc3545;
        }
        .check-name {
            font-weight: bold;
            flex: 1;
        }
        .check-status {
            padding: 5px 15px;
            border-radius: 20px;
            color: white;
            font-weight: bold;
        }
        .check-status.pass {
            background-color: #28a745;
        }
        .check-status.fail {
            background-color: #dc3545;
        }
        .check-details {
            margin-top: 10px;
            font-size: 0.9em;
            color: #666;
            padding-left: 10px;
            border-left: 3px solid #dee2e6;
        }
        .footer {
            text-align: center;
            margin-top: 40px;
            padding: 20px;
            color: #666;
            font-size: 0.9em;
        }
        @media (max-width: 768px) {
            .summary {
                grid-template-columns: 1fr;
            }
            .node-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🚀 Kubernetes Cluster Health Report</h1>
        <div class="subtitle">Generated on $(date '+%Y-%m-%d %H:%M:%S')</div>
    </div>

    <div class="summary">
        <div class="summary-card">
            <h3>총 점검 항목</h3>
            <div class="number">$total_checks</div>
        </div>
        <div class="summary-card">
            <h3>성공</h3>
            <div class="number pass">$passed_checks</div>
        </div>
        <div class="summary-card">
            <h3>실패</h3>
            <div class="number fail">$failed_checks</div>
        </div>
        <div class="summary-card">
            <h3>성공률</h3>
            <div class="number">$(echo "scale=1; $passed_checks * 100 / $total_checks" | bc -l)%</div>
        </div>
    </div>

    <div class="resource-section">
        <h2>🖥️ 노드별 리소스 현황</h2>
        <div class="node-grid">
EOF

    # Add node resource information
    for node_name in "${!NODE_RESOURCES[@]}"; do
        local node_data="${NODE_RESOURCES[$node_name]}"
        
        # Parse JSON data (simplified parsing for bash)
        local pod_count=$(echo "$node_data" | sed 's/.*"pod_count":"\([^"]*\)".*/\1/')
        local max_pods=$(echo "$node_data" | sed 's/.*"max_pods":"\([^"]*\)".*/\1/')
        local pod_percent=$(echo "$node_data" | sed 's/.*"pod_used_percent":"\([^"]*\)".*/\1/')
        local cpu_percent=$(echo "$node_data" | sed 's/.*"cpu_used_percent":"\([^"]*\)".*/\1/')
        local memory_percent=$(echo "$node_data" | sed 's/.*"memory_used_percent":"\([^"]*\)".*/\1/')
        
        # Get progress bar class based on percentage
        get_progress_class() {
            local percent=$(echo "$1" | cut -d. -f1)
            if [[ $percent -lt 50 ]]; then echo "low"
            elif [[ $percent -lt 70 ]]; then echo "medium"
            elif [[ $percent -lt 85 ]]; then echo "high"
            else echo "critical"
            fi
        }
        
        local pod_class=$(get_progress_class "$pod_percent")
        local cpu_class=$(get_progress_class "$cpu_percent")
        local memory_class=$(get_progress_class "$memory_percent")
        
        cat >> "$HTML_REPORT" << EOF
            <div class="node-card">
                <h4>📦 $node_name</h4>
                <div class="resource-bar">
                    <div class="label">
                        <span>Pods</span>
                        <span>$pod_count/$max_pods (${pod_percent}%)</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill $pod_class" style="width: ${pod_percent}%"></div>
                    </div>
                </div>
                <div class="resource-bar">
                    <div class="label">
                        <span>CPU</span>
                        <span>${cpu_percent}%</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill $cpu_class" style="width: ${cpu_percent}%"></div>
                    </div>
                </div>
                <div class="resource-bar">
                    <div class="label">
                        <span>Memory</span>
                        <span>${memory_percent}%</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill $memory_class" style="width: ${memory_percent}%"></div>
                    </div>
                </div>
EOF

        # Add GPU info if available
        if echo "$node_data" | grep -q "gpu_used_percent"; then
            local gpu_percent=$(echo "$node_data" | sed 's/.*"gpu_used_percent":"\([^"]*\)".*/\1/')
            local gpu_class=$(get_progress_class "$gpu_percent")
            cat >> "$HTML_REPORT" << EOF
                <div class="resource-bar">
                    <div class="label">
                        <span>GPU</span>
                        <span>${gpu_percent}%</span>
                    </div>
                    <div class="progress-bar">
                        <div class="progress-fill $gpu_class" style="width: ${gpu_percent}%"></div>
                    </div>
                </div>
EOF
        fi
        
        cat >> "$HTML_REPORT" << EOF
            </div>
EOF
    done

    cat >> "$HTML_REPORT" << EOF
        </div>
    </div>

    <div class="checks-section">
        <h2>🔍 상세 점검 결과</h2>
EOF

    # Add check results
    for check_name in "${!CHECK_RESULTS[@]}"; do
        local result="${CHECK_RESULTS[$check_name]}"
        local details="${CHECK_DETAILS[$check_name]}"
        local status_class=$(echo "$result" | tr '[:upper:]' '[:lower:]')
        
        # Translate check names to Korean
        local korean_name=""
        case "$check_name" in
            "node_status") korean_name="클러스터 노드 상태" ;;
            "pod_status") korean_name="파드 상태" ;;
            "services") korean_name="서비스 상태" ;;
            "coredns") korean_name="CoreDNS 상태" ;;
            "storage") korean_name="스토리지 상태" ;;
            *) korean_name="$check_name" ;;
        esac
        
        cat >> "$HTML_REPORT" << EOF
        <div class="check-item $status_class">
            <div class="check-name">$korean_name</div>
            <div class="check-status $status_class">$result</div>
        </div>
        <div class="check-details">$details</div>
EOF
    done

    cat >> "$HTML_REPORT" << EOF
    </div>

    <div class="footer">
        <p>📊 Report generated by Advanced Kubernetes Health Check Script</p>
        <p>🕒 Timestamp: $(date '+%Y-%m-%d %H:%M:%S')</p>
    </div>

    <script>
        // Add some interactivity
        document.addEventListener('DOMContentLoaded', function() {
            // Animate progress bars
            const progressBars = document.querySelectorAll('.progress-fill');
            progressBars.forEach(bar => {
                const width = bar.style.width;
                bar.style.width = '0%';
                setTimeout(() => {
                    bar.style.width = width;
                }, 100);
            });
        });
    </script>
</body>
</html>
EOF

    log_info "HTML report generated: $HTML_REPORT"
}

# JSON Report generation
generate_json_report() {
    log_info "Generating JSON report..."
    
    local json_data="{"
    json_data+="\"timestamp\":\"$(date -Iseconds)\","
    json_data+="\"summary\":{"
    json_data+="\"total_checks\":${#CHECK_RESULTS[@]},"
    
    local passed=0
    local failed=0
    for result in "${CHECK_RESULTS[@]}"; do
        if [[ "$result" == "PASS" ]]; then ((passed++)); else ((failed++)); fi
    done
    
    json_data+="\"passed\":$passed,"
    json_data+="\"failed\":$failed"
    json_data+="},"
    
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
    
    json_data+="\"checks\":{"
    local first_check=true
    for check_name in "${!CHECK_RESULTS[@]}"; do
        if [[ "$first_check" == "false" ]]; then
            json_data+=","
        fi
        json_data+="\"$check_name\":{\"status\":\"${CHECK_RESULTS[$check_name]}\",\"details\":\"${CHECK_DETAILS[$check_name]}\"}"
        first_check=false
    done
    json_data+="}}"
    
    echo "$json_data" | jq '.' > "$JSON_REPORT" 2>/dev/null || echo "$json_data" > "$JSON_REPORT"
    
    log_info "JSON report generated: $JSON_REPORT"
}

# Main execution function
main() {
    log_info "Starting advanced Kubernetes cluster health check..."
    log_info "Script version: 2.0.0"
    log_info "Output directory: $OUTPUT_DIR"
    
    # Load configuration
    load_config
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_info "Kubernetes cluster is accessible"
    
    # Run checks in parallel
    log_info "Starting parallel health checks..."
    
    run_check_parallel "check_node_status" "nodes" &
    run_check_parallel "check_pod_status" "pods" &
    run_check_parallel "check_services" "services" &
    run_check_parallel "check_coredns" "coredns" &
    run_check_parallel "check_storage" "storage" &
    
    # Wait for all checks to complete
    wait_for_parallel_jobs
    
    # Generate reports
    log_info "Generating reports..."
    generate_html_report
    generate_json_report
    
    # Display summary
    echo
    echo "=================================="
    echo "📊 CLUSTER HEALTH CHECK SUMMARY"
    echo "=================================="
    
    local total=${#CHECK_RESULTS[@]}
    local passed=0
    local failed=0
    
    for result in "${CHECK_RESULTS[@]}"; do
        if [[ "$result" == "PASS" ]]; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    echo "총 점검 항목: $total"
    echo "✅ 성공: $passed"
    echo "❌ 실패: $failed"
    echo "📈 성공률: $(echo "scale=1; $passed * 100 / $total" | bc -l)%"
    echo
    echo "📄 Reports generated:"
    echo "  • HTML: $HTML_REPORT"
    echo "  • JSON: $JSON_REPORT"
    echo "  • Log:  $LOG_FILE"
    echo "=================================="
    
    # Return exit code based on results
    if [[ $failed -gt 0 ]]; then
        log_warn "Some checks failed. Please review the reports."
        exit 1
    else
        log_info "All checks passed successfully!"
        exit 0
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi