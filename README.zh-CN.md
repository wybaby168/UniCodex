<p align="center">
  <img src="docs/logo.png" alt="UniCodex 应用图标" width="120" height="120">
</p>
<h1 align="center">UniCodex</h1>
<p align="center">基于 Codex 引擎的原生 macOS 编程工作台</p>
<p align="center"><a href="README.md">English</a></p>

在指定的本机项目目录中运行 Codex，使用自己的 API Key，按会话和任务选择供应商、模型与推理强度。模型请求由所选供应商处理并按其 API 规则计费。

## 操作演示

<p align="center">
  <img src="docs/unicodex-demo.webp" alt="UniCodex 在同一会话从 OpenAI 切换到 DeepSeek，并生成发布检查清单" width="920">
</p>

在同一会话切换供应商，将上一轮的回答整理成发布清单。录屏使用演示数据。[静态截图](docs/unicodex-demo-still.webp)

## 主要功能

- **多会话并行**。多个任务可独立运行，会话支持重命名和归档。
- **会话中切换模型**。可在下一轮更换供应商、模型和推理档位，跨供应商接续时带入最近对话。
- **长对话阅读**。原生 Markdown、可折叠的思考摘要和工具详情，以及可点击打开或在 Finder 中显示的本地文件链接。
- **本机 MCP**。其他 Agent 可以派发任务、查询结果和取消任务。
- **原生 macOS 界面**。基于 SwiftUI 和 AppKit，在 macOS 26 及以上使用系统液态玻璃效果。支持简体中文、英语、日语、韩语、德语、法语和俄语。

## 构建和安装

需要 macOS 14 或以上、Xcode 26 或以上，以及 Python 3.11 或以上。请先选中完整的 Xcode 开发目录。

~~~sh
git clone https://github.com/wybaby168/UniCodex.git
cd UniCodex
./build.sh
~~~

应用会安装到 `/Applications/UniCodex.app`。首次构建会创建本机签名身份，后续构建复用签名和未改变的密钥读取组件。只构建供检查时，可使用 `./build.sh --build-only`，产物在 `build/UniCodex.app`。

1. 打开 UniCodex。应用可使用独立管理的 Codex 引擎，也可使用「应用程序」中 ChatGPT 附带的引擎。缺少引擎时，在「偏好设置 → 引擎」检查更新，校验完成后重新打开应用。
2. 通过左下角齿轮或 **⌘,** 打开「偏好设置 → 供应商」。可配置 OpenAI、DeepSeek、Kimi Code、Google Gemini，也可添加支持 Responses API 的自定义 HTTPS 端点。首次使用 OpenAI 密钥时，通过 **+** 添加 OpenAI 配置。
3. 在聊天工具栏选择工作目录、模型和推理强度，然后发送任务。界面语言和主题色可在「偏好设置 → 外观」更改。

新配置的 API Key 保存在本机 macOS 钥匙串。

## 本机 MCP

在「偏好设置 → Agent」可以复制 MCP 配置。在 Codex 中可运行以下命令完成注册。

~~~sh
codex mcp add codex_api_workbench -- /Applications/UniCodex.app/Contents/MacOS/APIWorkbench --mcp
~~~

先用 `list_models` 确认模型和推理档位，再通过 `dispatch_task` 传入模型、推理强度及绝对工作目录。使用返回的 `task_id` 调用 `task_status` 等待结果，或用 `cancel_task` 取消。任务需要审批时会在 UniCodex 中显示。完整参数示例见[英文文档](README.md#local-mcp)。

## 开发和许可

~~~sh
xcrun swift-format lint --strict --recursive Sources/UniCodex Tests
python3 Tests/offline_check.py
~~~

离线检查使用真实 Codex 引擎和本机模拟服务。可设置 `WORKBENCH_TEST_CODEX_BINARY` 指定另一个兼容的引擎。

UniCodex 源码采用 [MIT 许可证](LICENSE)。内置的 Codex 模型元数据沿用上游的 [Apache 2.0 许可证](Resources/CodexCatalog-LICENSE.txt)。[第三方来源与许可](THIRD_PARTY_NOTICES.md)

UniCodex 是基于 [OpenAI Codex](https://github.com/openai/codex) 开发的独立项目。
