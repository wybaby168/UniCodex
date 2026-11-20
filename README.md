<p align="center">
  <img src="docs/logo.png" alt="UniCodex app icon" width="120" height="120">
</p>
<h1 align="center">UniCodex</h1>
<p align="center">A native macOS workbench for coding agents built on the Codex engine.</p>
<p align="center">
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="#build-and-install">Build and install</a> ·
  <a href="#local-mcp">Local MCP</a>
</p>

UniCodex runs Codex coding sessions in the local folders you choose. Bring your own API keys, run several chats at once, and choose the provider, model, and reasoning level for each turn. Model calls go to the selected provider and use that provider’s API billing.

## Demo

<p align="center">
  <img src="docs/unicodex-demo-v1.11.5.webp" alt="UniCodex switches from OpenAI to DeepSeek in the same chat and generates a release checklist" width="920">
</p>

Continue the same chat with another provider and turn the previous answer into a release checklist. Recorded in the local UniCodex 1.11.5 app with sample data. [Still image](docs/unicodex-demo-still-v1.11.5.webp)

## What you can do

- **Work in parallel.** Open multiple chats, let tasks run independently, and rename or archive work as you go.
- **Plan and implement.** Choose an engine-supported collaboration mode by the message composer. In Plan mode, answer Codex’s clarifying questions and review its proposed plan. **Implement Plan** continues in the same chat using Default mode.
- **Switch models mid-conversation.** Pick a provider, model, and supported reasoning level for the next turn. Cross-provider continuations carry recent conversation context into the new engine.
- **Work with long transcripts.** Select text across Markdown blocks, copy progress messages and replies, collapse tool output and reasoning summaries, and open local file links or reveal them in Finder.
- **Delegate from another agent.** Send tasks over local MCP and follow their status by task ID.
- **Use a native macOS interface.** SwiftUI and AppKit provide the window, menus, and transcript. Liquid Glass is available on macOS 26 and later. The interface supports English, Simplified Chinese, Japanese, Korean, German, French, and Russian.

## Install

Download the universal ZIP for Apple silicon and Intel Macs running macOS 14 or later. Extract it and move **UniCodex.app** to **Applications**. [Download UniCodex](https://github.com/wybaby168/UniCodex/releases/latest)

The v1.11.7 archive uses the maintainer’s signing certificate. It has no Apple notarization ticket, so Gatekeeper may block the first launch. You can also build locally.

### Build from source

You need macOS 14 or later, Xcode 26 or later selected as the active developer directory, and Python 3.11 or later. The build targets the Mac’s current architecture.

~~~sh
git clone https://github.com/wybaby168/UniCodex.git
cd UniCodex
./build.sh
~~~

This installs `/Applications/UniCodex.app`. The first build creates a local signing identity. Later builds reuse the credential helper when its source is unchanged so provider keys remain accessible across app updates. To compile a signed bundle in the checkout instead, run `./build.sh --build-only`. The bundle appears at `build/UniCodex.app`.

### First run

1. Open UniCodex. It uses its managed Codex engine or the engine bundled with ChatGPT in Applications. If the engine is missing, look under **Preferences → Updates → Codex Engine** and check for updates. Reopen UniCodex after the update is verified.
2. Open **Preferences → Providers** from the sidebar gear or with **⌘,**. Select a provider profile and save its API key. For a new OpenAI key, add an OpenAI profile with **+**.
3. Choose a working folder and a model in the chat toolbar, then send a task. Open **Appearance** to choose the app language and accent color.

| Provider | Profile |
| --- | --- |
| OpenAI | Add an OpenAI profile with an API key |
| DeepSeek | Configure the built-in DeepSeek profile |
| Kimi Code | Configure the built-in profile and choose the service region |
| Google Gemini | Configure the built-in Gemini profile |
| Custom | Supply an HTTPS base URL that supports the Responses API and the model IDs to expose |

New provider keys are stored in the local macOS Keychain. UniCodex uses an application-specific directory for its engine, workspaces, and session state.

## Updates

UniCodex checks [GitHub Releases](https://github.com/wybaby168/UniCodex/releases) for a stable application update on launch. **Preferences → Updates** shows the installed version and lets you check again. Matching installers open in your browser for manual installation.

The Codex engine checks for stable releases on launch and every 24 hours. It starts with OpenAI’s CDN and automatically falls back to the official GitHub release and npm distribution. UniCodex verifies the checksum, macOS code signature, and app-server compatibility before selecting a new engine for the next launch. Update checks remove unused managed engines and abandoned download files. Active sessions keep using their current engine.

Run `./build.sh --release` to create a locally signed `UniCodex-macos-universal.zip` and its `SHA256SUMS` in `build/`. For Apple notarization, use a Developer ID Application certificate, hardened runtime, and a secure timestamp. Staple the ticket to the DMG, or to the app before creating the final ZIP. The GitHub updater recognizes the `UniCodex-macos-arm64`, `UniCodex-macos-x86_64`, and `UniCodex-macos-universal` asset names with a `.dmg` or `.zip` extension. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Local MCP

Open **Preferences → Agent** to copy the stdio server configuration. To register it in Codex, run the following command.

~~~sh
codex mcp add codex_api_workbench -- /Applications/UniCodex.app/Contents/MacOS/APIWorkbench --mcp
~~~

| Tool | Purpose |
| --- | --- |
| `list_models` | List configured providers, models, and collaboration mode IDs. Pass a provider ID to see supported reasoning levels. |
| `dispatch_task` | Start a task with an optional absolute workspace path, provider, model, reasoning level, and `mode`. Reuse a `request_id` with the same input when retrying. |
| `task_status` | Check progress or wait up to 20 seconds for a status change. Retrieve the answer when the task finishes. |
| `cancel_task` | Stop a task started through MCP. |

For example, an MCP client can pass these arguments to `dispatch_task` after confirming the model with `list_models`.

~~~json
{
  "prompt": "Read this project and summarize its entry points.",
  "workspace": "/path/to/project",
  "provider": "deepseek-default",
  "model": "deepseek-flash",
  "effort": "high",
  "request_id": "inspect-project-001"
}
~~~

Set `"mode": "plan"` to request a plan. Call `task_status` with the returned `task_id`. If it reports `waiting_input`, answer the question in the UniCodex chat. Approvals appear there too. The MCP connection runs locally under the current macOS user.

## Develop and verify

- [Sources/UniCodex](Sources/UniCodex) contains the app, transcript renderer, provider adapters, and MCP server.
- [Sources/Credentials](Sources/Credentials) contains the signed credential helper.
- [Resources/Localization](Resources/Localization) contains one native string bundle per interface language.
- [Tests](Tests) contains a local fixture that drives the real Codex app-server without provider API calls.

~~~sh
xcrun swift-format lint --strict --recursive Sources/UniCodex Tests
python3 Tests/offline_check.py
~~~

The offline check uses the Codex engine bundled with ChatGPT in Applications by default. Set `WORKBENCH_TEST_CODEX_BINARY` to the path of another compatible Codex executable to test that engine. The test uses temporary workspaces and synthetic credentials.

## License

The UniCodex source is available under the [MIT License](LICENSE). The bundled Codex model metadata carries its upstream [Apache 2.0 license](Resources/CodexCatalog-LICENSE.txt). See [third-party notices](THIRD_PARTY_NOTICES.md) for provenance and attribution.

UniCodex is an independent project built on [OpenAI Codex](https://github.com/openai/codex).
