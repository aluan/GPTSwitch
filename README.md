# GPTSwitch

<p align="center">
  <img src="Brand/GPTSwitchLogo.png" alt="GPTSwitch Logo" width="180">
</p>

<p align="center">
  面向 macOS Codex App 的第三方模型切换、协议兼容、使用统计与界面换肤工具。
</p>

<p align="center">
  <a href="https://aluan.github.io/GPTSwitch/">官网</a> ·
  <a href="https://github.com/aluan/GPTSwitch/releases/latest">下载</a>
</p>

GPTSwitch 在 Mac 本机启动原生 Swift 代理，让 Codex 在 ChatGPT 账号登录、Responses API 中转站和 OpenAI-compatible Chat Completions 服务之间切换，并为只支持 Responses 托管 `image_generation` 的 Provider 补齐新版 Codex Images API。

## 功能

- 将 `/images/generations`、`/images/edits` 转换为 Responses `image_generation`。
- 将 Codex Responses 请求转换为 DeepSeek、GLM、通用 `/chat/completions` 和 Anthropic-compatible `/messages` 请求。
- 将已登记的第三方模型注入 Codex App、TUI 和 CLI 模型选择器，并按 `provider/model` 路由。
- 添加、检测、排序和快速切换 ChatGPT 账号与多个第三方 Provider。
- 查看请求、Token、延迟与估算成本统计。
- 使用四款内置主题，或导入图片自动取色并自定义 Codex 界面。
- 停用代理时安全恢复原 Provider 地址。

## 安装

要求 macOS 14 或更高版本。

1. 从 [GitHub Releases](https://github.com/aluan/GPTSwitch/releases/latest) 下载 DMG 或 ZIP。
2. 将 `GPTSwitch.app` 拖入“应用程序”。
3. 从菜单栏打开主界面，添加 Provider 并点击“应用并启动”。
4. 完全退出并重新打开 Codex。

如果使用“ChatGPT 账号登录”Provider，请先在 Codex App 或 Codex CLI 中登录 ChatGPT，确保 `~/.codex/auth.json` 包含有效登录态；不需要填写 API Key。

GPTSwitch 是菜单栏工具，不显示 Dock 图标。当前公开包使用 ad-hoc 签名；如果 macOS 阻止首次打开，可在 Finder 中右键选择“打开”，或运行：

```bash
xattr -dr com.apple.quarantine "/Applications/GPTSwitch.app"
open "/Applications/GPTSwitch.app"
```

## 工作原理

启用时，GPTSwitch 会备份 `~/.codex/config.toml`，将当前 Provider 的 `base_url` 指向本机代理，并通过 `model_catalog_json` 挂载 `~/.codex/gptswitch-catalog.json`：

```text
Codex → 127.0.0.1:17891 → Provider
```

- Codex 模型菜单与 `/models` 只返回当前 Provider 的目录，切换 Provider 后会立即重建目录与模型缓存。
- 请求默认严格使用当前 Provider；旧对话引用的模型不属于当前 Provider 时会提示重新选择，不会静默切回旧 Provider。设置中可显式开启高级跨 Provider 路由。
- Chat Provider 的 `/responses` 双向转换为 `/chat/completions`，包括文本、思考内容和工具调用。
- Anthropic-compatible Provider 的 `/responses` 双向转换为流式 `/messages`，支持 thinking signature 和工具结果回传。
- Images API 请求转换为 Responses 托管生图。
- 返回图片重新封装后交给 Codex 保存和展示。

Codex 升级后通常无需重新配置，因为 GPTSwitch 不替换 Codex CLI，也不修改 Codex.app。

### Provider 配置

新建 Provider 时可选择“ChatGPT 账号登录”。GPTSwitch 会只读复用 Codex 当前的 ChatGPT access token 和账号 ID，访问 `https://chatgpt.com/backend-api/codex`，协议固定为 Responses。缺少登录态、文件损坏、账号 ID 缺失或 token 已过期时，GPTSwitch 会阻止启动并提示先重新登录 Codex；GPTSwitch 不提供独立浏览器登录，也不刷新 OAuth token。

ChatGPT Provider 的模型目录来自 GPTSwitch 当前登记的原始 Codex 模型 ID，不请求内部后端的 `/models`。创建模板默认沿用当前 Codex/活动 Provider 的模型，之后仍可手动增删模型目录项；请求转发时继续按 `provider/model` 编码并向上游还原原始模型 ID。

### 第三方模型协议

Provider 可以选择 `Responses API`、`Chat Completions` 或 `Anthropic Messages`。新建 Provider 提供 Responses 中转站、通用 Chat Completions、Anthropic Messages 中转站和 Anthropic 官方 API 模板；模型 ID 始终由用户填写。Chat Completions 仍可按服务兼容类型处理 `thinking`、`reasoning_effort` 和 `reasoning_content` 字段。

每个 Provider 可以维护多条 Codex 模型目录项，包括展示名称、启用状态、reasoning effort 和图片输入能力。只有当前 Provider 的模型会以 `provider/model` 出现在 Codex App 输入框的模型菜单中；切换 Provider 后会同步选择该目录中的可用模型，触发 Codex 自动刷新菜单。上游模型 ID 含 `/` 时，GPTSwitch 只编码 Codex-facing slug，并在代理层还原真实 ID。“从 `/models` 刷新”只追加新候选，不覆盖手工元数据。停用代理时会恢复原来的模型、catalog 指针和模型缓存。

Provider 必须支持原生结构化工具调用才能启用。GPTSwitch 会在“工具兼容性”、切换 Provider 和启动代理时强制调用探针函数；仅返回普通文本、XML 或 JSON 伪调用的模型会被拒绝。协议转换统一经过内部请求模型和事件桥，未知工具、非法参数或损坏的上游 SSE 会返回明确的转换错误。

Anthropic Messages Provider 支持官方 `x-api-key` 和兼容中转站 Bearer 两种钥匙串认证；Responses Provider 仍支持沿用 Codex 凭据。Anthropic thinking signature 与 `redacted_thinking` 会按原始 block 顺序保存在 GPTSwitch 自有版本化 envelope 中回放，不会把代理生成的签名伪装成官方加密内容；旧版 `gpts1` envelope 仍可读取。

## 安全与数据

- 代理只监听 `127.0.0.1`，不会暴露到局域网或公网。
- API Key 保存在 macOS 钥匙串，不写入数据库、日志或 Codex 配置。
- ChatGPT OAuth 凭据只从 `~/.codex/auth.json` 读取并在内存中使用，不写入钥匙串、数据库或日志，也不会发送给第三方 Provider。
- 统计仅记录 Provider、模型、状态码、Token 和耗时，不保存 Prompt 或响应正文。
- 换肤通过本机 CDP 应用，不修改 Codex 安装包或签名资源。

换肤使用未认证的本机 CDP 端口 `9341`；同一用户权限下的其他本机进程可能访问该端口。不使用主题时可点击“恢复原生界面”关闭此边界。

## 当前限制

- 生图 Provider 需支持 HTTP Responses API 和托管 `image_generation`。
- ChatGPT 账号模式依赖 Codex 当前使用的非公开内部端点 `chatgpt.com/backend-api/codex`，该端点可能随 Codex 更新而变化。
- Chat Completions 和 Anthropic Messages Provider 不支持 Images API 或 Responses 托管的 `web_search`、`file_search`、`image_generation` 工具。
- 当前 Provider 只有在健康检查未失败且凭据完整时才会进入 Codex 模型目录；上游 `/models` 不可用时需手动登记模型。
- Anthropic Messages 适配面向兼容中转站，暂不承诺 Anthropic 官方 API 的认证与全部 Beta 能力。
- Anthropic 官方 API 仅承诺 Messages、thinking、工具调用和 usage 的基础兼容，不包含 OAuth、Beta transport 或 prompt-cache 扩展。
- Responses WebSocket 不经过生图转换。
- `images/edits` 的能力取决于 Provider 实现。
- 换肤仅支持 macOS 版官方 Codex。
- 当前公开包尚未进行 Apple 公证。

## 开发

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
./script/build_and_run.sh --verify
xcodebuild test \
  -project CodexImageGenProxy.xcodeproj \
  -scheme CodexImageGenProxy \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
./script/package_app.sh
```

原生代码位于 `App/`，测试位于 `AppTests/`。Python 代理和命令行安装器仅作为旧版兼容后备。

## 相关项目

- [HeiGeAi/heige-codex-skin-studio](https://github.com/HeiGeAi/heige-codex-skin-studio)
- [lidge-jun/opencodex](https://github.com/lidge-jun/opencodex)
- [OpenAI Codex PR #31596](https://github.com/openai/codex/pull/31596)
- [OpenAI Codex Issue #30921](https://github.com/openai/codex/issues/30921)

本项目采用 [MIT License](LICENSE)。
