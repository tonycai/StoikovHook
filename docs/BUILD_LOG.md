# StoikovHook Build Log
ETHGlobal Tokyo 2026 — 从 2026-09-25 21:00 JST 开赛

## [2026-09-25 21:03 JST] 从 v4-template 创建仓库

**目标**：以 `uniswapfoundation/v4-template` 为模板创建公开仓库并克隆到本地。

**结果**：
- 仓库：https://github.com/tonycai/StoikovHook（public，GitHub 创建时间 12:03:53 UTC）
- 命令：`gh repo create tonycai/StoikovHook --template uniswapfoundation/v4-template --public --clone`
- 模板初始提交：`dfbe4cf Initial commit`

**遇到的问题**：克隆下来的 `lib/forge-std`、`lib/hookmate`、`lib/uniswap-hooks` 都是空目录。
根因：`--clone` 只做普通 `git clone`，不带 `--recurse-submodules`，子模块没有检出。
解法：运行 `forge install`，它按 `.gitmodules` 递归检出子模块，版本以 `foundry.lock` 锁定的 rev 为准（见下一条）。

**下一步**：脚手架搭建（.gitignore、foundry.toml、目录与文档骨架）。

---

## [2026-09-25 21:06 JST] 脚手架搭建

**目标**：修正 .gitignore，固定编译参数（CREATE2 挖出的 Hook 地址依赖字节码），建立 specs/ 与文档骨架。

**结果**：
- `.gitignore` 覆盖 `.env*`、`cache/`、`broadcast/`、`out/`，已用 `git check-ignore -v` 验证
- `foundry.toml` 固定编译参数，`forge config` 确认生效值：`solc = "0.8.30"`、`auto_detect_solc = false`、`evm_version = "cancun"`、`optimizer = true`、`optimizer_runs = 7777`、`via_ir = false`、`bytecode_hash = "none"`
- 新建 `specs/`（`.gitkeep`）、`AI_USAGE.md`、`FEEDBACK.md`（仅标题和空章节）
- `README.md` 首行加 "Built at ETHGlobal Tokyo 2026"

**遇到的问题**：
1. 模板的 `.gitignore` 用 `!/broadcast` 白名单，只忽略 `/broadcast/*/31337/`、`/broadcast/*/5/`、`dry-run/`。
   根因：模板写于 Goerli 时期，只排除了本地链和 Goerli。Sepolia（11155111）和主网的广播记录会被提交进公开仓库。
   解法：改为直接忽略 `broadcast/`。
2. 模板 CI（`.github/workflows/test.yml`）设置了 `FOUNDRY_PROFILE: ci`，但 `foundry.toml` 里没有 `[profile.ci]`。
   根因：CI 的编译配置依赖环境变量；以后有人加一个 `[profile.ci]`，CI 产出的字节码就和本地不同。
   解法：删掉这个 env。
3. 注意：`FOUNDRY_*` 环境变量在运行时仍能覆盖 `foundry.toml`，配置文件本身挡不住。本机已确认没有设置任何 `FOUNDRY_*`/`DAPP_*` 变量。
4. 注意：`.env*` 也会忽略 `.env.example`；以后如需提交它，要加 `!.env.example`。

问题 1、2 属于 v4-template 的问题，之后整理进 FEEDBACK.md。

**下一步**：安装依赖，跑基线测试，提交首个 commit。

---

## [2026-09-25 21:06 JST] 依赖安装与基线测试通过

**目标**：安装依赖，确认模板自带测试在固定编译参数下全部通过，并完成首次提交。

**结果**：
- 工具链：forge 1.5.0-stable（`1c57854`），solc 0.8.30
- 依赖（由 `foundry.lock` 锁定）：forge-std v1.10.0（`8bbcf6e`）、uniswap-hooks v1.1.0（`e59fe72`）、hookmate（`33408fb`）
- `forge build`：编译 80 个文件，成功
- `forge test`（21:05）：**8 passed / 0 failed / 0 skipped**
  - `CounterTest`：`testCounterHooks` gas 183563，`testLiquidityHooks` gas 167640
  - `EasyPosmTest`：6 项全部通过（`test_mintLiquidity` gas 429042、`test_increaseLiquidity` gas 490783 等）
- 提交：`6aee28d chore: bootstrap from v4-template`（本地提交，尚未 push）

**遇到的问题**：`forge install` 用时约 67 秒。uniswap-hooks 下面嵌套了 v4-core、v4-periphery、openzeppelin-contracts、solmate、permit2 等多层子模块，这属于正常情况，不是故障。

**下一步**：编写设计规格 `specs/01-design.md`（动态费率模型），经 Tony 确认后再开始实现。

---

## [2026-09-25 21:17 JST] 建立开发日志机制

**目标**：创建 `docs/BUILD_LOG.md` 作为主日志，补记开赛以来已完成的工作。

**结果**：新建 `docs/BUILD_LOG.md`，补记 3 条（仓库创建、脚手架搭建、基线测试）。之后每完成一个任务就追加一条，时间用 JST，精确到分钟，不记录 RPC URL、私钥等敏感值。

**遇到的问题**：`git add docs/BUILD_LOG.md` 被拒绝，提示路径被忽略。
根因：v4-template 的 `.gitignore` 里有 `docs/`，本意是忽略 `forge doc` 的输出目录，却把 `docs/` 整个目录都挡掉了。
解法：从 `.gitignore` 删除 `docs/`，并用 `git check-ignore` 确认 `docs/BUILD_LOG.md` 已可追踪。
注意：之后如果要跑 `forge doc`，需把输出目录改到 `docs/` 以外，否则生成的文件会混进 `docs/`。这一条也属于模板问题，之后整理进 FEEDBACK.md。

**下一步**：完成 `specs/01-design.md`；然后写 `CLAUDE.md` 和 README 骨架。

---

## [2026-09-25 21:26 JST] 设计规格：动态费率模型

**目标**：写出 `specs/01-design.md`，面向 Uniswap Foundation 工程师，定下费率公式、链上状态、回调、安全约束和 MVP 范围。不写实现代码。

**结果**：
- `specs/01-design.md`（373 行）共 7 节：问题陈述、费率模型、链上状态、回调与权限、安全约束、范围（MVP 5 项、验收标准 A1–A10、Stretch S1–S6）、待评审问题
- 费率公式采用 GLFT（A–S 的 T→∞ 平稳解）结构：$f(s) = \mathrm{clamp}(f_0 + \sigma_h(\alpha + \beta s \hat q), f_{\min}, f_{\max})$，按方向分 $f_\uparrow$ / $f_\downarrow$
- 输入只有池子自身的 `slot0.tick` 和 `block.timestamp`，不用预言机
- 每个池子的状态打包进 1 个 slot（208 bit）；每个 timestamp 窗口只在第一笔 swap 时更新一次，后续 swap 读缓存
- 回调：`afterInitialize` + `beforeSwap`，Hook 地址 flags = `0x1080`；费率通过 `OVERRIDE_FEE_FLAG` 按笔覆盖
- 所有 v4 接口结论都附了 `file:line` 证据；数值例（费率表、波动冲击后回落时间、位宽上界）已用脚本复算

**遇到的问题**：
1. 动态费率池初始化后 `slot0.lpFee = 0`（`LPFeeLibrary.sol:51-54`）。如果 Hook 某次没有返回覆盖费率，swap 就是 0 手续费。
   解法：规格要求在 `afterInitialize` 里调用 `updateDynamicLPFee(key, f0)` 作为兜底（库注释 `LPFeeLibrary.sol:48` 也推荐这么做）。这一条记作 v4 接口使用注意，之后整理进 FEEDBACK.md。
2. 如果按每笔 swap 的即时状态算库存偏斜，在同一笔交易里先反向小额交易越过参考价，再做大额交易，就能拿到折扣费率。
   解法：费率按 timestamp 窗口快照，同一窗口内固定。跨区块的残余风险写进 §5.4，由 S1 覆盖。
3. EMA 参考价如果用整数 tick 存储，在 τ_R = 900 时，位移不到 901 tick 就一步都不会动（整数除法截断为 0）。
   解法：规格要求用 16 位小数定点存储。

**下一步**：Tony 评审规格（§7 有 5 个待定问题）；同时写 `CLAUDE.md` 和 README 骨架。

---

## [2026-09-25 21:30 JST] CLAUDE.md 与 README 骨架

**目标**：写 AI 协作规范 `CLAUDE.md`，以及面向评委的 README 骨架（12 节）。

**结果**：
- `CLAUDE.md`：项目背景、技术栈、硬性约束（编译参数固定、权限与 HookMiner flags 一致、keystore、不打印 RPC URL、禁止对真实网络用 `--resume`）、已知环境问题、工作方式
- `README.md` 全部重写，替换掉模板内容。12 节依次是：标题/定位、Problem、Solution、Architecture（2 张 Mermaid 图）、Core Features、How It Works、Tech Stack、Repository Guide（占位表）、Getting Started、Deployed Contracts（占位）、Demo（占位）、Built With AI
- 所有未实现项都标了 "🚧 In progress"，顶部加了 "Project status: design phase" 提示框
- Mermaid 两张图都用 mermaid-cli 11.17.0 本地渲染验证通过（组件图 flowchart、时序图 sequenceDiagram 共 12 步）

**遇到的问题**：组件图初版用 `flowchart LR`，把 PoolManager 画成 subgraph，从 subgraph 边框连出去的 `beforeSwap()` 标签被节点遮住一半。
根因：从 subgraph 边框连出的边，标签会被放在 subgraph 内侧。
解法：改成 `flowchart TB`，PoolManager 和 Pool 作为 "Uniswap v4 core" subgraph 里的普通节点，StoikovHook 和它的状态放进另一个 subgraph。重新渲染后所有标签完整可见。
另外，时序图消息里避开了 `;` 和 `|`（Mermaid 会把 `;` 当语句分隔符），写成 "fee + OVERRIDE_FEE_FLAG"。

**下一步**：在 CLAUDE.md 里补上"功能完成后的固定流程"。

---
