# OpenClaw Deploy Ninja 🥷🦞

**OpenClaw 最强“零依赖”、抗崩溃自动化部署技能。**

这是一个专为 AI 编程助手（如 opencode, Claude Code, Codex 等）设计的核心技能（Skill）。只要把这个技能交给你的 AI，它就能像一个资深运维专家一样，为你完美、无痕地在 macOS 或 Linux 上部署和配置 [OpenClaw](https://openclaw.ai)。

## 🌟 为什么需要这个 Skill？

OpenClaw 极其强大，但它的系统级守护进程配置对新手来说很容易踩坑。这个技能包能让 AI 帮你实现“无菌室”级别的全自动安装：

- **绝对的零依赖 (Zero Dependencies)**：你的电脑上甚至不需要安装 Node.js！脚本会自动探测你的 CPU 架构（Intel 或 ARM64 / M系列芯片），并把专用的 Node 环境封装在私有目录中，绝不污染你本机的环境。
- **Mac 外接硬盘免疫 (破解 Exit Code 78)**：如果你选择把 OpenClaw 安装到外置硬盘（`/Volumes/...`），macOS 严苛的 `launchd` 防火墙会拒绝写入日志并导致服务崩溃。这个技能内置了底层修复逻辑，让外接硬盘安装也能一次点亮！（Linux系统原生完美支持）。
- **智能“三岔路口”模型向导**：它会像人一样主动询问并支持 3 种用户的配置需求：
  1. **官方账号白嫖党**：引导通过浏览器登录，利用 Google Gemini CLI 或 OpenAI Codex 的免费 OAuth 通道。
  2. **直连氪金大佬**：原生配置 Anthropic 或 OpenAI 的官方 API Key。
  3. **第三方中转/网关用户（小白福音）**：只需告诉 AI 你的 `BaseURL` 和 `API Key`，它会自动帮你写好复杂的 JSON 配置文件，并配置好完美的“国产高性价比基座 + 顶级代码模型兜底”策略。

## 🚀 如何使用 (How to Use)

由于你还没有安装 OpenClaw，你需要让**你手头现有的 AI 编程助手**（比如 opencode, Claude Code, Cursor 里的 Agent，或是命令行版 Codex）来执行这个技能：

1. 下载本仓库的 `openclaw-setup.md` 文件。
2. 将它放到你当前使用的 AI 助手的 `skills`（技能/规则）目录中。或者直接把这个文件的内容复制喂给你的 AI。
3. 在聊天框中对 AI 发送以下指令：
   > *"使用 openclaw-setup 技能帮我把 OpenClaw 部署到本机。"*
4. 接下来，你只需要喝口茶。AI 会自动接管终端，中途它会弹窗采访你“想安装在哪个盘？”以及“想用哪种模型方案？”，最后它会直接把配置好带 Token 的 Dashboard 链接发到你的屏幕上。

## 📂 项目结构
- `openclaw-setup.md`：核心的 AI Agent 技能定义文件，基于标准的 Markdown 编写，任何高级大模型均可无障碍理解并执行。

---
*这个技能诞生于对抗 macOS 守护进程和 SSRF 网络代理的深坑之中。不要再和终端配置搏斗了，让 Agent 来部署 Agent。*
