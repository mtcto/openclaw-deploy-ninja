# OpenClaw 一键部署脚本 (openclaw-deploy-ninja)

这是一个为 [OpenClaw](https://github.com/openclaw/openclaw) 量身定制的一键安装与配置向导脚本。

## ✨ 项目亮点

1. **主打极致安全**  
   默认配置下只有主 Agent 具备操作宿主机环境的全部权限。而创建的子 Agent 将全部分离并强制运行在安全的 Docker 沙箱（Sandbox）环境中。命令拦截与环境隔离，让你的 OpenClaw 再也不用“裸奔”。

2. **自动集成开源优质环境**  
   自动检测并安装必备依赖（Node.js、Docker等），并无缝集成安装 `@openclaw-china/channels` 插件，轻松解决中国区插件及国内渠道服务对接问题。

3. **通讯渠道向导式配置**  
   告别手工修改冗长复杂 JSON 配置文件的痛苦。脚本支持向导式地一步步配置 **Telegram**、**钉钉**、**飞书** 以及 **企业微信** 渠道对接参数。

4. **Agent向导式建立及隔离路由绑定**  
   向导会自动辅助你对多个 Agent 进行设置、赋权并完成渠道通道的多账号绑定与事件隔离。

5. **支持双轨安装：联网 & 本地双离线模式**  
   对于网络通畅的开发者，可选择“联网安装”始终拉取最新上游代码与依赖；对于服务器无法翻墙或受限于内网的情况，可选择“本地模式”一键安装本地提供的预下载依赖（如 `offline-packages`）。

---

## 🚀 快速开始

克隆或下载本仓库，并赋予执行权限运行即可：

```bash
chmod +x openclaw-install.sh
./openclaw-install.sh
```

> **注意：** 若您选择的是**本地安装**模式，请保证项目当前文件夹下 `offline-packages` 目录内存放了对应最新版的 `.tgz` 及 Node.js、Docker 的依赖包。

---

## 🗑️ 卸载与清理

如果您需要将 OpenClaw 从该宿主机及其对应的沙箱容器完全卸载清理：

```bash
./openclaw-install.sh uninstall
```

*(该操作会重置环境变量，移除 npm global 安装文件，删掉 config 目录并清空名为 `openclaw-sbx-` 的 Docker 沙箱实例)*
