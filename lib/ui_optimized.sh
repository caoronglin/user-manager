#!/bin/bash
# ui_optimized.sh - High-performance UI optimizations
# Reduced redraw overhead, line-based updates, cached rendering

# Performance-optimized clear - only clear changed lines
# Usage: smart_clear <line_count>
smart_clear() {
    local lines="${1:-24}"
    # Move cursor to top and clear from cursor to end of screen
    printf '\033[H\033[J'
}

# Line-based screen update - preserves unchanged lines
# Usage: line_update <line_number> <content>
line_update() {
    local line="$1"
    local content="$2"
    # Move cursor to specific line and clear it
    printf '\033[%d;1H\033[K%s' "$line" "$content"
}

# Optimized header drawing with caching
# Cache header to avoid recalculation
declare -A _HEADER_CACHE
declare -A _HEADER_CACHE_TIME
readonly HEADER_CACHE_TTL=5  # 5 seconds

draw_header_cached() {
    local title="$1"
    local cache_key="$title"
    local now=$(date +%s)
    
    # Check cache
    if [[ -n "${_HEADER_CACHE[$cache_key]:-}" ]]; then
        local cache_time="${_HEADER_CACHE_TIME[$cache_key]:-0}"
        if (( now - cache_time < HEADER_CACHE_TTL )); then
            # Use cached output
            echo "${_HEADER_CACHE[$cache_key]}"
            return 0
        fi
    fi
    
    # Generate fresh output
    local output=""
    local hline=""
    for ((i=0; i<54; i++)); do hline+="─"; done
    
    output+="  \033[38;5;243m${hline}\033[0m\n"
    output+="  \033[38;5;75m■\033[0m \033[1m\033[1;37m${title}\033[0m\n"
    output+="  \033[38;5;243m${hline}\033[0m\n"
    
    # Cache the result
    _HEADER_CACHE[$cache_key]="$output"
    _HEADER_CACHE_TIME[$cache_key]="$now"
    
    echo "$output"
}

# Progressive rendering - render content in chunks to improve perceived performance
# Usage: progressive_render <content_array_name> <chunk_size>
progressive_render() {
    local -n _content=$1
    local chunk_size="${2:-5}"
    local total=${#_content[@]}
    local i=0
    
    while (( i < total )); do
        local chunk_end=$((i + chunk_size))
        (( chunk_end > total )) && chunk_end=$total
        
        for ((j=i; j<chunk_end; j++)); do
            echo "${_content[$j]}"
        done
        
        i=$chunk_end
        
        # Small delay between chunks for visual feedback
        (( i < total )) && sleep 0.01
    done
}

# Optimized line drawing using printf batching
# Usage: batch_lines <count> <char>
batch_lines() {
    local count="$1"
    local char="${2:-─}"
    local line=""
    
    for ((i=0; i<count; i++)); do
        line+="$char"
    done
    
    echo "$line"
}

# Smart cursor positioning - minimize cursor movement
# Usage: smart_cursor <action> [args]
smart_cursor() {
    local action="$1"
    
    case "$action" in
        save)
            printf '\033[s'  # Save cursor position
            ;;
        restore)
            printf '\033[u'  # Restore cursor position
            ;;
        home)
            printf '\033[H'  # Move to top-left
            ;;
        hide)
            printf '\033[?25l'  # Hide cursor
            ;;
        show)
            printf '\033[?25h'  # Show cursor
            ;;
    esac
}

# Export all functions
export -f smart_clear
export -f line_update
export -f draw_header_cached
export -f progressive_render
export -f batch_lines
export -f smart_cursor
