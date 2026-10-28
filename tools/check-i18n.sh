#!/bin/bash
# =============================================================================
# check-i18n.sh —— 双语文档一致性检查（只读）
#
# 前提：中文是主语言（原文），英文是译文。所以"英文侧少了章节"一律按漏译处理，判失败；
#       "英文侧多了导航性章节"只是提示。反方向（中文多了、英文没跟上）同样要修 —— 补译文。
#
# 为什么只比结构不比内容：
#   中英文无法逐行对齐（英文普遍更长），diff 全文必然满屏噪声。
#   但"翻译时漏了一整节"这种错误会直接反映在标题数量上，一比就露。
#   代码块数量同理：漏掉一段命令示例是很常见的翻译事故。
#
# 检查项（每个 <name>.zh-CN.md 与 <name>.md 成对比较）：
#   1. 英文版是否存在
#   2. 二级标题数量（## ）
#   3. 三级标题数量（### ）
#   4. 代码块围栏数量（``` ，且必须为偶数）
#   5. 英文版是否残留中文（语言切换行除外）
#
# 不做的事：不判断译得对不对、不要求逐段对应、不检查行数。
#   英文版允许多出导航性章节（如 "Documentation written in Chinese"）。
#
# 用法：./tools/check-i18n.sh          # 退出码 0 = 全部一致
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RED=''; GRN=''; YEL=''; RST=''
if [ -t 1 ]; then RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'; fi

# grep -c 无匹配时会输出 0 但返回 1，所以不能用 `|| echo 0`（会得到 "0\n0"）
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }

pairs=0; bad=0
printf '%-34s %-11s %-11s %-12s %s\n' '文件对' '二级标题' '三级标题' '代码块围栏' '结论'
printf '%s\n' '--------------------------------------------------------------------------------'

# 用 find 而非 git ls-files：新增但尚未 git add 的译文也要能检查
while IFS= read -r zh; do
    zh="${zh#./}"
    en="${zh%.zh-CN.md}.md"
    pairs=$((pairs + 1))

    if [ ! -f "$en" ]; then
        printf '%-34s %s\n' "$en" "${RED}缺失英文版${RST}"
        bad=$((bad + 1)); continue
    fi

    h2e=$(count '^## ' "$en");   h2z=$(count '^## ' "$zh")
    h3e=$(count '^### ' "$en");  h3z=$(count '^### ' "$zh")
    cbe=$(count '^```' "$en");   cbz=$(count '^```' "$zh")

    msgs=(); notes=()
    # 英文侧标题少于中文侧 = 漏译（失败）；多于中文侧 = 英文多出导航性章节（提示，不失败）
    [ "$h2e" -lt "$h2z" ] && msgs+=("二级标题少 $((h2z - h2e)) 个，可能漏译")
    [ "$h3e" -lt "$h3z" ] && msgs+=("三级标题少 $((h3z - h3e)) 个，可能漏译")
    [ "$h3e" -gt "$h3z" ] && notes+=("英文版多 $((h3e - h3z)) 个三级标题（导航性章节）")
    [ "$cbe" -ne "$cbz" ] && msgs+=("代码块围栏 $cbe vs $cbz")
    [ $((cbe % 2)) -ne 0 ] && msgs+=("英文版代码块围栏为奇数，可能未闭合")

    # 英文版中文残留（排除语言切换行里的「简体中文」）
    zh_residue=$(grep -n '[一-龥]' "$en" 2>/dev/null | grep -v '简体中文' | wc -l)
    [ "$zh_residue" -gt 0 ] && msgs+=("残留中文 $zh_residue 行")

    if [ ${#msgs[@]} -eq 0 ]; then
        printf '%-34s %-11s %-11s %-12s %s\n' \
            "$en" "$h2e/$h2z" "$h3e/$h3z" "$cbe/$cbz" "${GRN}OK${RST}"
        for n in "${notes[@]}"; do printf '    · %s\n' "$n"; done
    else
        printf '%-34s %-11s %-11s %-12s %s\n' \
            "$en" "$h2e/$h2z" "$h3e/$h3z" "$cbe/$cbz" "${YEL}见下${RST}"
        for m in "${msgs[@]}"; do printf '    - %s\n' "$m"; done
        bad=$((bad + 1))
    fi
done < <(find . -name '*.zh-CN.md' -not -path './.git/*' | sort)

printf '%s\n' '--------------------------------------------------------------------------------'
if [ "$pairs" -eq 0 ]; then
    echo "没有找到任何 .zh-CN.md 文件 —— 检查是否在仓库根目录运行"
    exit 2
fi

if [ "$bad" -eq 0 ]; then
    echo "${GRN}结论：${pairs} 对文件，结构全部一致${RST}"
    echo
    echo "注：只比结构，不比译文。中文是主语言，英文是译文。"
    echo "    英文侧标题多于中文侧 = 多了只对英文读者有意义的导航性章节（如 \"Chinese-only pages\"），"
    echo "    不算错误；中文侧标题多于英文侧 = 中文新增了内容而译文没跟上，补英文侧，别回头改中文。"
    exit 0
else
    echo "${RED}结论：${pairs} 对文件中 ${bad} 对存在结构差异${RST}"
    exit 1
fi
