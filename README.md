# Steria agent

一个**会主动找你**的 AI 伙伴，不只是被动回答问题，还能根据你订阅的信息源主动判断“现在该不该发消息、发什么”，并在空闲时自主执行后台任务。

---

## Quickstart

需要 Python 3.12。

```bash
git clone <this-repo>
cd Steria-agent
uv venv && uv pip install -r requirements.txt
```

没有 `uv`？先执行 `pip install uv`。

**1. 初始化**

```bash
uv run python main.py setup    # 交互向导（推荐）
uv run python main.py init     # 非交互，CI / 自动化用
```

**2. 填写 `config.toml`**

推荐配置：DeepSeek 主模型 + Qwen 轻量 / 视觉 / 向量：

```toml
[llm]
provider = "deepseek"

[llm.main]
model = "deepseek-v4-flash"     # 主模型：推理强、速度快、价格低
api_key = "sk-..."
base_url = "https://api.deepseek.com/v1"
enable_thinking = true          # 开启 reasoning
multimodal = false              # DeepSeek 不支持图片，用 VL 工具补

[llm.fast]
model = "qwen-flash"            # 轻量模型：memory gate / query rewrite / HyDE
api_key = "sk-..."
base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"

[llm.vl]
model = "qwen-vl-plus"          # 视觉：主模型 multimodal=false 时自动启用
api_key = "sk-..."
base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"

[memory]
enabled = true
engine = ""                     # 记忆引擎，留空 = default_memory 插件

[memory.embedding]
model = "text-embedding-v3"     # 向量模型
api_key = "sk-..."
base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"

[channels.telegram]
token = "123456:ABC..."
allow_from = ["your_username"]
```

**个人推荐**

这个项目和 `deepseek-v4-flash` 以及 Qwen 相性比较好

**3. 启动**

```bash
uv run python main.py
```

给 bot 发一条消息即可开始对话。

---

## 系统全景

```text
你的消息 → [被动回复] ──→ agent loop ──→ 回复
                │
                ├── 记忆系统 ─── 每轮注入长期记忆 + 对话后 consolidation
                │
                └── 插件系统 ─── 拦截命令、注入协议、阻断工具、挂载新工具...

[主动推送] ──→ 定期轮询 ──→ 三路数据 (alert/content/context) ──→ LLM 决策 ──→ 推送或跳过
                │
                └── [Drift] ──→ 没东西推时执行后台任务 (SKILL.md)
```

---

## 被动回复

收到消息后，系统会进行记忆检索、工具调用，并输出流式回复。每轮经过 6 个 Phase：`BeforeTurn` → `BeforeReasoning` → `PromptRender` → `Reasoner` → `AfterReasoning` → `AfterTurn`。

插件有 **4 种介入方式**：`PhaseModule` 链（7 个 Phase 方法 + slot 依赖声明）、`EventBus` 装饰器（9 种事件）、`@on_tool_pre`（工具拦截）、`@tool`（注册工具）。详见[插件系统](./_handbook/plugins-tutorial.md)。

## 主动推送（Proactive）

Agent 会根据“电量模型”自适应调整轮询频率。你刚聊完时尽量不打扰你（8 分钟一次），半天没动静后会加速到 1 分钟一次。每轮拉取三路 MCP 数据：

- **alert**：高优先级告警，直接透传
- **content**：内容流，逐条由 LLM 评分分类
- **context**：背景上下文，按概率注入作为 fallback

详见 [Proactive 配置指南](./_handbook/proactive-guide.md)。

## 记忆系统

对话会通过 **consolidation** 自动提取为结构化事实：`HISTORY.md`（时间线事件） + `PENDING.md`（待归档缓冲） + `RECENT_CONTEXT.md`（近期上下文摘要）。**Optimizer** 会定时把 `PENDING` 归档进 `MEMORY.md`。中间加这一层，是为了保护 prompt cache，因为 `MEMORY.md` 全文注入 system prompt，高频修改会破坏缓存。

同时，`memory2.db`（向量层）提供语义检索。

详见 [记忆系统](./_handbook/memory-markdown.md)。

## Drift 空闲任务

没有内容可推时，agent 不会空转，而是执行你写的 `SKILL.md`（分步操作指南），比如审计长期记忆是否准确、补充用户画像、自我诊断。

详见 [Drift 指南](./_handbook/drift-guide.md)。

---

## 其他命令

```bash
uv run python main.py cli       # 连接运行中的 agent（TUI）
uv run python main.py dashboard # 打开 Dashboard（默认 :2236）
uv run python main.py --help    # 查看全部子命令

pytest tests/
akashic_RUN_SCENARIOS=1 pytest -c pytest-scenarios.ini tests_scenarios/
```

## 工作区

所有运行时数据都位于 `~/.akashic/workspace/`。
