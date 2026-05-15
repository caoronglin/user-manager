#!/bin/bash
# backup_excludes.sh - 统一备份排除模式管理模块 v1.0.0
# 提供所有备份排除模式的单一数据源，消除代码重复
# 所有备份函数（手动/定时/批量/并行）均引用此模块
#
# 使用方式:
#   source "$LIB_DIR/backup_excludes.sh"
#   然后调用:
#     get_base_exclude_patterns     - 获取基础系统排除
#     get_bio_exclude_patterns      - 获取生物信息排除
#     get_all_exclude_patterns      - 获取全部排除
#     build_rsync_exclude_args arr  - 构建 rsync --exclude 参数数组
#     generate_exclude_file [path]  - 生成排除临时文件用于 --exclude-from

set -uo pipefail

# ============================================================
# 1. get_base_exclude_patterns - 基础系统排除模式
# ============================================================
# 输出：每行一个排除模式
# 涵盖：缓存、临时文件、版本控制无关文件等通用排除项
# ============================================================
get_base_exclude_patterns() {
    cat << 'EOF'
.cache
.local/share/Trash
*.tmp
__pycache__
.git/objects
.git/logs
EOF
}

# ============================================================
# 2. get_bio_exclude_patterns - 生物信息学文件排除模式
# ============================================================
# 输出：每行一个排除模式
# 涵盖：BAM/CRAM/FASTQ/VCF/BED/GFF/索引/中间产物等大文件
# ============================================================
get_bio_exclude_patterns() {
    command -v cat &>/dev/null || { msg_err "cat 命令不可用"; return 1; }
    cat << 'EOF'
*.bam
*.bam.bai
*.cram
*.cram.crai
*.fastq
*.fastq.gz
*.fq
*.fq.gz
*.sai
*.sam
*.sam.gz
*.bcf
*.vcf
*.vcf.gz
*.vcf.bgz
*.tbi
*.csi
*.bed
*.gff
*.gff3
*.gtf
*.txt.gz
*.pileup
*.mpileup
*.wig
*.bedgraph
*.bw
*.bigwig
*.hic
*.cool
*.mcool
*.bai
*.crai
*.idx
*.sra
*.sra.lite
*.ubam
*.unmapped.bam
*.sorted.bam
*.dedup.bam
*.recall.bam
*.realigned.bam
*.trimmed.fastq.gz
*.trimmed.fq.gz
*.paired.fq.gz
*.unpaired.fq.gz
*.R1.fastq.gz
*.R2.fastq.gz
*.fasta.fai
*.dict
*.amb
*.ann
*.bwt
*.pac
*.sa
*.bt2
*.bt2l
*.hisat2
*.ht2
*.ht2l
*.stidx
*.stcoords
.samtoolscache
.gatk-cache
.picard-tmp
.bwa-cache
.snakemake
work/
tmp/
temp/
intermediate/
EOF
}

# ============================================================
# 3. get_all_exclude_patterns - 获取全部排除模式（合并）
# ============================================================
# 输出：基础排除 + 生物信息排除，去重
# ============================================================
get_all_exclude_patterns() {
    {
        get_base_exclude_patterns
        get_bio_exclude_patterns
    } | sort -u
}

# ============================================================
# 4. get_exclude_pattern_count - 获取排除模式总数
# ============================================================
get_exclude_pattern_count() {
    get_all_exclude_patterns | wc -l
}

# ============================================================
# 5. build_rsync_exclude_args - 构建 rsync --exclude 参数数组
# ============================================================
# 参数: $1 - 数组名称引用（nameref），结果追加到此数组
# 用法: local -a my_args=(); build_rsync_exclude_args my_args
#       rsync "${my_args[@]}" src/ dst/
# ============================================================
build_rsync_exclude_args() {
    local -n _excl_arr=$1    # nameref: 结果追加到此数组
    local pattern

    # 只使用基础排除构建 --exclude 参数（生物信息排除通过 --exclude-from 处理更高效）
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        _excl_arr+=( --exclude="$pattern" )
    done < <(get_base_exclude_patterns)

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        _excl_arr+=( --exclude="$pattern" )
    done < <(get_bio_exclude_patterns)
}

# ============================================================
# 6. generate_exclude_file - 生成排除文件（用于 --exclude-from）
# ============================================================
# 参数: $1 - 可选，输出文件路径。默认生成临时文件并打印路径
# 输出: 生成的排除文件路径（stdout）
# 注意: 调用者负责清理临时文件
# ============================================================
generate_exclude_file() {
    local output_file="${1:-}"
    local created_temp=false

    if [[ -z "$output_file" ]]; then
        output_file=$(mktemp) || { msg_err "无法创建排除临时文件"; return 1; }
        created_temp=true
    fi

    # 写入所有排除模式
    {
        echo "# Backup Exclude Patterns"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Total patterns: $(get_exclude_pattern_count)"
        echo "#"
        echo "# === Base Excludes ==="
        get_base_exclude_patterns
        echo ""
        echo "# === Bioinformatics Excludes ==="
        get_bio_exclude_patterns
    } > "$output_file"

    if [[ ! -s "$output_file" ]]; then
        msg_err "排除文件生成失败或为空: $output_file"
        [[ "$created_temp" == "true" ]] && rm -f "$output_file"
        return 1
    fi

    echo "$output_file"
    return 0
}

# ============================================================
# 7. get_exclude_preview - 获取排除模式预览（供UI显示）
# ============================================================
# 参数: $1 - 预览行数（默认8）
# 输出: 前N行排除模式 + 总数
# ============================================================
get_exclude_preview() {
    local preview_lines="${1:-8}"
    local total base_count bio_count

    base_count=$(get_base_exclude_patterns | wc -l)
    bio_count=$(get_bio_exclude_patterns | wc -l)
    total=$((base_count + bio_count))

    echo "排除模式预览 (基础: $base_count 项, 生物信息: $bio_count 项, 共 $total 项):"
    echo ""
    get_base_exclude_patterns | head -n "$preview_lines" | sed 's/^/    /'
    echo "    ... (更多生物信息排除模式)"
}

# ============================================================
# 8. _cleanup_exclude_temp_files - 清理排除临时文件
# ============================================================
# 由调用者在 trap 中注册
# 参数: 全局变量 BACKUP_EXCLUDE_TEMP_FILES（数组）
# ============================================================
_cleanup_exclude_temp_files() {
    local f
    for f in "${BACKUP_EXCLUDE_TEMP_FILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
    BACKUP_EXCLUDE_TEMP_FILES=()
}

# ============================================================
# 9. register_exclude_temp_file - 注册待清理的临时文件
# ============================================================
register_exclude_temp_file() {
    local file="$1"
    [[ -z "$file" ]] && return 1
    BACKUP_EXCLUDE_TEMP_FILES+=("$file")
}

# ============================================================
# 10. print_exclude_summary - 打印排除策略摘要
# ============================================================
print_exclude_summary() {
    local base_count bio_count total
    base_count=$(get_base_exclude_patterns | wc -l)
    bio_count=$(get_bio_exclude_patterns | wc -l)
    total=$((base_count + bio_count))

    msg_info "排除策略: 基础 $base_count 项 + 生物信息 $bio_count 项 = 共 $total 项"
}
