# CLAUDE.md — StoikovHook AI 协作规范

本文件写给之后每一轮的 Claude Code 看。开始工作前先读完。

## 项目背景

StoikovHook 是一个 Uniswap v4 Hook，用 Avellaneda-Stoikov 做市模型驱动动态手续费。
ETHGlobal Tokyo 2026 参赛作品，Start From Scratch 赛道，目标赛道 Uniswap Foundation Best Uniswap Stack Contribution。
截止时间 2026-09-27 09:00 JST。

设计规格见 `specs/01-design.md`。实现必须以规格为准，规格经 Tony 确认后才能开始实现。

## 技术栈

Solidity（版本以 `foundry.toml` 为准）、Foundry、Uniswap v4-core / v4-periphery、
hookmate（地址常量）、本地 anvil fork Sepolia。

## 硬性约束

- 编译参数固定在 `foundry.toml`，不得依赖环境变量。
  CREATE2 挖出的 Hook 地址由字节码决定，编译参数一变，地址就失效。
- `getHookPermissions()` 声明的权限必须与 HookMiner 使用的 flags 严格一致。
  改动其中一个，必须同步另一个并重新挖地址。
- 脚本中禁止使用 `address(this)`，forge 广播时会拒绝；用 deployer 地址变量。
- 私钥只能通过 keystore（`--account`）使用，禁止写进命令行、`.env` 或任何文件。
- 禁止打印 RPC URL 的实际值。
- 禁止对真实网络使用 `--resume` 重放 broadcast 记录。
- 仓库是公开的。提交前确认 `.gitignore` 覆盖 `.env*`、`cache/`、`broadcast/`、`out/`。

## 已知环境问题与解法

- HookMiner 挖地址时 gas 不足：部署脚本加
  `--gas-limit 100000000000 --disable-block-gas-limit`
- anvil 闲置导致时间戳落后，swap 报 `DeadlinePassed`：
  anvil 启动时加 `--block-time 1`
- CREATE2 候选地址被占：调整 `optimizer_runs` 改变字节码

## 工作方式

- 每个可工作的中间态立即 commit，禁止攒大提交（评委会审查 git 历史）
- 涉及费率计算、状态机、资金安全的改动，先输出 diff 供 Tony 确认，再合并
- 每个任务完成后，追加记录到 `docs/BUILD_LOG.md`
- 开发中遇到的 Uniswap 工具链问题，同步记一条到 `FEEDBACK.md`
  （这是 Uniswap 赛道的硬性参赛要求）
- 任何结论都要给出 `file:line` 证据，不做无依据的断言

### 功能完成后的固定流程

每当一项功能达到可工作状态（测试通过），按顺序执行以下四步，不要跳过：

1. **更新 README.md**
   - 「Core Features」：把新功能改为已完成状态，去掉 🚧 标记
   - 「Repository Guide」：补上该功能对应的合约文件路径和关键代码行号，
     格式为 `src/StoikovHook.sol:L120-L145 — 费率计算主逻辑`。
     这是 Uniswap 赛道的硬性要求，评委据此验证集成
   - 如涉及架构变化，同步更新 Mermaid 图
   - 只写已实现的内容，未完成的保持 🚧 标记

2. **追加记录到 `docs/BUILD_LOG.md`**
   按既有格式写明目标、结果、遇到的问题、下一步。
   关键数值（测试通过数、gas 消耗、合约地址）必须记录

3. **如果过程中遇到 Uniswap 工具链、文档或 v4 接口的问题**，
   同步记一条到 `FEEDBACK.md`

4. **提交并推送到 main**
   ```bash
   git add -A
   git commit -m "<type>: <简明描述>"
   git push origin main
   ```
   提交信息用 Conventional Commits 格式：`feat` / `fix` / `test` / `docs` / `chore` / `refactor`

### 分支策略

单人维护，直接提交 main，不开 PR，不建功能分支。

### 提交纪律

- 一个功能一次提交，禁止把多个功能攒在一起提交
- 提交前确认 `git status` 中没有 `.env` 开头的文件、`cache/`、`broadcast/` 目录
- 评委会审查 git 历史，单次巨量提交会被质疑
