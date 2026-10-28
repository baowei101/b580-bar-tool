# 🔍 安全审计报告

> 审计方法：纯静态文本分析，全程未执行被审项目中的任何脚本或命令。
> 审计时间：2026-10-27 21:30｜审计对象性质：**运维工具项目**（非 skill），按 skill 投毒审查标准执行。

---

## 📊 执行摘要

- **审计对象**：`D:\2\b580-bar-tool`（49 个文件，约 190 KB；核心为 `b580-bar-tool.sh` 34 KB）
- **发现问题总数**：3 个
  - 🔴 Malicious（恶意）：**0** 个
  - ⚠️ Suspicious（可疑）：**3** 个
  - 📝 信息性提醒：**2** 个（非风险项，不计入风险总数）
- **安全评分**：**51 / 100**

**一句话结论**：没有后门、没有外送、没有供应链投毒。三个可疑项全部是**"这个工具本来就要干的高危事"**（改 PCI 配置、提权、改系统配置），不是隐藏意图。

---

## 🔴 Malicious（恶意）风险发现

✅ **未发现 Malicious 风险。**

逐条核对结论：

| 投毒特征 | 检查结果 |
|---|---|
| 远程下载 + 执行（`curl \| bash`） | ❌ 无 |
| 读取敏感文件后外送（`~/.ssh`、`.env`、云凭证） | ❌ 无 |
| 硬编码凭证 / 私钥 / API Key | ❌ 无 |
| 隐蔽持久化（crontab、authorized_keys、未知 systemd 服务） | ❌ 无（唯一的 systemd 单元是项目自身功能，见下） |
| 数据外送（`curl -d`、`nc`、POST 到第三方） | ❌ 无 |
| 破坏性删除（`rm -rf /`、`~/*`、系统路径） | ❌ 无 |
| 功能描述与实际行为不符 | ❌ 未见不符 |

---

## ⚠️ Suspicious（可疑）风险发现

### 1. systemd 单元在开机时**自动执行**写 PCI 配置的操作

- **位置**：`tools/b580-rebar.service:21-24`、`tools/b580-rebar-late.service:17-20`
- **代码片段**：
  ```ini
  ExecStart=/opt/b580-bar-tool/rebar-autofix.sh
  ExecStartPost=/opt/b580-bar-tool/rebar-autofix.sh --check
  ```
  最终落到 `b580-bar-tool.sh:285` 的 `setpci ... .l=$val`（写 ReBAR Control 寄存器）
  与 `b580-bar-tool.sh:474` 的 `echo 1 > /sys/bus/pci/devices/$ROOT_BDF/remove`（移除 PCIe 根端口）。

- **Step A→B→C 判定链**：
  - **A 是否自动执行**：✅ 是。开机由 systemd 拉起，无需人工确认。
  - **B 是否危险操作**：✅ 是。写 PCI 配置空间 + 移除根端口，已有实测记录内核会在此处 soft lockup 直至整机复位。
  - **C 是否含恶意意图**：❌ **否**。功能与项目描述完全一致（"开机恢复 BAR2，因为断电后 BIOS 会重置"），且具备多重保护：`BAR2 已是目标尺寸即幂等退出`、尺寸不符自动 `rollback_to`、`ExecStartPost` 逐张校验并在失败时 `wall` + journal 报警、BDF 动态枚举不写死。

- **按规则降级** → **Suspicious**（Step C 确认无恶意意图，不得以假设性风险维持 Malicious）。

- **残留风险（真实存在，非假设）**：这是一条**开机自动触发的高危写操作通道**。一旦 `/opt/b580-bar-tool/b580-bar-tool.sh` 被第三方篡改，每次开机都会以 root 身份执行任意内容。
- **修复建议**：
  1. 给脚本加校验和，unit 里 `ExecStartPre` 先比对 SHA256，不符则拒绝执行；
  2. `/opt/b580-bar-tool` 目录收紧为 `root:root 0755`（当前是运维账号所有）——
     **本项目决定不收紧，理由与补偿措施见下文「风险接受记录 RA-01」**；
  3. 首次启用时要求人工 `systemctl start` 确认，而非默认 enable。

---

### 2. `docker run --privileged --pid=host` + `nsenter -t 1` 提权到宿主机 root

- **位置**：`NEXT.md:36,47,57,105`、`docs/dual-gpu-checklist.md:12,17,63,101`
- **代码片段**：
  ```bash
  docker run --rm --privileged --pid=host -v /etc:/etc ... ubuntu:24.04 \
    nsenter -t 1 -m -u -i -n -p -- /opt/b580-bar-tool/b580-bar-tool.sh apply ...
  ```
- **Step A→B→C 判定链**：
  - **A 是否自动执行**：❌ 否。这些是**文档里的手册命令**，需人工复制执行。按规则"仅提供能力 → 最高 Suspicious"。
  - 补充事实：`--privileged` + `--pid=host` + `-v /etc:/etc` + `nsenter -t 1` 组合起来**等同于宿主机无密码 root**，且绕过了 sudo 审计日志。

- **按规则** → **Suspicious**（非自动执行）。

- **残留风险**：文档教会使用者建立一条无需密码、无审计痕迹的 root 通道。若这条命令被写进任何自动化脚本，即成为永久后门。
- **修复建议**：
  1. 有 sudo 可用时**优先 sudo**，不要用容器通道；
  2. 必须用容器通道时，挂载改只读：`-v /opt:/opt:ro`、`-v /etc:/etc:ro`（本仓库部分命令已用了 `:ro`，建议统一）；
  3. 不要把这条命令固化进任何 cron / systemd / CI。

---

### 3. `wd-enable.sh` 用 `sed -i` 直接改 `/etc/systemd/system.conf`

- **位置**：`tools/wd-enable.sh:18-25`
- **代码片段**：
  ```bash
  CONF=/etc/systemd/system.conf
  cp -a "$CONF" "$BAK"                       # 有备份
  sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=60s/' "$CONF"
  systemctl daemon-reexec
  ```
- **Step A→B→C 判定链**：
  - **A 是否自动执行**：❌ 否。手动运行，且开头有 `[ "$(id -u)" -eq 0 ] || exit 1` 拦截。
  - **B 是否危险操作**：✅ 是。修改系统级 systemd 主配置文件并 `daemon-reexec`。
  - **C 是否含恶意意图**：❌ 否。目的是启用硬件看门狗（iTCO_wdt），有带时间戳的 `cp -a` 备份，注释写明"可逆"。

- **按规则** → **Suspicious**（非自动执行）。

- **残留风险**：`sed -i` 直接改主配置，若中途断电可能留下半行；且 `daemon-reexec` 会重载全部单元。
- **修复建议**：改用 **drop-in** 方式，完全不碰原文件：
  ```bash
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nRuntimeWatchdogSec=60s\n' > /etc/systemd/system.conf.d/99-watchdog.conf
  systemctl daemon-reexec
  ```
  撤销时删掉该文件即可，比 `sed -i` 回滚更干净。

---

## 🔕 风险接受记录

> 本节记录**已识别但决定不修**的风险，与"待修复"区分开。审计报告只负责指出风险，
> 是否处置属于运维决策；写下决策理由，是为了让后续接手的人不必重新争论一遍。

### RA-01：`/opt` 目录属主为运维账号，开机 unit 以 root 执行其中脚本

| 项 | 内容 |
|---|---|
| 对应发现 | ⚠️ Suspicious #1 的残留风险 |
| 当前状态 | 目录 `drwxr-xr-x <USER>:<USER>`，脚本 `-rwxrwxr-x <USER>:<USER>` |
| 决策 | **接受，不收紧属主** |
| 决策时间 | 2026-10-27 |

**接受理由（按权重排序）**

1. **物理与网络隔离层级足够**：部署机位于**实验室隔离网段**（NAT 之后再下一层），
   无公网可达路径，未接入任何可被非受信终端访问的网络。
2. **单操作员专用机**：`<USER>` 是唯一具备交互登录权限的账号，不存在多人共用、
   权限边界模糊的情形。风险模型中的"攻击者"与"运维者"是同一个主体。
3. **收紧属主不改变实际能力，只增加摩擦**：该账号本身已具备等价 root 能力
   （本机既有提权通道见 Suspicious #2），把这个账号列为威胁来源等于承认整机已失守 ——
   属主收紧对此毫无帮助。
4. **收紧反而提高高危命令使用频次**：目录变为 `root:root` 后，每次更新脚本都必须走
   `docker --privileged + nsenter`。让日常操作被迫频繁使用最危险的那条命令，
   **净效果是风险上升而非下降**。

**补偿措施（已实施）**

| 措施 | 作用 |
|---|---|
| unit 的 `ExecStartPost` 尺寸自检 + `wall` + journal 报警 | 扩容异常不会静默，人一定看得见 |
| `rebar-batch.sh --check` / `rebar-autofix.sh --check` 只读核对 | 随时可验证实际 BAR2，不依赖脚本自述 |
| 全部脚本纳入 git，`origin` 裸库保留完整历史 | 每次脚本变更可追溯、可 diff、可回滚，篡改会留痕 |
| 脚本默认幂等（已是目标尺寸即退出） | 重复执行无副作用，降低误操作面 |

**触发重新评估的情形**（出现任意一条，RA-01 立即作废）

- 该主机接入可被非受信终端访问的网段，或新增端口映射 / 反向代理；
- 增加第二个具备交互登录权限的账号（尤其 sudo 组）；
- `/opt/b580-bar-tool` 改由自动化流程写入（CI、定时任务、配置管理工具）；
- 工具转为对外分发或开源。

**如日后决定收紧**（一条命令，随时可执行）：

```bash
chown -R root:root /opt/b580-bar-tool && chmod -R go-w /opt/b580-bar-tool
```

> 注：收紧后 root 仍可读写执行，功能不受影响；仅更新方式需改走特权容器。

---

## 📝 信息性提醒（非风险项）

### 1. 内网信息暴露（**已在本轮脱敏**）

- **位置**：`README.md`、`NEXT.md`、`docs/*.md` 共 16 处
- **原内容**：真实内网 IP、登录账号、另一台评审机地址、`runuser -u <账号>` + `uid 1000` 硬编码
- **说明**：不属于投毒风险，但对外分享时会泄露内网拓扑与账号体系。
- **已处理**：
  | 原值类型 | 替换为 |
  |---|---|
  | 目标机内网 IP | `<SERVER_IP>` |
  | 登录账号 | `<USER>` |
  | 评审机 IP | `<REVIEW_HOST>` |
  | 脚本内 `runuser -u <账号>` / `uid 1000` | 运行时推断 `GPU_USER="${GPU_USER:-${SUDO_USER:-}}"` + `id -u` |

### 2. GitHub 账号名 `baowei101`

- **位置**：仓库内已无（相关的 PR #268 记录文档已移出本项目）
- **说明**：这是上游公开 PR #268 的作者署名，属于**公开可查信息**，不是凭证。

---

## 📋 详细检查结果

### 命令执行与权限检查

| 项 | 次数 | 说明 |
|---|---|---|
| `id -u` root 自检 | 3 | `b580-bar-tool.sh:85`、`archive/baseline.sh:64`、`wd-enable.sh:10` —— 全部是**拒绝非 root** 的拦截，非提权 |
| `setpci` 写 | 2 | 核心功能（写 ReBAR Control），已列 Suspicious #1/#2 |
| sysfs 写入（`remove`/`rescan`/`unbind`/`bind`） | 10 | 核心功能，内核公开 ABI |
| `nsenter` / `--privileged` | 8 | 全部在文档中，需人工执行（Suspicious #2） |
| `eval` / `exec(` / `shell_exec` | 0 | 无 |
| `subprocess` / `os.system` / `Popen` | 0 | 无 |

**结论**：无"隐蔽执行"（无 `base64 -d | bash`、无 `--silent` 掩盖危险操作）。

### 文件操作与敏感路径检查

| 路径 / 操作 | 位置 | 判定 |
|---|---|---|
| `/etc/systemd/system.conf` 写 | `tools/wd-enable.sh` | ⚠️ Suspicious #3（有备份） |
| `~/.ssh` `~/.aws` `.env` `credentials` | — | ❌ 未出现 |
| `/etc/passwd` `/etc/shadow` | — | ❌ 未出现 |

### 网络请求检查

发现的全部 URL：

| URL | 用途 | 判定 |
|---|---|---|
| `http://127.0.0.1:{PORT}/health` | 扩容后验证推理服务端口存活（`tools/start-gpu-root.sh`） | ✅ 回环地址 |

- **Base64 编码检测**：未发现可疑长串编码。
- **无 `curl | bash`、无 `wget | sh`、无下载后 `eval`。**

### 远程脚本深度分析

**不适用** —— 本项目不存在"自动下载并执行远程脚本"的行为，故无需抓取远程内容分析。

### 依赖安装风险检查

| 项 | 结果 |
|---|---|
| 全局 `pip install` / `npm install -g` | ❌ 未发现 |
| 非官方源（`--index-url` / `--registry`） | ❌ 未发现 |
| 从仓库安装且未固定 SHA | ❌ 未发现 |

依赖全部为**系统包**（`lspci`/`setpci` 来自 pciutils、`llama.cpp` 由本机源码编译），无运行期拉包行为。

---

## 💡 总体建议

1. **目录属主**：`/opt/b580-bar-tool` 为运维账号所有，而开机 unit 以 root 执行其中的脚本 ——
   技术上确实是"拿到该账号即可实现 root 持久注入"。**本项目已将其列为已接受风险
   （见「风险接受记录 RA-01」），前提是隔离网段 + 单操作员专用机 + 全量 git 留痕。**
   一旦脱离这三个前提，须立即执行
   `chown -R root:root /opt/b580-bar-tool && chmod -R go-w /opt/b580-bar-tool`。
2. **给自愈脚本加完整性校验**：unit 里 `ExecStartPre` 比对 SHA256，防止脚本被替换后开机自动执行。
3. **提权通道统一**：能用 sudo 就不用 `docker --privileged + nsenter`；必须用时挂载一律加 `:ro`。
4. **`wd-enable.sh` 改 drop-in**，不碰 `/etc/systemd/system.conf` 主文件。
5. **脱敏已基本完成**，剩余 GitHub 账号名可按需处理。

---

## ✅ 审计结论

**风险等级**：⚠️ **Suspicious（可疑）— 建议改进后使用**

**评分构成**：无 Malicious（基础 75 分）− 3 个 Suspicious × 8 = **51 分**

**使用建议**：

- ✅ 作为**本机自用运维工具**：可放心使用。三个可疑项都是项目声明功能所必需，且有回滚、幂等、备份等实质性保护，无任何隐藏行为。
- ⚠️ 作为**对外分享/开源项目**：先落实第 2 条（完整性校验）。第 1 条（目录属主）当前
  按 RA-01 接受，但那三个前提（隔离网段 / 单操作员 / git 留痕）在分享场景下**全部不成立**，
  必须补齐属主收紧。
- 🚫 作为**第三方 sudo 权限授予对象**：不建议直接放行，先完成第 1、2 条改造。
