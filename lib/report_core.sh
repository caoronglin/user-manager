#!/bin/bash
# report_core.sh - 报告生成核心模块 v5.0
# 提供日志查询、统计分析、HTML 报告生成、邮件发送功能

# ============================================================
# HTML 报告生成辅助函数
# ============================================================

# 生成 HTML 头部（现代简洁风格）
generate_html_header() {
    local title="$1"
    local max_width="${2:-900px}"
    cat <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>${title}</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans SC','PingFang SC','Hiragino Sans GB','Microsoft YaHei',sans-serif;background:#f6f8fb;color:#1e293b;line-height:1.7;padding:24px 16px;font-size:14px;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
code,pre,.mono{font-family:'JetBrains Mono','Fira Code','SF Mono','Cascadia Code',Consolas,monospace;font-size:13px}
.container{max-width:${max_width};margin:0 auto}
.header{background:#fff;border:1px solid #e2e8f0;border-top:4px solid #16a34a;border-radius:10px;padding:24px;margin-bottom:24px;box-shadow:0 1px 3px rgba(15,23,42,.06)}
.header h1{font-size:24px;font-weight:700;color:#0f172a;letter-spacing:-0.025em}
.header .subtitle{font-size:13px;color:#64748b;margin-top:6px;font-weight:400}
.section{margin-bottom:28px}
.section-title{font-size:16px;font-weight:700;color:#0f172a;margin-bottom:12px;padding-left:10px;border-left:4px solid #16a34a;letter-spacing:0}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;box-shadow:0 1px 3px rgba(15,23,42,.06);padding:18px;margin-bottom:16px}
.stat-row,.metric-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin-bottom:16px}
.stat-card,.metric{background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:16px}
.stat-card .label{font-size:12px;color:#64748b;margin-bottom:4px;font-weight:500;text-transform:uppercase;letter-spacing:0.05em}
.stat-card .value{font-size:24px;font-weight:700;color:#0f172a;letter-spacing:-0.025em}
.stat-card .value.green{color:#16a34a}
.metric .label{font-size:12px;color:#64748b;margin-bottom:4px;font-weight:600}
.metric .value{font-size:20px;color:#0f172a;font-weight:700}
.kv-table td:first-child{color:#64748b;width:150px}
.kv-table td:last-child{font-weight:500}
table{width:100%;border-collapse:collapse;font-size:14px}
th{background:#f8fafc;color:#475569;font-weight:600;text-align:left;padding:10px 12px;border-bottom:2px solid #e2e8f0;font-size:13px;letter-spacing:0.02em}
td{padding:10px 12px;border-bottom:1px solid #f1f5f9;color:#334155}
tr:hover td{background:#f8fafc}
.progress-bar{width:100%;height:8px;background:#e2e8f0;border-radius:4px;overflow:hidden}
.progress-fill{height:100%;border-radius:4px;transition:width 0.3s}
.progress-success{background:#22c55e}
.progress-warning{background:#eab308}
.progress-danger{background:#ef4444}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:12px;font-weight:500}
.badge-success{background:#f0fdf4;color:#16a34a}
.badge-warning{background:#fefce8;color:#ca8a04}
.badge-danger{background:#fef2f2;color:#dc2626}
.tip-box{background:#f0fdf4;border-left:3px solid #16a34a;border-radius:4px;padding:12px 16px;font-size:13px;color:#166534;margin-top:12px;line-height:1.8}
.muted{color:#64748b}
.footer{margin-top:32px;padding-top:16px;border-top:1px solid #e2e8f0;font-size:12px;color:#94a3b8;text-align:center}
</style>
</head>
<body>
<div class="container">
HTMLEOF
}

# 生成 HTML 尾部
generate_html_footer() {
    local current_time
    current_time=$(date '+%Y-%m-%d %H:%M:%S')
    cat <<HTMLEOF
<div class="footer">
  生成时间：${current_time}
</div>
</div>
</body>
</html>
HTMLEOF
}

# 根据使用率百分比返回进度条 CSS 类
get_progress_class() {
    local pct="$1"
    if (( pct >= 90 )); then
        echo "progress-danger"
    elif (( pct >= 70 )); then
        echo "progress-warning"
    else
        echo "progress-success"
    fi
}

# 根据使用率百分比返回徽章 CSS 类
get_badge_class() {
    local pct="$1"
    if (( pct >= 90 )); then
        echo "badge-danger"
    elif (( pct >= 70 )); then
        echo "badge-warning"
    else
        echo "badge-success"
    fi
}

report_run_timeout() {
    local seconds="${1:-5}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

report_sum_user_threads() {
    local username="${1:-}"
    [[ -n "$username" ]] || { printf '0\n'; return 0; }
    ps -u "$username" -o nlwp --no-headers 2>/dev/null | awk '{sum += $1} END {print sum + 0}'
}

report_count_user_job_submissions() {
    local username="${1:-}" days="${2:-30}" count=0
    [[ -n "$username" ]] || { printf '0\n'; return 0; }

    local stats_dir="${JOB_STATS_DIR:-${DATA_BASE:-/tmp}/job_stats}"
    local stats_file="$stats_dir/${username}.csv"
    if [[ -f "$stats_file" ]]; then
        count=$(awk -F',' 'NR > 1 && $1 != "" {count++} END {print count + 0}' "$stats_file")
    fi

    if [[ "${REPORT_ENABLE_SCHEDULER_STATS:-0}" == "1" ]] && command -v sacct >/dev/null 2>&1; then
        local start_date scheduler_count
        start_date=$(date -d "${days} days ago" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        scheduler_count=$(report_run_timeout 5 sacct -u "$username" -S "$start_date" -n -X -o JobID 2>/dev/null | awk 'NF {count++} END {print count + 0}')
        [[ "$scheduler_count" =~ ^[0-9]+$ ]] && (( scheduler_count > count )) && count="$scheduler_count"
    fi

    printf '%s\n' "${count:-0}"
}

report_get_system_network_usage() {
    local rx_tx rx tx
    if [[ ! -r /proc/net/dev ]]; then
        printf '不可用'
        return 0
    fi
    rx_tx=$(awk -F'[: ]+' 'NR > 2 && $2 != "lo" {rx += $3; tx += $11} END {printf "%d:%d", rx, tx}' /proc/net/dev)
    rx="${rx_tx%%:*}"
    tx="${rx_tx#*:}"
    printf '接收 %s / 发送 %s' "$(bytes_to_human "${rx:-0}")" "$(bytes_to_human "${tx:-0}")"
}

report_get_user_network_usage() {
    local username="${1:-}" traffic_file latest rx tx
    [[ -n "$username" ]] || { printf '未启用用户流量记账'; return 0; }
    traffic_file="${JOB_STATS_DIR:-${DATA_BASE:-/tmp}/job_stats}/${username}_traffic.csv"
    if [[ -f "$traffic_file" ]]; then
        latest=$(tail -n 1 "$traffic_file" 2>/dev/null || true)
        IFS=',' read -r _ rx tx <<< "$latest"
        if [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
            printf '接收 %s / 发送 %s' "$(bytes_to_human "$rx")" "$(bytes_to_human "$tx")"
            return 0
        fi
    fi
    printf '未启用用户流量记账'
}

report_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

report_get_login_stats() {
    local username="${1:-}" limit="${REPORT_LOGIN_SCAN_LIMIT:-200}"
    [[ -n "$username" ]] || { printf '0|无记录\n'; return 0; }
    command -v last >/dev/null 2>&1 || { printf '0|无记录\n'; return 0; }
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=200

    last -w "$username" 2>/dev/null | head -n "$limit" | awk -v user="$username" '
        $1 == user {
            count++
            if ($3 != "" && $3 != "-" && $3 != ":0" && $3 !~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) {
                ips[$3] = 1
            }
        }
        END {
            for (ip in ips) {
                list = (list == "" ? ip : list ", " ip)
            }
            if (list == "") list = "无记录"
            printf "%d|%s\n", count + 0, list
        }'
}

# ============================================================
# 系统 HTML 报告
# ============================================================

# 生成完整系统 HTML 报告
generate_html_report() {
    local output_file="${1:-$REPORT_DIR/system_report.html}"
    mkdir -p "$(dirname "$output_file")"

    msg_info "正在生成系统报告..."

    {
        generate_html_header "系统资源报告" "900px"

        echo '<div class="header">'
        echo '  <h1>系统资源报告</h1>'
        echo "  <div class=\"subtitle\">$(date '+%Y-%m-%d %H:%M:%S')</div>"
        echo '</div>'

        generate_html_overview_section
        generate_html_quota_section
        generate_html_resource_section
        generate_html_resource_usage_section
        generate_html_log_section

        generate_html_footer
    } > "$output_file"

    msg_ok "系统报告已生成: ${C_BOLD}${output_file}${C_RESET}"
}

# 系统概览区块
generate_html_overview_section() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)
    local user_count=${#managed_users[@]}

    # 统计磁盘
    local total_disk_bytes=0
    local used_disk_bytes=0
    local online_count=0
    local disk_num idx mp

    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp="${DATA_BASE}/data${idx}"
        mountpoint -q "$mp" 2>/dev/null || continue
        ((online_count+=1))
        local df_line
        df_line=$(df -B1 "$mp" 2>/dev/null | awk 'NR==2 {print $2, $3}')
        if [[ -n "$df_line" ]]; then
            local t u
            read -r t u <<< "$df_line"
            total_disk_bytes=$((total_disk_bytes + t))
            used_disk_bytes=$((used_disk_bytes + u))
        fi
    done

    local total_human used_human
    total_human=$(bytes_to_human "$total_disk_bytes")
    used_human=$(bytes_to_human "$used_disk_bytes")

    # 暂停用户数
    local suspended_count=0
    if [[ -f "$DISABLED_USERS_FILE" ]]; then
        suspended_count=$(grep -c '.' "$DISABLED_USERS_FILE" 2>/dev/null || echo 0)
    fi

    local total_threads=0 total_submissions=0 username
    for username in "${managed_users[@]}"; do
        local user_threads user_submissions
        user_threads=$(report_sum_user_threads "$username")
        user_submissions=$(report_count_user_job_submissions "$username" 30)
        [[ "$user_threads" =~ ^[0-9]+$ ]] || user_threads=0
        [[ "$user_submissions" =~ ^[0-9]+$ ]] || user_submissions=0
        total_threads=$((total_threads + user_threads))
        total_submissions=$((total_submissions + user_submissions))
    done

    local network_usage
    network_usage=$(report_get_system_network_usage)

    cat <<HTMLEOF
<div class="section">
  <div class="section-title">系统概览</div>
  <div class="stat-row">
    <div class="stat-card">
      <div class="label">托管用户</div>
      <div class="value green">${user_count}</div>
    </div>
    <div class="stat-card">
      <div class="label">在线磁盘</div>
      <div class="value">${online_count} / ${#ALL_DISKS[@]}</div>
    </div>
    <div class="stat-card">
      <div class="label">总存储</div>
      <div class="value">${total_human}</div>
    </div>
    <div class="stat-card">
      <div class="label">已用存储</div>
      <div class="value">${used_human}</div>
    </div>
    <div class="stat-card">
      <div class="label">暂停用户</div>
      <div class="value">${suspended_count}</div>
    </div>
    <div class="stat-card">
      <div class="label">线程总数</div>
      <div class="value">${total_threads}</div>
    </div>
    <div class="stat-card">
      <div class="label">任务提交数</div>
      <div class="value">${total_submissions}</div>
    </div>
    <div class="stat-card">
      <div class="label">流量使用</div>
      <div class="value" style="font-size:16px">${network_usage}</div>
    </div>
  </div>
</div>
HTMLEOF
}

# 用户配额表格区块
generate_html_quota_section() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    cat <<'HTMLEOF'
<div class="section">
  <div class="section-title">用户配额</div>
  <div class="card">
  <table>
    <thead>
      <tr>
        <th>用户</th>
        <th>挂载点</th>
        <th>已用</th>
        <th>配额</th>
        <th>使用率</th>
        <th>状态</th>
      </tr>
    </thead>
    <tbody>
HTMLEOF

    if (( ${#managed_users[@]} == 0 )); then
        echo '      <tr><td colspan="6" style="text-align:center;color:#94a3b8;">暂无托管用户</td></tr>'
    else
        for username in "${managed_users[@]}"; do
            local home mp quota_info used_bytes limit_bytes pct
            home=$(get_user_home "$username" 2>/dev/null)
            [[ -z "$home" ]] && continue
            mp=$(get_user_mountpoint "$home" 2>/dev/null)
            [[ -z "$mp" ]] && continue

            quota_info=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
            used_bytes="${quota_info%%:*}"
            limit_bytes="${quota_info#*:}"

            [[ "$used_bytes" =~ ^[0-9]+$ ]]  || used_bytes=0
            [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0

            pct=0
            if (( limit_bytes > 0 )); then
                pct=$((used_bytes * 100 / limit_bytes))
            fi

            local used_h limit_h progress_cls badge_cls badge_text
            used_h=$(bytes_to_human "$used_bytes")
            limit_h=$(bytes_to_human "$limit_bytes")
            progress_cls=$(get_progress_class "$pct")
            badge_cls=$(get_badge_class "$pct")

            if (( pct >= 90 )); then
                badge_text="危险"
            elif (( pct >= 70 )); then
                badge_text="警告"
            else
                badge_text="正常"
            fi

            cat <<HTMLEOF
      <tr>
        <td>${username}</td>
        <td>${mp}</td>
        <td>${used_h}</td>
        <td>${limit_h}</td>
        <td>
          <div style="display:flex;align-items:center;gap:8px">
            <div class="progress-bar" style="flex:1"><div class="progress-fill ${progress_cls}" style="width:${pct}%"></div></div>
            <span style="font-size:13px;min-width:36px">${pct}%</span>
          </div>
        </td>
        <td><span class="badge ${badge_cls}">${badge_text}</span></td>
      </tr>
HTMLEOF
        done
    fi

    cat <<'HTMLEOF'
    </tbody>
  </table>
  </div>
</div>
HTMLEOF
}

# 资源限制表格区块
generate_html_resource_section() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    cat <<'HTMLEOF'
<div class="section">
  <div class="section-title">资源限制</div>
  <div class="card">
  <table>
    <thead>
      <tr>
        <th>用户</th>
        <th>CPU 配额</th>
        <th>内存限制</th>
        <th>状态</th>
      </tr>
    </thead>
    <tbody>
HTMLEOF

    if (( ${#managed_users[@]} == 0 )); then
        echo '      <tr><td colspan="4" style="text-align:center;color:#94a3b8;">暂无托管用户</td></tr>'
    else
        for username in "${managed_users[@]}"; do
            local limits cpu memory status_badge
            limits=$(get_current_resource_limits "$username" 2>/dev/null)
            cpu="${limits%%:*}"
            memory="${limits#*:}"

            if [[ -n "$cpu" || -n "$memory" ]]; then
                status_badge='<span class="badge badge-success">已配置</span>'
            else
                status_badge='<span class="badge" style="background:#f1f5f9;color:#94a3b8">未设置</span>'
            fi

            cat <<HTMLEOF
      <tr>
        <td>${username}</td>
        <td>${cpu:--}</td>
        <td>${memory:--}</td>
        <td>${status_badge}</td>
      </tr>
HTMLEOF
        done
    fi

    cat <<'HTMLEOF'
    </tbody>
  </table>
  </div>
</div>
HTMLEOF
}

# 用户实时资源使用情况 HTML 区块
# ============================================================
# generate_html_resource_usage_section - 生成 HTML 资源使用区块
# ============================================================
# 无参数函数，输出 HTML 格式的实时资源使用表格
# Returns: 0 始终成功
# ============================================================
generate_html_resource_usage_section() {
    # 防御性检查：确保 get_managed_usernames 函数可用
    if ! declare -F get_managed_usernames &>/dev/null; then
        echo '<!-- get_managed_usernames function not available -->'
        return 0
    fi

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    cat <<'HTMLEOF'
<div class="section">
  <div class="section-title">实时资源使用</div>
  <div class="card">
  <table>
    <thead>
      <tr>
        <th>用户</th>
        <th>进程数</th>
        <th>线程数</th>
        <th>CPU %</th>
        <th>内存 (RSS)</th>
        <th>磁盘 I/O</th>
        <th>流量使用</th>
        <th>任务提交数</th>
        <th>登录次数</th>
        <th>登录 IP/来源</th>
        <th>登录状态</th>
      </tr>
    </thead>
    <tbody>
HTMLEOF

    if (( ${#managed_users[@]} == 0 )); then
        echo '      <tr><td colspan="11" style="text-align:center;color:#94a3b8;">暂无托管用户</td></tr>'
    else
        for username in "${managed_users[@]}"; do
            local proc_count thread_count cpu_pct mem_rss io_read traffic_usage job_submissions login_status login_badge
            local login_stats login_count login_sources login_sources_html

            # 进程数
            proc_count=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
            thread_count=$(report_sum_user_threads "$username")
            job_submissions=$(report_count_user_job_submissions "$username" 30)
            traffic_usage=$(report_get_user_network_usage "$username")
            login_stats=$(report_get_login_stats "$username")
            login_count="${login_stats%%|*}"
            login_sources="${login_stats#*|}"
            login_sources_html=$(report_html_escape "$login_sources")

            # CPU 和内存使用
            if (( proc_count > 0 )); then
                cpu_pct=$(ps -u "$username" --no-headers -o pcpu 2>/dev/null | awk '{sum+=$1} END {printf "%.1f", sum}')
                mem_rss=$(ps -u "$username" --no-headers -o rss 2>/dev/null | awk '{sum+=$1} END {
                    if (sum >= 1048576) printf "%.1f GB", sum/1048576
                    else if (sum >= 1024) printf "%.1f MB", sum/1024
                    else printf "%d KB", sum
                }')
            else
                cpu_pct="0.0"
                mem_rss="0 KB"
            fi

            # 磁盘 I/O（从 /proc 统计）
            local uid
            uid=$(id -u "$username" 2>/dev/null)
            io_read="-"
            if [[ -n "$uid" ]]; then
                local total_io=0
                while IFS= read -r pid; do
                    if [[ -f "/proc/$pid/io" ]]; then
                        local rb
                        rb=$(awk '/^read_bytes:/ {print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
                        total_io=$((total_io + rb))
                    fi
                done < <(ps -u "$username" --no-headers -o pid 2>/dev/null | head -n "${REPORT_MAX_PROCESS_SCAN:-500}" | tr -d ' ')

                if (( total_io >= 1073741824 )); then
                    io_read=$(awk "BEGIN {printf \"%.1f GB\", $total_io / 1073741824}")
                elif (( total_io >= 1048576 )); then
                    io_read=$(awk "BEGIN {printf \"%.1f MB\", $total_io / 1048576}")
                elif (( total_io > 0 )); then
                    io_read=$(awk "BEGIN {printf \"%.1f KB\", $total_io / 1024}")
                else
                    io_read="0"
                fi
            fi

            # 登录状态
            if who 2>/dev/null | grep -q "^${username} "; then
                login_status="在线"
                login_badge='<span class="badge badge-success">在线</span>'
            else
                login_status="离线"
                login_badge='<span class="badge" style="background:#f1f5f9;color:#94a3b8">离线</span>'
            fi

            # CPU 颜色
            local cpu_val
            cpu_val=$(echo "$cpu_pct" | awk '{printf "%d", $1}')
            local cpu_style=""
            if (( cpu_val >= 80 )); then
                cpu_style="color:#dc2626;font-weight:600"
            elif (( cpu_val >= 50 )); then
                cpu_style="color:#ca8a04;font-weight:600"
            fi

            cat <<HTMLEOF
      <tr>
        <td>${username}</td>
        <td>${proc_count}</td>
        <td>${thread_count:-0}</td>
        <td style="${cpu_style}">${cpu_pct}%</td>
        <td>${mem_rss}</td>
        <td>${io_read}</td>
        <td>${traffic_usage}</td>
        <td>${job_submissions:-0}</td>
        <td>${login_count:-0}</td>
        <td class="mono" style="font-size:12px">${login_sources_html}</td>
        <td>${login_badge}</td>
      </tr>
HTMLEOF
        done
    fi

    cat <<'HTMLEOF'
    </tbody>
  </table>
  </div>
</div>
HTMLEOF
}

# 最近操作日志区块
generate_html_log_section() {
    cat <<'HTMLEOF'
<div class="section">
  <div class="section-title">最近操作</div>
  <div class="card">
HTMLEOF

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        echo '    <p style="color:#94a3b8;text-align:center">未找到操作日志</p>'
    else
        local total_lines
        total_lines=$(wc -l < "$USER_CREATION_LOG")

        if (( total_lines <= 1 )); then
            echo '    <p style="color:#94a3b8;text-align:center">暂无记录</p>'
        else
            cat <<'HTMLEOF'
    <table>
      <thead>
        <tr>
          <th>时间</th>
          <th>用户</th>
          <th>操作</th>
          <th>类型</th>
          <th>挂载点</th>
        </tr>
      </thead>
      <tbody>
HTMLEOF

            # 取最后 20 条记录（跳过首行标题），按时间倒序
            tail -n +2 "$USER_CREATION_LOG" | tail -20 | tac | while IFS=',' read -r timestamp username action user_type mountpoint home quota_gb; do
                cat <<HTMLEOF
        <tr>
          <td style="font-size:13px;color:#64748b">${timestamp}</td>
          <td>${username}</td>
          <td>${action}</td>
          <td>${user_type}</td>
          <td>${mountpoint}</td>
        </tr>
HTMLEOF
            done

            cat <<'HTMLEOF'
      </tbody>
    </table>
HTMLEOF
        fi
    fi

    echo '  </div>'
    echo '</div>'
}

# ============================================================
# 用户个人报告
# ============================================================

generate_user_personal_report() {
    local username="$1"
    local output_file="${2:-$REPORT_DIR/${username}_report.html}"

    if ! id "$username" &>/dev/null; then
        msg_err "用户 $username 不存在"
        return 1
    fi

    mkdir -p "$(dirname "$output_file")"

    local home mp quota_info used_bytes limit_bytes pct
    home=$(get_user_home "$username" 2>/dev/null)
    mp=$(get_user_mountpoint "$home" 2>/dev/null)

    used_bytes=0
    limit_bytes=0
    pct=0

    if [[ -n "$mp" ]]; then
        quota_info=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
        used_bytes="${quota_info%%:*}"
        limit_bytes="${quota_info#*:}"
        [[ "$used_bytes" =~ ^[0-9]+$ ]]  || used_bytes=0
        [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
        if (( limit_bytes > 0 )); then
            pct=$((used_bytes * 100 / limit_bytes))
        fi
    fi

    local used_h limit_h progress_cls badge_cls badge_text
    used_h=$(bytes_to_human "$used_bytes")
    limit_h=$(bytes_to_human "$limit_bytes")
    progress_cls=$(get_progress_class "$pct")
    badge_cls=$(get_badge_class "$pct")

    if (( pct >= 90 )); then badge_text="危险"
    elif (( pct >= 70 )); then badge_text="警告"
    else badge_text="正常"; fi

    # 获取资源限制
    local limits cpu_limit mem_limit
    limits=$(get_current_resource_limits "$username" 2>/dev/null)
    cpu_limit="${limits%%:*}"
    mem_limit="${limits#*:}"

    # 获取实时资源使用
    local proc_count thread_count real_cpu real_mem traffic_usage job_submissions login_stats login_count login_sources login_sources_html
    proc_count=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
    thread_count=$(report_sum_user_threads "$username")
    traffic_usage=$(report_get_user_network_usage "$username")
    job_submissions=$(report_count_user_job_submissions "$username" 30)
    login_stats=$(report_get_login_stats "$username")
    login_count="${login_stats%%|*}"
    login_sources="${login_stats#*|}"
    login_sources_html=$(report_html_escape "$login_sources")
    if (( proc_count > 0 )); then
        real_cpu=$(ps -u "$username" --no-headers -o pcpu 2>/dev/null | awk '{sum+=$1} END {printf "%.1f", sum}')
        real_mem=$(ps -u "$username" --no-headers -o rss 2>/dev/null | awk '{sum+=$1} END {
            if (sum >= 1048576) printf "%.1f GB", sum/1048576
            else if (sum >= 1024) printf "%.1f MB", sum/1024
            else printf "%d KB", sum
        }')
    else
        real_cpu="0.0"
        real_mem="0 KB"
    fi

    # 获取作业统计
    local weekly_stats monthly_stats
    weekly_stats=$(get_weekly_job_stats "$username" 2>/dev/null) || weekly_stats=""
    monthly_stats=$(get_monthly_job_stats "$username" 2>/dev/null) || monthly_stats=""

    local w_records=0 w_avg=0 w_max=0 w_min=0
    if [[ -n "$weekly_stats" ]]; then
        w_records=$(echo "$weekly_stats" | sed -n 's/.*records=\([0-9]*\).*/\1/p')
        w_avg=$(echo "$weekly_stats" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
        w_max=$(echo "$weekly_stats" | sed -n 's/.*max=\([0-9]*\).*/\1/p')
        w_min=$(echo "$weekly_stats" | sed -n 's/.*min=\([0-9]*\).*/\1/p')
    fi

    local m_records=0 m_avg=0 m_max=0 m_min=0
    if [[ -n "$monthly_stats" ]]; then
        m_records=$(echo "$monthly_stats" | sed -n 's/.*records=\([0-9]*\).*/\1/p')
        m_avg=$(echo "$monthly_stats" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
        m_max=$(echo "$monthly_stats" | sed -n 's/.*max=\([0-9]*\).*/\1/p')
        m_min=$(echo "$monthly_stats" | sed -n 's/.*min=\([0-9]*\).*/\1/p')
    fi

    {
        generate_html_header "个人资源报告 - ${username}" "700px"

        cat <<HTMLEOF
<div class="header">
  <h1>个人资源报告</h1>
  <div class="subtitle">${username} - $(date '+%Y-%m-%d %H:%M:%S')</div>
</div>

<div class="section">
  <div class="section-title">账户信息</div>
  <div class="card">
    <div class="metric-grid">
      <div class="metric"><div class="label">当前进程</div><div class="value">${proc_count}</div></div>
      <div class="metric"><div class="label">当前线程</div><div class="value">${thread_count:-0}</div></div>
      <div class="metric"><div class="label">当前 CPU</div><div class="value">${real_cpu}%</div></div>
      <div class="metric"><div class="label">当前内存</div><div class="value">${real_mem}</div></div>
      <div class="metric"><div class="label">近期登录次数</div><div class="value">${login_count:-0}</div></div>
      <div class="metric"><div class="label">任务提交数</div><div class="value">${job_submissions:-0}</div></div>
    </div>
    <table class="kv-table">
      <tr><td>用户名</td><td>${username}</td></tr>
      <tr><td>主目录</td><td>${home:--}</td></tr>
      <tr><td>挂载点</td><td>${mp:--}</td></tr>
      <tr><td>CPU 配额</td><td>${cpu_limit:--}</td></tr>
      <tr><td>内存限制</td><td>${mem_limit:--}</td></tr>
      <tr><td>流量使用</td><td>${traffic_usage}</td></tr>
      <tr><td>登录 IP/来源</td><td class="mono">${login_sources_html}</td></tr>
    </table>
  </div>
</div>

<div class="section">
  <div class="section-title">磁盘配额使用</div>
  <div class="card">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
      <span style="font-size:14px;color:#475569">已用：${used_h} / ${limit_h}</span>
      <span class="badge ${badge_cls}">${badge_text} (${pct}%)</span>
    </div>
    <div class="progress-bar" style="height:12px">
      <div class="progress-fill ${progress_cls}" style="width:${pct}%"></div>
    </div>
  </div>
</div>

<div class="section">
  <div class="section-title">任务统计</div>
  <div class="card">
    <table>
      <thead>
        <tr>
          <th>周期</th>
          <th>记录数</th>
          <th>平均进程数</th>
          <th>最大值</th>
          <th>最小值</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>最近 7 天</td>
          <td>${w_records:-0}</td>
          <td>${w_avg:-0}</td>
          <td>${w_max:-0}</td>
          <td>${w_min:-0}</td>
        </tr>
        <tr>
          <td>最近 30 天</td>
          <td>${m_records:-0}</td>
          <td>${m_avg:-0}</td>
          <td>${m_max:-0}</td>
          <td>${m_min:-0}</td>
        </tr>
      </tbody>
    </table>
  </div>
</div>

<div class="section">
  <div class="section-title">使用建议</div>
  <div class="card">
    <div class="tip-box">
      <p style="font-weight:600;margin-bottom:6px">建议</p>
      <ul style="margin:0;padding:0 0 0 18px;line-height:2">
        <li>定期查看磁盘使用率，避免超过配额。</li>
        <li>及时清理临时文件和不再使用的数据。</li>
        <li>可使用 <code>du -sh ~/*</code> 查看目录大小。</li>
        <li>需要调整配额、线程或资源限制时请联系管理员。</li>
      </ul>
    </div>
  </div>
</div>
HTMLEOF

        generate_html_footer
    } > "$output_file"

    msg_ok "个人报告已生成: ${C_BOLD}${output_file}${C_RESET}"
}

# ============================================================
# 邮件发送
# ============================================================

# 发送用户报告邮件（含重试机制）
send_user_report_email() {
    local username="$1"
    local report_file="$2"
    local max_retries=3

    if [[ ! -f "$report_file" ]]; then
        msg_err "报告文件不存在: $report_file"
        return 1
    fi

    local email
    email=$(get_user_email "$username")
    if [[ -z "$email" ]]; then
        msg_warn "用户 $username 未配置邮箱，跳过发送"
        return 1
    fi

    if ! [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        msg_err "用户邮箱格式无效: $email"
        return 1
    fi

    if declare -F validate_email_config >/dev/null 2>&1 && ! validate_email_config; then
        msg_err "邮件配置验证失败"
        return 1
    fi

    local from_name from_addr
    from_name=$(get_email_config "from_name")
    from_addr=$(get_email_config "from_address")
    from_name="${from_name:-用户管理系统}"
    from_addr="${from_addr:-noreply@example.com}"

    if declare -F sanitize_mail_header_value >/dev/null 2>&1; then
        from_name=$(sanitize_mail_header_value "$from_name")
        from_addr=$(sanitize_mail_header_value "$from_addr")
        email=$(sanitize_mail_header_value "$email")
    fi

    local subject
    subject="[${from_name}] 个人使用报告 - $(date '+%Y-%m-%d')"
    if declare -F sanitize_mail_header_value >/dev/null 2>&1; then
        subject=$(sanitize_mail_header_value "$subject")
    fi

    msg_step "正在发送报告至: ${email}"

    local attempt=0
    while (( attempt < max_retries )); do
        ((attempt+=1))

        local send_result
        {
            echo "From: ${from_name} <${from_addr}>"
            echo "To: ${email}"
            echo "Subject: ${subject}"
            echo "MIME-Version: 1.0"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            cat "$report_file"
        } | timeout 30 sendmail -t 2>/dev/null
        send_result=$?

        if [[ $send_result -eq 0 ]]; then
            msg_ok "报告已发送至: ${email}"
            return 0
        fi

        if (( attempt < max_retries )); then
            local wait_secs=$((attempt * 2))
            msg_warn "发送失败 (第 $attempt 次)，${wait_secs}s 后重试..."
            sleep "$wait_secs"
        fi
    done

    msg_err "报告发送失败: ${email} (已重试 $max_retries 次)"
    return 1
}

# 批量生成并发送所有用户报告
send_all_user_reports() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    if (( ${#managed_users[@]} == 0 )); then
        msg_warn "未找到托管用户"
        return 0
    fi

    msg_info "正在为 ${#managed_users[@]} 个用户生成并发送报告..."

    local sent=0 failed=0 skipped=0

    for username in "${managed_users[@]}"; do
        local report_file="$REPORT_DIR/${username}_report.html"

        # 生成个人报告
        if ! generate_user_personal_report "$username" "$report_file" 2>/dev/null; then
            msg_err "用户 $username 报告生成失败"
            ((failed+=1))
            continue
        fi

        # 发送邮件
        local email
        email=$(get_user_email "$username")
        if [[ -z "$email" ]]; then
            msg_warn "用户 $username 无邮箱，跳过"
            ((skipped+=1))
            continue
        fi

        if send_user_report_email "$username" "$report_file"; then
            ((sent+=1))
        else
            ((failed+=1))
        fi
    done

    echo ""
    msg_info "发送完成: ${C_BGREEN}成功 ${sent}${C_RESET}, ${C_BRED}失败 ${failed}${C_RESET}, ${C_RESET}跳过 ${skipped}${C_RESET}"
    [[ $failed -eq 0 ]]
}

# ============================================================
# 定时任务管理
# ============================================================

# 设置每周报告定时任务
setup_weekly_report_cron() {
    local cron_cmd="$SCRIPT_DIR/run.sh --send-reports >> $REPORT_DIR/weekly_report.log 2>&1"
    local cron_entry="0 9 * * 1 $cron_cmd"

    # 检查是否已存在
    if crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/run.sh --send-reports"; then
        msg_warn "每周报告定时任务已存在"
        return 0
    fi

    if (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -; then
        msg_ok "每周报告定时任务已创建（每周一 09:00）"
        msg_step "命令: ${cron_cmd}"
    else
        msg_err "定时任务创建失败"
        return 1
    fi
}

# 移除每周报告定时任务
remove_weekly_report_cron() {
    if ! crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/run.sh --send-reports"; then
        msg_warn "未找到每周报告定时任务"
        return 0
    fi

    if crontab -l 2>/dev/null | grep -vF "$SCRIPT_DIR/run.sh --send-reports" | crontab -; then
        msg_ok "每周报告定时任务已移除"
    else
        msg_err "定时任务移除失败"
        return 1
    fi
}

# 查看每周报告日志
view_weekly_report_log() {
    local log_file="$REPORT_DIR/weekly_report.log"

    if [[ ! -f "$log_file" ]]; then
        msg_warn "日志文件不存在: $log_file"
        return 0
    fi

    draw_header "每周报告日志"
    echo ""
    tail -50 "$log_file"
    echo ""
    draw_line 50
    msg_info "日志文件: $log_file"
}

# ============================================================
# 文本报告与查询
# ============================================================

# ============================================================
# 日志分析功能
# ============================================================

# 分析操作频率与趋势
analyze_operation_trends() {
    draw_header "操作趋势分析"

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi
    if [[ ! -r "$USER_CREATION_LOG" ]]; then
        msg_err_ctx "analyze_operation_trends" "日志文件不可读: $USER_CREATION_LOG"
        return 1
    fi

    local total_ops
    total_ops=$(( $(wc -l < "$USER_CREATION_LOG") - 1 ))
    if (( total_ops <= 0 )); then
        msg_info "暂无操作记录"
        return 0
    fi

    # 1. 按操作类型统计
    echo ""
    msg_info "${C_BOLD}操作类型分布:${C_RESET}"
    draw_line 50
    tail -n +2 "$USER_CREATION_LOG" | awk -F',' '{
        actions[$3]++
    } END {
        for (a in actions) printf "  %-20s %d\n", a, actions[a]
    }' | sort -t' ' -k2 -rn | while IFS= read -r line; do
        local action count
        action=$(echo "$line" | awk '{print $1}')
        count=$(echo "$line" | awk '{print $2}')
        printf "  ${C_RESET}%-20s${C_RESET} ${C_BOLD}%d${C_RESET}\n" "$action" "$count"
    done

    # 2. 按日期统计（最近 14 天）
    echo ""
    msg_info "${C_BOLD}最近 14 天操作频率:${C_RESET}"
    draw_line 50
    local cutoff_date
    cutoff_date=$(date -d '14 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-14d '+%Y-%m-%d' 2>/dev/null)

    tail -n +2 "$USER_CREATION_LOG" | awk -F',' -v cutoff="$cutoff_date" '{
        date = substr($1, 1, 10)
        if (date >= cutoff) daily[date]++
    } END {
        for (d in daily) printf "%s %d\n", d, daily[d]
    }' | sort | while read -r date count; do
        local bar=""
        local i
        for (( i = 0; i < count && i < 40; i++ )); do
            bar="${bar}#"
        done
        printf "  ${C_DIM}%-12s${C_RESET} ${C_RESET}%-40s${C_RESET} ${C_BOLD}%d${C_RESET}\n" "$date" "$bar" "$count"
    done

    # 3. 最活跃用户 TOP 10
    echo ""
    msg_info "${C_BOLD}最活跃用户 TOP 10:${C_RESET}"
    draw_line 50
    tail -n +2 "$USER_CREATION_LOG" | awk -F',' '{
        users[$2]++
    } END {
        for (u in users) printf "%d %s\n", users[u], u
    }' | sort -rn | head -10 | while read -r count username; do
        printf "  ${C_BOLD}%-16s${C_RESET} ${C_RESET}%d 次操作${C_RESET}\n" "$username" "$count"
    done

    # 4. 操作时段(小时)分布
    echo ""
    msg_info "${C_BOLD}操作时段分布:${C_RESET}"
    draw_line 50
    tail -n +2 "$USER_CREATION_LOG" | awk -F',' '{
        hour = substr($1, 12, 2)
        hours[hour+0]++
    } END {
        for (h = 0; h < 24; h++) printf "%02d %d\n", h, hours[h]+0
    }' | while read -r hour count; do
        local bar=""
        local i
        for (( i = 0; i < count && i < 30; i++ )); do
            bar="${bar}#"
        done
        if (( count > 0 )); then
            printf "  ${C_DIM}%s:00${C_RESET} ${C_BGREEN}%-30s${C_RESET} %d\n" "$hour" "$bar" "$count"
        fi
    done

    echo ""
    msg_info "共 ${C_BOLD}$total_ops${C_RESET} 条操作记录"
}

# 异常检测：高频操作、频繁密码修改、可疑删除
# ============================================================
# analyze_anomalies - 异常检测分析
# ============================================================
# 无参数函数，检测高频操作、频繁密码修改、批量删除等异常
# Returns: 0 始终成功
# ============================================================
analyze_anomalies() {
    draw_header "异常检测分析"

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi
    if [[ ! -r "$USER_CREATION_LOG" ]]; then
        msg_err_ctx "analyze_anomalies" "日志文件不可读: $USER_CREATION_LOG"
        return 1
    fi

    local anomaly_count=0

    # 1. 检测今日高频操作（>20 次视为异常）
    local today
    today=$(date '+%Y-%m-%d')
    local today_ops
    today_ops=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' -v d="$today" 'substr($1,1,10)==d {c++} END {print c+0}')

    if (( today_ops > 20 )); then
        echo ""
        msg_warn "⚠ 今日操作次数异常偏高: ${C_BRED}$today_ops${C_RESET} 次"
        ((anomaly_count+=1))
    fi

    # 2. 检测频繁密码修改（同一用户 7 天内 >3 次）
    echo ""
    msg_info "${C_BOLD}频繁密码修改检测 (7天内 >3次):${C_RESET}"
    draw_line 50
    local cutoff7
    cutoff7=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null)

    local found_freq=0
    while IFS= read -r line; do
        msg_warn "$line"
        found_freq=1
    done < <(tail -n +2 "$USER_CREATION_LOG" | awk -F',' -v cutoff="$cutoff7" '
        substr($1,1,10) >= cutoff && $3 ~ /password/ {
            users[$2]++
        }
        END {
            for (u in users) if (users[u] > 3) printf "  %s: %d 次\n", u, users[u]
        }')
    [[ $found_freq -eq 0 ]] && msg_ok "  未发现异常"

    # 3. 检测短时间内的批量删除
    echo ""
    msg_info "${C_BOLD}批量删除检测 (24小时内 >3次):${C_RESET}"
    draw_line 50
    local cutoff24h
    cutoff24h=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    local delete_count
    delete_count=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' -v cutoff="$cutoff24h" '
        $1 >= cutoff && $3 ~ /delete|DELETE/ {c++}
        END {print c+0}')

    if (( delete_count > 3 )); then
        msg_warn "⚠ 24小时内删除操作: ${C_BRED}$delete_count${C_RESET} 次"
        ((anomaly_count+=1))
    else
        msg_ok "  未发现异常 (删除 $delete_count 次)"
    fi

    # 4. 检测未知/异常操作类型
    echo ""
    msg_info "${C_BOLD}未知操作类型检测:${C_RESET}"
    draw_line 50
    local known_actions="create|update|delete|password_change|suspend|enable|rename|quota_modify|resource_set|resource_remove|backup|restore|schedule_backup|remove_schedule|batch_backup|symlink_create|symlink_delete|password_rotate"
    local unknown_ops
    unknown_ops=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' -v known="$known_actions" '
        BEGIN { split(known, arr, "|"); for (i in arr) valid[arr[i]] = 1 }
        !(tolower($3) in valid) { print $3 }
    ' | sort -u)

    if [[ -n "$unknown_ops" ]]; then
        echo "$unknown_ops" | while IFS= read -r op; do
            msg_warn "  未知操作: ${C_RESET}$op${C_RESET}"
        done
    else
        msg_ok "  所有操作类型均已知"
    fi

    echo ""
    if (( anomaly_count == 0 )); then
        msg_ok "未发现明显异常"
    else
        msg_warn "发现 $anomaly_count 个潜在异常，请关注"
    fi
}

# 生成日志摘要报告
generate_log_summary() {
    draw_header "日志摘要报告"

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi

    local total_ops
    total_ops=$(( $(wc -l < "$USER_CREATION_LOG") - 1 ))
    (( total_ops < 0 )) && total_ops=0

    if (( total_ops == 0 )); then
        msg_info "暂无操作记录"
        return 0
    fi

    # 时间范围
    local first_date last_date
    first_date=$(tail -n +2 "$USER_CREATION_LOG" | head -1 | cut -d',' -f1)
    last_date=$(tail -n +2 "$USER_CREATION_LOG" | tail -1 | cut -d',' -f1)

    echo ""
    draw_info_card "总操作数:" "$total_ops"
    draw_info_card "时间范围:" "$first_date ~ $last_date"

    # 操作统计
    local creates deletes updates pwd_changes
    creates=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /create/ {c++} END {print c+0}')
    deletes=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /delete/ {c++} END {print c+0}')
    updates=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /update|modify/ {c++} END {print c+0}')
    pwd_changes=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /password/ {c++} END {print c+0}')

    echo ""
    draw_info_card "创建操作:" "${C_BGREEN}$creates${C_RESET}"
    draw_info_card "删除操作:" "${C_BRED}$deletes${C_RESET}"
    draw_info_card "更新操作:" "${C_RESET}$updates${C_RESET}"
    draw_info_card "密码修改:" "${C_RESET}$pwd_changes${C_RESET}"

    # 唯一用户数
    local unique_users
    unique_users=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '{users[$2]=1} END {print length(users)}')
    echo ""
    draw_info_card "涉及用户数:" "$unique_users"

    echo ""
}

# 显示用户创建日志
show_user_creation_log() {
    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi

    local total_lines
    total_lines=$(wc -l < "$USER_CREATION_LOG")

    if (( total_lines <= 1 )); then
        msg_info "暂无操作记录"
        return 0
    fi

    draw_header "用户操作日志"
    echo ""

    # 表头
    printf "  ${C_BOLD}${C_WHITE}%-20s %-14s %-10s %-10s %-16s %-20s %s${C_RESET}\n" \
           "时间" "用户名" "操作" "类型" "挂载点" "主目录" "配额(GB)"
    draw_line 70

    tail -n +2 "$USER_CREATION_LOG" | while IFS=',' read -r timestamp username action user_type mountpoint home quota_gb; do
        local action_color="$C_RESET"
        case "$action" in
            *create*|*CREATE*) action_color="$C_BGREEN" ;;
            *delete*|*DELETE*) action_color="$C_BRED" ;;
            *update*|*UPDATE*|*modify*) action_color="$C_RESET" ;;
            *suspend*|*disable*) action_color="$C_BRED" ;;
            *enable*|*restore*) action_color="$C_RESET" ;;
        esac

        printf "  ${C_DIM}%-20s${C_RESET} ${C_BOLD}%-14s${C_RESET} ${action_color}%-10s${C_RESET} %-10s %-16s %-20s %s\n" \
               "$timestamp" "$username" "$action" "$user_type" "$mountpoint" "$home" "$quota_gb"
    done

    echo ""
    msg_info "共 $((total_lines - 1)) 条记录"
}

# 查询用户历史
query_user_history() {
    local username="$1"

    if [[ -z "$username" ]]; then
        msg_err "请提供用户名"
        return 1
    fi

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi

    draw_header "用户历史: ${username}"
    echo ""

    printf "  ${C_BOLD}${C_WHITE}%-20s %-10s %-10s %-16s %-20s %s${C_RESET}\n" \
           "时间" "操作" "类型" "挂载点" "主目录" "配额(GB)"
    draw_line 60

    tail -n +2 "$USER_CREATION_LOG" | while IFS=',' read -r timestamp uname action user_type mountpoint home quota_gb; do
        [[ "$uname" != "$username" ]] && continue

        local action_color="$C_RESET"
        case "$action" in
            *create*|*CREATE*) action_color="$C_BGREEN" ;;
            *delete*|*DELETE*) action_color="$C_BRED" ;;
            *update*|*UPDATE*|*modify*) action_color="$C_RESET" ;;
            *suspend*|*disable*) action_color="$C_BRED" ;;
            *enable*|*restore*) action_color="$C_RESET" ;;
        esac

        printf "  ${C_DIM}%-20s${C_RESET} ${action_color}%-10s${C_RESET} %-10s %-16s %-20s %s\n" \
               "$timestamp" "$action" "$user_type" "$mountpoint" "$home" "$quota_gb"
    done

    echo ""
}

# 按日期范围查询
query_by_date_range() {
    local start_date="$1"
    local end_date="$2"

    if [[ -z "$start_date" || -z "$end_date" ]]; then
        msg_err "请提供起始和结束日期 (YYYY-MM-DD)"
        return 1
    fi

    if [[ ! -f "$USER_CREATION_LOG" ]]; then
        msg_warn "日志文件不存在"
        return 0
    fi

    draw_header "日期范围查询: ${start_date} ~ ${end_date}"
    echo ""

    printf "  ${C_BOLD}${C_WHITE}%-20s %-14s %-10s %-10s %-16s %-20s %s${C_RESET}\n" \
           "时间" "用户名" "操作" "类型" "挂载点" "主目录" "配额(GB)"
    draw_line 70

    tail -n +2 "$USER_CREATION_LOG" | while IFS=',' read -r timestamp username action user_type mountpoint home quota_gb; do
        # 提取日期部分
        local record_date="${timestamp%% *}"
        [[ -z "$record_date" ]] && continue

        if [[ ! "$record_date" < "$start_date" && ! "$record_date" > "$end_date" ]]; then
            local action_color="$C_RESET"
            case "$action" in
                *create*|*CREATE*) action_color="$C_BGREEN" ;;
                *delete*|*DELETE*) action_color="$C_BRED" ;;
                *update*|*UPDATE*|*modify*) action_color="$C_RESET" ;;
            esac

            printf "  ${C_DIM}%-20s${C_RESET} ${C_BOLD}%-14s${C_RESET} ${action_color}%-10s${C_RESET} %-10s %-16s %-20s %s\n" \
                   "$timestamp" "$username" "$action" "$user_type" "$mountpoint" "$home" "$quota_gb"
        fi
    done

    echo ""
}

# 生成用户统计信息
generate_user_statistics() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)
    local user_count=${#managed_users[@]}

    draw_header "用户统计"
    echo ""

    # 用户数概览
    draw_info_card "托管用户总数:" "$user_count" "$C_RESET"

    # 暂停用户统计
    local suspended_count=0
    if [[ -f "$DISABLED_USERS_FILE" ]]; then
        suspended_count=$(grep -c '.' "$DISABLED_USERS_FILE" 2>/dev/null || echo 0)
    fi
    draw_info_card "暂停用户:" "$suspended_count" "$C_RESET"

    # 操作日志统计
    if [[ -f "$USER_CREATION_LOG" ]]; then
        local total_ops=0 create_ops=0 delete_ops=0 update_ops=0
        total_ops=$(( $(wc -l < "$USER_CREATION_LOG") - 1 ))
        (( total_ops < 0 )) && total_ops=0

        if (( total_ops > 0 )); then
            create_ops=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /create|CREATE/ {c++} END {print c+0}')
            delete_ops=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /delete|DELETE/ {c++} END {print c+0}')
            update_ops=$(tail -n +2 "$USER_CREATION_LOG" | awk -F',' '$3 ~ /update|UPDATE|modify/ {c++} END {print c+0}')
        fi

        echo ""
        draw_info_card "总操作次数:" "$total_ops" "$C_BOLD"
        draw_info_card "创建操作:" "$create_ops" "$C_BGREEN"
        draw_info_card "删除操作:" "$delete_ops" "$C_BRED"
        draw_info_card "更新操作:" "$update_ops" "$C_RESET"
    fi

    # 磁盘分布统计
    echo ""
    msg_info "${C_BOLD}用户磁盘分布:${C_RESET}"
    draw_line 40

    local disk_num idx mp disk_user_count
    for disk_num in "${ALL_DISKS[@]}"; do
        idx=$(printf "%02d" "$disk_num")
        mp="${DATA_BASE}/data${idx}"
        mountpoint -q "$mp" 2>/dev/null || continue

        disk_user_count=0
        for username in "${managed_users[@]}"; do
            local home
            home=$(get_user_home "$username" 2>/dev/null)
            if [[ "$home" == "${mp}/"* ]]; then
                ((disk_user_count+=1))
            fi
        done

        local color="$C_RESET"
        (( disk_user_count > 0 )) && color="$C_RESET"
        printf "  ${C_DIM}data${idx}${C_RESET}  ${color}%3d 个用户${C_RESET}\n" "$disk_user_count"
    done

    echo ""
}

# 生成配额报告（文本）
generate_quota_report() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    draw_header "配额使用报告"
    echo ""

    if (( ${#managed_users[@]} == 0 )); then
        msg_info "暂无托管用户"
        return 0
    fi

    printf "  ${C_BOLD}${C_WHITE}%-16s %-14s %-12s %-12s %-24s %s${C_RESET}\n" \
           "用户名" "挂载点" "已用" "配额" "使用率" "状态"
    draw_line 60

    for username in "${managed_users[@]}"; do
        local home mp quota_info used_bytes limit_bytes pct
        home=$(get_user_home "$username" 2>/dev/null)
        [[ -z "$home" ]] && continue
        mp=$(get_user_mountpoint "$home" 2>/dev/null)
        [[ -z "$mp" ]] && continue

        quota_info=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
        used_bytes="${quota_info%%:*}"
        limit_bytes="${quota_info#*:}"
        [[ "$used_bytes" =~ ^[0-9]+$ ]]  || used_bytes=0
        [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0

        pct=0
        (( limit_bytes > 0 )) && pct=$((used_bytes * 100 / limit_bytes))

        local used_h limit_h
        used_h=$(bytes_to_human "$used_bytes")
        limit_h=$(bytes_to_human "$limit_bytes")

        local mp_short="${mp##*/}"

        printf "  ${C_BOLD}%-16s${C_RESET} %-14s %-12s %-12s " \
               "$username" "$mp_short" "$used_h" "$limit_h"
        draw_usage_bar "$pct" 16
        echo ""
    done

    echo ""
}

# 生成资源报告（文本）
generate_resource_report() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    draw_header "资源限制报告"
    echo ""

    if (( ${#managed_users[@]} == 0 )); then
        msg_info "暂无托管用户"
        return 0
    fi

    printf "  ${C_BOLD}${C_WHITE}%-18s %-12s %-12s %s${C_RESET}\n" \
           "用户名" "CPU 配额" "内存限制" "状态"
    draw_line 52

    local configured=0
    for username in "${managed_users[@]}"; do
        local limits cpu memory status_text status_color
        limits=$(get_current_resource_limits "$username" 2>/dev/null)
        cpu="${limits%%:*}"
        memory="${limits#*:}"

        if [[ -n "$cpu" || -n "$memory" ]]; then
            status_text="已配置"
            status_color="$C_BGREEN"
            ((configured+=1))
        else
            status_text="未设置"
            status_color="$C_DIM"
        fi

        printf "  %-18s " "$username"
        if [[ -n "$cpu" ]]; then
            printf "${C_RESET}%-12s${C_RESET} " "$cpu"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        if [[ -n "$memory" ]]; then
            printf "${C_RESET}%-12s${C_RESET} " "$memory"
        else
            printf "${C_DIM}%-12s${C_RESET} " "-"
        fi
        echo -e "${status_color}${status_text}${C_RESET}"
    done

    echo ""
    msg_info "共 ${#managed_users[@]} 个用户, ${configured} 个已配置资源限制"
    echo ""
}

# 显示用户实时资源使用报告（终端）
show_user_resource_usage() {
    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    draw_header "用户实时资源使用"
    echo ""

    if (( ${#managed_users[@]} == 0 )); then
        msg_info "暂无托管用户"
        return 0
    fi

    printf "  ${C_BOLD}${C_WHITE}%-16s %-8s %-8s %-10s %-12s %-12s %-18s %-10s %-8s %-20s %s${C_RESET}\n" \
           "用户名" "进程数" "线程数" "CPU %" "内存(RSS)" "磁盘I/O" "流量使用" "任务提交数" "登录数" "登录IP/来源" "登录状态"
    draw_line 140

    for username in "${managed_users[@]}"; do
        local proc_count thread_count cpu_pct mem_rss io_total traffic_usage job_submissions login_status login_stats login_count login_sources

        proc_count=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
        thread_count=$(report_sum_user_threads "$username")
        traffic_usage=$(report_get_user_network_usage "$username")
        job_submissions=$(report_count_user_job_submissions "$username" 30)
        login_stats=$(report_get_login_stats "$username")
        login_count="${login_stats%%|*}"
        login_sources="${login_stats#*|}"
        [[ ${#login_sources} -gt 20 ]] && login_sources="${login_sources:0:17}..."

        if (( proc_count > 0 )); then
            cpu_pct=$(ps -u "$username" --no-headers -o pcpu 2>/dev/null | awk '{sum+=$1} END {printf "%.1f", sum}')
            mem_rss=$(ps -u "$username" --no-headers -o rss 2>/dev/null | awk '{sum+=$1} END {
                if (sum >= 1048576) printf "%.1f GB", sum/1048576
                else if (sum >= 1024) printf "%.1f MB", sum/1024
                else printf "%d KB", sum
            }')
        else
            cpu_pct="0.0"
            mem_rss="0 KB"
        fi

        # I/O
        local total_io=0
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            if [[ -f "/proc/${pid}/io" ]]; then
                local rb
                rb=$(awk '/^read_bytes:/ {print $2}' "/proc/${pid}/io" 2>/dev/null || echo 0)
                total_io=$((total_io + rb))
            fi
        done < <(ps -u "$username" --no-headers -o pid 2>/dev/null | head -n "${REPORT_MAX_PROCESS_SCAN:-500}" | tr -d ' ')

        if (( total_io >= 1073741824 )); then
            io_total=$(awk "BEGIN {printf \"%.1f GB\", $total_io / 1073741824}")
        elif (( total_io >= 1048576 )); then
            io_total=$(awk "BEGIN {printf \"%.1f MB\", $total_io / 1048576}")
        else
            io_total="0 KB"
        fi

        # 登录状态
        if who 2>/dev/null | grep -q "^${username} "; then
            login_status="${C_BGREEN}在线${C_RESET}"
        else
            login_status="${C_DIM}离线${C_RESET}"
        fi

        local cpu_color="$C_RESET"
        local cpu_val
        cpu_val=$(echo "$cpu_pct" | awk '{printf "%d", $1}')
        if (( cpu_val >= 80 )); then
            cpu_color="$C_BRED"
        elif (( cpu_val >= 50 )); then
            cpu_color="$C_RESET"
        fi

        printf "  ${C_BOLD}%-16s${C_RESET} %-8s %-8s ${cpu_color}%-10s${C_RESET} %-12s %-12s %-18s %-10s %-8s %-20s " \
               "$username" "$proc_count" "${thread_count:-0}" "${cpu_pct}%" "$mem_rss" "$io_total" "$traffic_usage" "${job_submissions:-0}" "${login_count:-0}" "$login_sources"
        echo -e "$login_status"
    done

    echo ""
}

# 单用户详细资源报告
show_single_user_resource() {
    local username="$1"

    if [[ -z "$username" ]] || ! id "$username" &>/dev/null; then
        msg_err "用户不存在: $username"
        return 1
    fi

    draw_header "用户资源详情 — $username"
    echo ""

    # 进程列表（TOP 10）
    local proc_count login_stats login_count login_sources
    proc_count=$(ps -u "$username" --no-headers 2>/dev/null | wc -l)
    login_stats=$(report_get_login_stats "$username")
    login_count="${login_stats%%|*}"
    login_sources="${login_stats#*|}"
    draw_info_card "总进程数:" "$proc_count"
    draw_info_card "近期登录次数:" "${login_count:-0}"
    draw_info_card "登录IP/来源:" "$login_sources"

    if (( proc_count > 0 )); then
        local total_cpu total_mem
        total_cpu=$(ps -u "$username" --no-headers -o pcpu 2>/dev/null | awk '{sum+=$1} END {printf "%.1f", sum}')
        total_mem=$(ps -u "$username" --no-headers -o rss 2>/dev/null | awk '{sum+=$1} END {
            if (sum >= 1048576) printf "%.1f GB", sum/1048576
            else if (sum >= 1024) printf "%.1f MB", sum/1024
            else printf "%d KB", sum
        }')
        draw_info_card "总 CPU:" "${total_cpu}%"
        draw_info_card "总内存:" "$total_mem"

        echo ""
        msg_info "${C_BOLD}资源占用 TOP 10 进程:${C_RESET}"
        printf "  ${C_DIM}%-8s %-8s %-8s %-40s${C_RESET}\n" "PID" "CPU%" "MEM%" "COMMAND"
        draw_line 65
        ps -u "$username" --no-headers -o pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -10 | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
    fi

    # 登录会话
    echo ""
    msg_info "${C_BOLD}当前登录会话:${C_RESET}"
    local sessions
    sessions=$(who 2>/dev/null | grep "^${username} " || true)
    if [[ -n "$sessions" ]]; then
        echo "$sessions" | while IFS= read -r line; do
            echo "  ${C_RESET}$line${C_RESET}"
        done
    else
        msg_info "  当前无活跃会话"
    fi

    echo ""
}

# 导出完整文本报告
export_full_report() {
    local output_file="${1:-$REPORT_DIR/full_report_$(date '+%Y%m%d_%H%M%S').txt}"
    mkdir -p "$(dirname "$output_file")"

    msg_info "正在生成完整报告..."

    {
        echo "=============================================="
        echo "  系统管理完整报告"
        echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=============================================="
        echo ""

        echo "[用户统计]"
        echo "----------------------------------------------"
        local managed_users=()
        mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)
        echo "托管用户数: ${#managed_users[@]}"

        local suspended_count=0
        if [[ -f "$DISABLED_USERS_FILE" ]]; then
            suspended_count=$(grep -c '.' "$DISABLED_USERS_FILE" 2>/dev/null || echo 0)
        fi
        echo "暂停用户数: $suspended_count"
        echo ""

        echo "[配额使用]"
        echo "----------------------------------------------"
        printf "%-16s %-14s %-12s %-12s %s\n" "用户名" "挂载点" "已用" "配额" "使用率"
        echo "----------------------------------------------"
        for username in "${managed_users[@]}"; do
            local home mp quota_info used_bytes limit_bytes pct
            home=$(get_user_home "$username" 2>/dev/null)
            [[ -z "$home" ]] && continue
            mp=$(get_user_mountpoint "$home" 2>/dev/null)
            [[ -z "$mp" ]] && continue

            quota_info=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
            used_bytes="${quota_info%%:*}"
            limit_bytes="${quota_info#*:}"
            [[ "$used_bytes" =~ ^[0-9]+$ ]]  || used_bytes=0
            [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0

            pct=0
            (( limit_bytes > 0 )) && pct=$((used_bytes * 100 / limit_bytes))

            printf "%-16s %-14s %-12s %-12s %d%%\n" \
                   "$username" "${mp##*/}" "$(bytes_to_human "$used_bytes")" "$(bytes_to_human "$limit_bytes")" "$pct"
        done
        echo ""

        echo "[资源限制]"
        echo "----------------------------------------------"
        printf "%-18s %-12s %-12s %s\n" "用户名" "CPU配额" "内存限制" "状态"
        echo "----------------------------------------------"
        for username in "${managed_users[@]}"; do
            local limits cpu memory status_text
            limits=$(get_current_resource_limits "$username" 2>/dev/null)
            cpu="${limits%%:*}"
            memory="${limits#*:}"
            if [[ -n "$cpu" || -n "$memory" ]]; then
                status_text="已配置"
            else
                status_text="未设置"
            fi
            printf "%-18s %-12s %-12s %s\n" "$username" "${cpu:--}" "${memory:--}" "$status_text"
        done
        echo ""

        echo "[操作日志 (最近 20 条)]"
        echo "----------------------------------------------"
        if [[ -f "$USER_CREATION_LOG" ]]; then
            printf "%-20s %-14s %-10s %-10s %-16s %-20s %s\n" \
                   "时间" "用户名" "操作" "类型" "挂载点" "主目录" "配额(GB)"
            echo "----------------------------------------------"
            tail -n +2 "$USER_CREATION_LOG" | tail -20 | while IFS=',' read -r timestamp username action user_type mountpoint home quota_gb; do
                printf "%-20s %-14s %-10s %-10s %-16s %-20s %s\n" \
                       "$timestamp" "$username" "$action" "$user_type" "$mountpoint" "$home" "$quota_gb"
            done
        else
            echo "无日志记录"
        fi
        echo ""

        echo "=============================================="
        echo "  报告结束"
        echo "=============================================="
    } > "$output_file"

    msg_ok "完整报告已导出: ${C_BOLD}${output_file}${C_RESET}"
}

# 导出用户 CSV
export_users_csv() {
    local output_file="${1:-$REPORT_DIR/users_$(date '+%Y%m%d_%H%M%S').csv}"
    mkdir -p "$(dirname "$output_file")"

    msg_info "正在导出用户 CSV..."

    local managed_users=()
    mapfile -t managed_users < <(get_managed_usernames 2>/dev/null)

    {
        echo "username,home,mountpoint,used_bytes,limit_bytes,usage_pct,cpu_quota,memory_limit"

        for username in "${managed_users[@]}"; do
            local home mp quota_info used_bytes limit_bytes pct
            home=$(get_user_home "$username" 2>/dev/null)
            mp=$(get_user_mountpoint "$home" 2>/dev/null)

            used_bytes=0
            limit_bytes=0
            pct=0

            if [[ -n "$mp" ]]; then
                quota_info=$(get_user_quota_info "$username" "$mp" 2>/dev/null)
                used_bytes="${quota_info%%:*}"
                limit_bytes="${quota_info#*:}"
                [[ "$used_bytes" =~ ^[0-9]+$ ]]  || used_bytes=0
                [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
                (( limit_bytes > 0 )) && pct=$((used_bytes * 100 / limit_bytes))
            fi

            local limits cpu memory
            limits=$(get_current_resource_limits "$username" 2>/dev/null)
            cpu="${limits%%:*}"
            memory="${limits#*:}"

            printf '%s,%s,%s,%s,%s,%d,%s,%s\n' \
                   "$username" "$home" "${mp:--}" "$used_bytes" "$limit_bytes" "$pct" "${cpu:--}" "${memory:--}"
        done
    } > "$output_file"

    msg_ok "CSV 已导出: ${C_BOLD}${output_file}${C_RESET} (${#managed_users[@]} 个用户)"
}
