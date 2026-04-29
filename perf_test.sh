#!/bin/bash
# Performance test suite for User Manager optimizations
# v1.0 - Performance Benchmarking Tool

set -uo pipefail

readonly TEST_VERSION="1.0.0"
readonly RESULTS_DIR="/tmp/umgr_perf_results"

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'
C_BLUE='\033[0;34m'

# Logging
log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_err() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step() { echo -e "${C_CYAN}[STEP]${C_RESET} $*"; }
log_metric() { echo -e "${C_BLUE}[METRIC]${C_RESET} $*"; }

# Initialize test environment
init_tests() {
    mkdir -p "$RESULTS_DIR"
    rm -f "$RESULTS_DIR"/*.result
    log_info "Performance test suite initialized"
    log_info "Results directory: $RESULTS_DIR"
}

# Measure execution time with high precision
measure_time() {
    local name="$1"
    shift
    local start end duration
    start=$(date +%s%N)
    
    if [[ $# -gt 0 ]]; then
        "$@" >/dev/null 2>&1
    fi
    local exit_code=$?
    
    end=$(date +%s%N)
    duration=$((end - start))
    
    # Convert to milliseconds with 3 decimal places
    local ms=$(echo "scale=3; $duration / 1000000" | bc 2>/dev/null || echo "0")
    
    # Save result
    echo "${name}:${ms}:${exit_code}" >> "$RESULTS_DIR/timing.results"
    
    echo "$ms"
}

# Test 1: Menu rendering performance
test_menu_rendering() {
    log_step "Test 1: Menu Rendering Performance"
    
    local iterations=100
    local total_time=0
    
    for i in $(seq 1 $iterations); do
        local time
        time=$(measure_time "menu_render_$i" "bash -c 'source ./lib/common.sh && draw_header Test'")
        total_time=$(echo "$total_time + $time" | bc 2>/dev/null || echo "0")
    done
    
    local avg=$(echo "scale=3; $total_time / $iterations" | bc 2>/dev/null || echo "0")
    log_metric "Average menu render time: ${avg}ms"
    log_metric "Total for $iterations iterations: ${total_time}ms"
    
    # Performance threshold
    if (( $(echo "$avg < 10" | bc 2>/dev/null || echo "0") )); then
        log_info "PASS: Menu rendering is fast (<10ms)"
    else
        log_warn "SLOW: Menu rendering could be optimized (>=10ms)"
    fi
}

# Test 2: Clear screen performance
test_clear_performance() {
    log_step "Test 2: Screen Clear Performance"
    
    local iterations=50
    local total_time=0
    
    for i in $(seq 1 $iterations); do
        local time
        time=$(measure_time "clear_$i" "printf '\\033[2J\\033[H'")
        total_time=$(echo "$total_time + $time" | bc 2>/dev/null || echo "0")
    done
    
    local avg=$(echo "scale=3; $total_time / $iterations" | bc 2>/dev/null || echo "0")
    log_metric "Average clear time: ${avg}ms"
    
    if (( $(echo "$avg < 1" | bc 2>/dev/null || echo "0") )); then
        log_info "PASS: Screen clear is very fast (<1ms)"
    fi
}

# Test 3: Input handling performance
test_input_performance() {
    log_step "Test 3: Input Handling Performance"
    
    # Simulate input reading
    local iterations=100
    local total_time=0
    
    for i in $(seq 1 $iterations); do
        local start end duration
        start=$(date +%s%N)
        
        # Simulate input check (non-blocking)
        read -t 0.001 dummy 2>/dev/null || true
        
        end=$(date +%s%N)
        duration=$((end - start))
        total_time=$((total_time + duration))
    done
    
    local avg_ns=$((total_time / iterations))
    local avg_ms=$(echo "scale=3; $avg_ns / 1000000" | bc 2>/dev/null || echo "0")
    
    log_metric "Average input check time: ${avg_ms}ms (${avg_ns}ns)"
    
    if (( avg_ns < 1000000 )); then
        log_info "PASS: Input handling is very fast (<1ms)"
    fi
}

# Test 4: Cache performance
test_cache_performance() {
    log_step "Test 4: Cache Performance"
    
    local cache_file="/tmp/test_cache"
    local iterations=1000
    
    # Write cache
    echo "test data" > "$cache_file"
    
    # Test cache read performance
    local start end duration
    start=$(date +%s%N)
    
    for i in $(seq 1 $iterations); do
        cat "$cache_file" >/dev/null
    done
    
    end=$(date +%s%N)
    duration=$((end - start))
    
    local avg_ns=$((duration / iterations))
    local avg_us=$(echo "scale=1; $avg_ns / 1000" | bc 2>/dev/null || echo "0")
    
    rm -f "$cache_file"
    
    log_metric "Average cache read time: ${avg_us}µs (${avg_ns}ns)"
    
    if (( avg_ns < 100000 )); then
        log_info "PASS: Cache access is very fast (<100µs)"
    fi
}

# Test 5: Overall menu loop performance
test_menu_loop_performance() {
    log_step "Test 5: Menu Loop Performance"
    
    local iterations=10
    local total_time=0
    
    # Simulate menu loop
    for i in $(seq 1 $iterations); do
        local start end duration
        start=$(date +%s%N)
        
        # Simulate typical menu operations
        printf '\033[2J\033[H' >/dev/null
        echo "Menu Header" >/dev/null
        echo "1. Option 1" >/dev/null
        echo "2. Option 2" >/dev/null
        echo "0. Exit" >/dev/null
        
        end=$(date +%s%N)
        duration=$((end - start))
        total_time=$((total_time + duration))
    done
    
    local avg_ns=$((total_time / iterations))
    local avg_ms=$(echo "scale=2; $avg_ns / 1000000" | bc 2>/dev/null || echo "0")
    
    log_metric "Average menu loop time: ${avg_ms}ms"
    
    if (( $(echo "$avg_ms < 50" | bc 2>/dev/null || echo "0") )); then
        log_info "PASS: Menu loop is fast (<50ms)"
    else
        log_warn "SLOW: Menu loop could be optimized (>=50ms)"
    fi
}

# Generate final report
generate_report() {
    log_step "Generating Performance Report"
    
    local report_file="$RESULTS_DIR/performance_report.txt"
    
    {
        echo "========================================"
        echo "User Manager Performance Test Report"
        echo "Generated: $(date)"
        echo "Version: $TEST_VERSION"
        echo "========================================"
        echo ""
        
        if [[ -f "$RESULTS_DIR/timing.results" ]]; then
            echo "Timing Results:"
            echo "---------------"
            while IFS=: read -r name time exit_code; do
                printf "%-30s: %10s ms (exit: %d)\n" "$name" "$time" "$exit_code"
            done < "$RESULTS_DIR/timing.results"
            echo ""
        fi
        
        echo "Test Summary:"
        echo "------------"
        echo "All performance tests completed."
        echo ""
        echo "Recommendations:"
        echo "---------------"
        
        # Add recommendations based on results
        if [[ -f "$RESULTS_DIR/timing.results" ]]; then
            local avg_menu_time
            avg_menu_time=$(grep "menu_render_" "$RESULTS_DIR/timing.results" | cut -d: -f2 | head -1)
            if [[ -n "$avg_menu_time" ]]; then
                if (( $(echo "$avg_menu_time >= 10" | bc 2>/dev/null || echo "0") )); then
                    echo "- Consider using line-based updates instead of full screen clear"
                    echo "- Cache menu structures to reduce redraw overhead"
                fi
            fi
        fi
        
        echo ""
        echo "========================================"
        
    } > "$report_file"
    
    log_info "Report generated: $report_file"
    cat "$report_file"
}

# Main test runner
main() {
    echo -e "${C_BOLD}User Manager Performance Test Suite v${TEST_VERSION}${C_RESET}"
    echo ""
    
    # Parse options
    case "${1:-}" in
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help     Show this help"
            echo "  -v, --version  Show version"
            echo "  --quick        Run quick tests only"
            echo ""
            exit 0
            ;;
        -v|--version)
            echo "Performance Test Suite v${TEST_VERSION}"
            exit 0
            ;;
        --quick)
            export QUICK_MODE=1
            ;;
    esac
    
    # Initialize
    init_tests
    
    # Run tests
    if [[ "${QUICK_MODE:-0}" == "1" ]]; then
        log_info "Running quick tests only..."
        test_clear_performance
        test_input_performance
    else
        log_info "Running full performance test suite..."
        test_menu_rendering
        test_clear_performance
        test_input_performance
        test_cache_performance
        test_menu_loop_performance
    fi
    
    # Generate report
    generate_report
    
    echo ""
    log_info "All performance tests completed!"
}

main "$@"
