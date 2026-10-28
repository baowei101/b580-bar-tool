# b580-bar-tool.sh 独立评审报告

- 评审对象：`D:\2\b580-bar-tool\b580-bar-tool.sh`（v1.1.0，690 行）
- 评审依据：PCI-SIG Resizable BAR ECN（ECAP ID 0x0015）、Linux PCI 子系统行为、脚本全文逐行核对
- 标注约定：【确认】= 有明确代码依据的缺陷；【可疑】= 依赖运行时条件，无法仅凭代码确证

---

## 一、独立评审

### 1.1 寄存器读写与位操作

**1.1.1 【确认】setpci 读失败被静默归零，可导致 apply「假幂等成功」**
- `hex2dec()` L78：`[ -n "$v" ] || { echo 0; return; }` —— 空输入（setpci 失败/设备消失）一律返回 0。
- `cap_read/ctl_read/sta_read`（L175-177）均 `2>/dev/null`，失败无任何上报。
- 推演（apply 路径，L494-502）：若 gather 之后、读取之前设备暂时不可访问，`ctl="" → cur_n=0`，`cap="" → max_n=0`，`target_n=0`。L500 `[ 0 -le 0 ]` 通过，L501 `[ 0 -ge 0 ]` 通过；到 L530 `[ "$cur_n" -ge "$target_n" ]` → `[ 0 -ge 0 ]` 成立 → 输出「BAR2 已是目标尺寸（N=0），幂等退出」并 `return 0`。**读寄存器彻底失败却报成功退出码 0。**
- 同理 plan 模式会打印「目标 N=0 = 1MB」的荒谬计划而不报错。
- 修复建议：apply/plan 路径对 `max_n` 做下限校验（如 `max_n >= 10`，B580 实测 14），对 `ctl` 做非空且含 BAR 索引校验；`cap_read/ctl_read` 失败时直接 die。

**1.1.2 【确认】ECAP 偏移算术依赖 bash 对 `0x` 前缀的隐式解析，可用但脆弱**
- `ECAP_OFF` 由 `ecap_find`（L123/126）echo 出来：hint 路径是 `0x420`（L123），fallback 路径是十进制（L125）。
- `cap_read` 等 L175-177 用 `$((ECAP_OFF + REG_CAP))`：bash 算术能同时消化 `0x420` 和 `1056`，结果正确；但两种进制混杂（L31 注释、L125 注释各自成体系）使审计困难。非缺陷，标注为可维护性问题。

**1.1.3 【确认·无缺陷】位域处理核对通过**
- `ctl_size_n` L183 `(v & 0x3F00) >> 8`：对实测 Control=0x00000922 得 9（512MB），与背景事实一致。
- `max_supported_n` L187-194：对 Capability=0x0007f000，bit(4+N)，N=8..14 → max=14（16GB），正确。
- `ctl_write` L180 `.l=00000xxx` 写 32 位，`do_resize` L323 `(~SIZE_MASK) | ((target_n<<8) & SIZE_MASK)` 保留 bits[2:0] BAR 索引与其它位，正确。
- L336 写后回读全量比对，正确（本卡 Control 其余位应为 0，全量比较安全）。
- setpci 宽度一律 `.l`（L116/175-181），注释 L173 明确无 `.d`，正确。

**1.1.4 【确认】`--size` 不校验目标 N 是否在 Capability 支持位图中**
- L104 `--size` 只透传；L500 仅校验 `<= max_n`、L501 仅校验 `>= cur_n`，从不检查 Capability `bit(4+N)` 是否置位。若传入一个卡不支持的中间值（本卡支持 8..14，传 10 合法，但换卡后可能传入空洞值），写入后硬件行为未定义（忽略或异常）。
- 修复：加一行 `( (cap >> (4 + target_n)) & 1 )` 检查。

**1.1.5 【可疑】`max_supported_n` 只扫 bit 4..28（L190）**
- 规范位域到 bit 31（N=27）。对本卡（bit 18 封顶）无影响；换成理论支持 >16TB 的设备会低估上限。当前场景无害。

### 1.2 前置检查

**1.2.1 【确认】fuser 缺失时 preflight 给出假绿灯**
- L252-261：`command -v fuser` 失败时 `holders=""`，走 else 分支 L260 打印 INFO「未检测到进程占用 GPU 设备节点」——实际是**根本没检测**，措辞是确定性结论。`cmd_check` L470-472 虽另行提示「没有 fuser」，但 apply 路径只跑 `preflight`（L534），不跑 cmd_check，所以 **apply 时这条误导性 INFO 是唯一输出**。
- 修复：preflight 内区分「fuser 缺失」（WARN/拒绝）与「确实无占用」（INFO）。

**1.2.2 【确认】fuser 检测本身覆盖不全**
- fuser 只看 `/dev/dri/*` 是否被打开（L253）。绑定到 vfio-pci、或由其他进程通过 `/dev/mem`/`/proc/bus/pci` 直接访问的 DMA 不在此列；X99 headless + xe 场景下大概率够用，标注为已知局限。

**1.2.3 【确认·无缺陷】子树白名单逻辑正确**
- L240-247：`0x0604*`（桥）、`0x0403*`（HDMI 音频）放行；GPU 自身 class 0x0300 落入 `*` 但被 `d != GPU_BDF` 条件豁免；`cls` 为空（设备中途消失）走 `*` → 报错 → rc=1，fail-safe 方向正确。
- L157-170 `dev_class` 优先 sysfs，注释明确警告过 lspci 字段陷阱，正确。

**1.2.4 【确认】缺少「根端口窗口 ≥ 目标 BAR 大小」的前置核对**
- preflight L235 打印窗口大小但只作展示；目标 16GB 是否放得下完全依赖 `pci=realloc` 的重分配逻辑。L225-231 已强制要求 pci=realloc（背景确认已存在），风险可接受，但至少应在 plan 中对「窗口 < 目标」给出 WARN。当前 L512 同样只打印不判断。

**1.2.5 【确认】`cmd_check` 的自述与实现不符**
- L460-461 注释称「把 apply 会验的每一项单独跑一遍」，但 check 并不读 ReBAR 寄存器、不验证 max_n 合理性（对应 1.1.1 的盲区）。文档性失真。

### 1.3 解绑 / 移除根端口 / rescan / 重绑

**1.3.1 【确认·无缺陷】顺序正确**
- do_resize L319-378：unbind → write ctl → 校验 → remove root → rescan → 验证 BAR2 → rebind。与 Resizable BAR 软件流程（改 size 后必须重新枚举才重分配）一致；rehearse 实测 4 秒零挂死佐证顺序可行。
- `unbind_leaf_drivers` L278-288 只解绑终端设备、pcieport 留给 remove 级联，符合内核行为（remove port 时内核级联移除下游）。

**1.3.2 【确认】unbind 失败被降级为 WARN，随后仍继续 remove**
- L273-274：`echo unbind 失败（可能 EBUSY）` 只打 WARN。若 xe 因 DMA 在途解绑失败，L346 仍会 remove 根端口，此时设备带活动 DMA 被拔出，是除内核枚举挂死外另一类可致挂死/数据损坏的路径。preflight 的 fuser 检查只能挡「用户态进程持有设备节点」，挡不住 EBUSY 的其它成因。
- 修复建议：unbind 失败（尤其 GPU 本体）应 `return 1` 中止，而不是 WARN 后继续。

**1.3.3 【确认】rebind 用「模块名」当「驱动名」**
- L296：从 `lspci -k` 的 `Kernel modules:` 行取值写入 `/sys/bus/pci/drivers/$drv/bind`。`Kernel modules` 列的是模块名（如 `snd_hda_intel`），多数情况与驱动名一致，但存在模块≠驱动的设备时 bind 会失败（仅 WARN，L300）。更稳的做法是查 `/sys/bus/pci/devices/$d/driver_override` 或先用 `modprobe` 确保模块加载后按 modalias 匹配。本机 xe/snd_hda_intel 恰好同名，实际影响低。

**1.3.4 【可疑】rescan_wait 重试上限 3 次、每次间隔 1s（L306-316）**
- 对 rescan 的 sysfs 写在内核中近似同步完成，正常情况下 echo 返回时设备已枚举完，重试逻辑大概率永不触发（rehearse 也证实）。但开关级联枚举慢的机器上 3 秒可能不够，且 L315 无条件 `sleep 1`、循环耗尽后无日志提示「已放弃重试」。整体影响：验证阶段会正确报 rc=2 并回滚，属健壮性小瑕疵。

**1.3.5 【确认·无缺陷】`subtree_devices` 不含根端口自身**
- L149-155 用 realpath 前缀匹配，根端口不属于自己的子树路径，桥设备（02:00.0、03:01.0/03:02.0）会被包含，与 remove 的级联范围一致。

### 1.4 回滚路径

**1.4.1 【确认·最严重类】rollback_to 在「GPU 不可见」分支跳过写回，却仍可能宣布回滚成功**
- L387-393：GPU 不存在时只打 ERROR「无法写回寄存器」，**Control 仍保持 16GB 值**（rc=2 GPU 缺失场景中 write-ctl 已成功，见 L334-341）。
- L395-406：随后照样 remove + rescan；若设备此时回来且内核按其（未恢复的）配置空间分到 16GB BAR2，L402 仅判 `bar2_mb > 0` → 输出「回滚完成，BAR2 = 16384MB」并 `return 0`。**回滚假成功，实际窗口仍是 16GB。**
- 修复：L402 必须校验 `bar2_mb == 原始尺寸`，且 GPU 不可见分支在 rescan 后应回读 Control 确认恢复，否则 return 1。

**1.4.2 【确认】rollback 成功判据只有 bar2_mb > 0，不校验恢复到的尺寸**
- 即使走的是「GPU 可见」分支、写回成功，L402 也不比对 `bar2_mb` 与 `bar2_mb_of_n(ctl_size_n(orig_ctl))`；`ctl_write` 失败（L389 仅 ERROR）后仍继续 remove/rescan 并可能报成功。do_resize 有回读校验（L335-339），rollback_to 没有——同一脚本内两套标准。

**1.4.3 【确认】rc=1（写失败类）路径的回滚会引入一次不必要的 remove/rescan**
- do_resize 返回 1 的三个点：L334（写失败）、L336-339（写校验失败）时**根端口尚未移除**；L347（remove 失败）时根端口状态未知。而 `rollback_to` L395-397 无条件再 remove 一次根端口并 rescan。前两个场景本可只写回寄存器 + 重绑驱动即可收场（写校验失败往往意味着硬件未接受新值，窗口未变）。这把「寄存器写失败」升级成了「再来一次根端口重新枚举」，把风险放大了一档。rehearse 已证明枚举可容忍，所以不算致命，但属设计缺陷。

**1.4.4 【确认】cmd_rollback 的兜底目标 N=8 与实际原值 N=9 不符**
- L664：`target_n="${TARGET_N:-8}"`。本卡原始 size 字段为 9（512MB）。当 STATE_FILE 不存在（如 apply 前手动 rollback、或 L548 写 state 失败）且未传 `--size` 时，回滚会把 BAR2 缩到 256MB。魔法数字 8 无任何注释解释，且 L501 明确禁止 apply 缩容、rollback 却默认缩容，逻辑不自洽。应默认取「当前值」或从 cfgdump/文档取 9。

**1.4.5 【确认】cmd_rollback 无幂等检查**
- L654-669：即使 `cur_n == target_n`（已在原尺寸），仍执行 rollback_to 的解绑 + remove 根端口 + rescan 全套破坏性动作。与 apply 的幂等退出（L530-533）不对等。

### 1.5 幂等性汇总

- `apply`：L530-533 有幂等退出 ✓（但受 1.1.1 假幂等缺陷污染）。
- `rehearse`：可重复执行 ✓（实测）。
- `rollback`：无幂等检查 ✗（1.4.5）。
- `check/status/plan`：纯只读 ✓。

### 1.6 `set -uo pipefail` 下的陷阱

**1.6.1 【确认】无 SIGINT/SIGTERM trap，Ctrl-C 可留下中间态**
- L28 只有 `set -uo pipefail`。若用户在 L341（写寄存器完成、sync 完）之后、L346 remove 之前按 Ctrl-C：Control 已改为 16GB、驱动已解绑、根端口未移除，脚本无任何清理。虽然重启即复原（脚本自己也这么声明），但「apply 过程中手滑中断」是很现实的操作路径。建议 `trap 'rollback_to "$SAVED_CTL"' INT TERM` 或至少 trap 后提示当前阶段。

**1.6.2 【确认·无缺陷】`&&`/`||` 优先级与命令替换失败处理抽查**
- L206 `(( e > s )) && echo … || echo 0`：echo 失败概率为零，或逻辑安全。
- L430 `ECAP_OFF="$(ecap_find …)" || die`：赋值与判活分开写，正确（写成 `local x=$(cmd) ||` 会吞返回值，此处没有犯这个错）。
- L556-557 `do_resize …` 与 `case $?` 之间无插入语句，`$?` 可靠。
- L474 `[ -e /dev/watchdog ] && wd=…`：短路与失败无 `-e` 连锁，安全。
- L253 glob 不匹配时 fuser 收到字面量、报错进 stderr，stdout 为空 → 走「无占用」分支（与 1.2.1 叠加）。

**1.6.3 【确认】`--gpu/--size/--log` 缺参数时死于 set -u 的裸报错**
- L103-105 `GPU_BDF="$2"`：`--gpu` 后无值 → `bash: $2: unbound variable` 退出。行为安全（不会继续执行），只是错误信息不友好，且退出码非脚本自己的 die 路径。小问题。

**1.6.4 【可疑】L296 管道 `sed | head -1` 在 pipefail 下的 SIGPIPE 竞态**
- 输出仅一行且小于管道缓冲区，sed 正常先退出，实际不会触发 141；理论竞态存在但概率可忽略。

**1.6.5 【确认】L348/354 等 `step` 与 `sync` 均 `|| true`，不会误杀主流程** ✓ 无问题。

### 1.7 其它核对（无缺陷项，供交叉验证）

- `bar2_mb` L197-207：`resource` 第 3 行 = BAR2（BAR0/1 为 64 位各占一行后 BAR2 正是第 3 行），未映射判 `0x0000000000000000` 正确。
- `detect_root_port` L143-147：regex 取 realpath 中 pci 段后第一个 BDF，即根端口；GPU 直连 root bus 时返回空 → L233 拦截，fail-safe。
- `ecap_find` fallback（L125-127）：对不存在偏移读到全 F，`& 0xFFFF = 0xFFFF ≠ 0x15`，无误报；代价是最坏 960 次 setpci 子进程，性能差但正确。
- 非 root 跑 plan：setpci 读 config space 允许，plan 无写动作，L529 need_root 在确认后才要求 root，合理。

---

## 二、冗余与僵尸代码

| # | 位置 | 类型 | 说明 |
|---|------|------|------|
| R1 | L686 `*) die` | 永不可达分支 | parse_args L97 已把 CMD 限定为六个已知值，空串默认为 plan，main 的 case 不可能有其它取值。防御性代码，非 bug 但属死分支 |
| R2 | L571 `local ctl="$1" ctl_before="$1"` | 冗余变量 | 两个变量始终同值；L601/603 可直接用 `ctl` |
| R3 | L323 / L502 / L667 | 重复逻辑 | 同一个 `(raw & ~SIZE_MASK) \| ((n << 8) & SIZE_MASK)` 表达式抄了三份，且 L502 算出的 `new_val` 仅用于展示、do_resize 内部 L323 又重算一遍。应抽成 `build_ctl(raw, n)` |
| R4 | L86-88 vs L90 | 重复逻辑 | `n_to_human` 与 `bar2_mb_of_n` 各自实现 `1 << (n+SIZE_EXP-20)`，前者可直接调后者 |
| R5 | L475 `wd="$(ls /dev/watchdog …)"` | 冗余 | 对单一固定路径用 ls 列目录毫无意义，L474 的 `[ -e ]` 已足够，`wd` 内容恒为 `/dev/watchdog` |
| R6 | L165-168 `dev_class` 的 lspci fallback | 实际不可达 | 设备存在于 sysfs 时 `class` 文件必可读；fallback 仅在竞态窗口（设备被移除的瞬间）有意义，且此时后续操作也必然失败。属半死代码 |
| R7 | L125-127 ecap 全区间扫描 | 条件性死代码 | 本机 hint 命中，永不执行。作为 fallback 保留合理，仅指出其 960 次子进程的性能代价 |
| R8 | L645-651 `local rc=$?; case $rc; …; return $rc` | 风格冗余 | `case $(do_rehearse "$ctl") in` 可直接表达，多出一个中间变量；非缺陷 |
| R9 | `--log`（L105）无配对的 `--step` 选项 | 选项不对称 | LOG_FILE 可改而 STEP_FILE 硬编码（L46），fallback_notice（L421）还引用它；一致性缺口，非缺陷 |

**无「定义但从未调用」的函数**：41 个函数全部有调用点；`sta_read/REG_STA` 仅 status 使用，属正常覆盖而非僵尸。**无可变参数未使用的选项**：`--gpu/--size/--log/--yes` 均有效（`--yes` 对只读命令传参无害）。

---

## 三、结论

### 最严重的 3 个问题（按风险排序）

1. **setpci 读失败静默归零 → apply 假幂等成功**（L78、L175-177、L500-533；见 1.1.1）。读寄存器是全脚本一切决策的输入源，输入为 0 时 `cur_n=0/max_n=0/target_n=0` 恰好让三道校验全部通过并返回退出码 0。这是唯一能让 apply「什么都没做却报成功」的路径。
2. **rollback_to 的 GPU 不可见分支跳过写回却可宣布回滚成功**（L387-406；见 1.4.1/1.4.2）。回滚是最后的防线，其成功判据 `bar2_mb > 0` 既不校验恢复尺寸，也不回读 Control，可能出现「回滚完成，BAR2 = 16384MB」的矛盾输出。叠加 1.4.4 的兜底 N=8（256MB≠原始 512MB），回滚子系统是全脚本最薄弱的环节。
3. **无信号 trap + unbind 失败仅 WARN 后继续 remove**（L273-274、L346、无 trap；见 1.3.2/1.6.1）。Ctrl-C 或 EBUSY 时，系统可能带着「已写 16GB Control + 驱动已解绑」的中间态走向 remove 根端口，把可控失败升级为最危险的执行路径。

### 能否安全执行 apply

**结论：可以执行，但有条件。**

支持执行的硬证据：
- 寄存器算术全部核对无误（1.1.3）：0x0007f000 → max N=14=16GB；0x00000922 → size 字段 9、BAR 索引 2，`new_val` 保留 bits[2:0]；写入用 `.l` 32 位并有回读校验（L335-339）。
- 最危险环节（remove 根端口 + rescan）已被 `rehearse` 实测通过：4 秒完成、零挂死、Control 不变、BAR2 保持 512MB —— 芯片组容忍度这一最大未知已被消除。
- `pci=realloc` 已在命令行（preflight L225 会强制验证）；子树白名单逻辑 fail-safe（1.2.3）；幂等与二次确认齐备。

执行前建议（均为小改，不修也可带风险执行）：
- 运行 `apply` 前先跑一次 `status`，人工确认 Control=0x00000922、Capability=0x0007f000、BAR2=512MB 均非零 —— 这一步直接封堵 1.1.1 的假幂等/全零盲区；
- 执行期间不要 Ctrl-C（无 trap，1.6.1）；
- 无人值守用 `apply --yes` 而非前台等待时离开；
- 若允许修改脚本，优先修三处：读失败 die（L78 调用方加校验）、rollback 判据比对原尺寸（L402）、unbind 失败中止（L274）。修完即可视为生产可用。
