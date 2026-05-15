# Akashic Agent 项目导读

这份导读的目标不是替代源码，而是帮你先建立一张“系统地图”：这个项目有哪些核心模块、一次消息怎么流动、记忆系统怎么把短期对话变成长期记忆、主动推送和插件又是怎么挂到主流程里的。

阅读时建议先跟着本文的顺序走。每一节都会尽量绑定到具体文件、类、函数，避免只讲抽象概念。

## 1. 先把它看成一个运行时系统

这个项目不是一个简单的 `prompt + LLM API` 脚本，而是一个 agent runtime。它包含：

- 多入口：CLI、Telegram、QQ/NapCat、Dashboard、Gateway。
- 主循环：接收用户消息，进入 agent loop，调用 LLM 和工具，生成回复。
- 长期记忆：把对话沉淀为结构化记忆，再在后续对话中召回。
- 主动推送：不等用户说话，也能根据外部事件或上下文触发消息。
- 插件系统：插件可以介入生命周期、注册工具、改写工具行为、扩展 Dashboard。

最先看的入口是 `main.py`：

- `main.py::serve()`：正常启动 agent 服务。
- `main.py::connect_cli()`：连接已经运行中的 agent，进入 CLI 对话。
- `main.py` 里的 `init` / `gateway` / `dashboard` / `cli` 分支：决定当前命令启动哪种模式。

真正把各模块组装起来的是 `bootstrap/app.py`：

- `AppRuntime.start()`：启动 observe、core runtime、channels、dashboard、proactive、memory optimizer。
- `AppRuntime.run()`：启动后等待停止信号，并在退出时做清理。

可以把启动路径理解成：

```text
main.py
  -> serve()
    -> build_app_runtime()
      -> AppRuntime.start()
        -> build_core_runtime()
        -> start_channels()
        -> build_dashboard_server()
        -> build_proactive_runtime()
```

这条路径很重要，因为你介绍项目时可以说：它不是把所有对象写在一个主函数里，而是通过 `bootstrap/*` 做依赖装配，把 agent core、通道、记忆、插件、后台任务分开管理。

## 2. Bootstrap 层：负责“把系统拼起来”

`bootstrap/` 目录可以理解成系统装配层。它不负责具体智能行为，而是把 provider、memory、tool、channel、scheduler、plugin 串成可运行对象。

重点文件：

- `bootstrap/app.py`：最高层 runtime 生命周期。
- `bootstrap/tools.py`：构建 agent core 依赖和工具注册表。
- `bootstrap/channels.py`：启动 CLI / Telegram / QQ 通道。
- `bootstrap/memory.py`：构建 memory runtime。
- `bootstrap/dashboard_api.py`：构建 Dashboard API。
- `bootstrap/proactive.py`：构建主动推送 runtime。

`bootstrap/tools.py` 是非常关键的文件。里面的几个函数能说明项目的装配思想：

- `build_registered_tools()`：把内置工具、MCP 工具、peer agent 工具、memory 工具、schedule 工具注册到统一工具表。
- `_build_loop_deps()`：构建 agent loop 需要的依赖，比如 `LLMConfig`、`MemoryConfig`、`QueryRewriter`、`SufficiencyChecker`、`ContextBuilder`、`ConsolidationService`。
- `build_core_runtime()`：创建 `AgentLoop`、`PluginManager`、`EventBus`、`SessionManager`，并返回 `CoreRuntime`。

这一层的设计思想是：agent 核心不直接 new 一堆基础设施，而是由 bootstrap 负责集中装配。这样通道、工具、记忆、插件可以替换或测试。

## 3. 多通道输入：同一个 agent core，多个入口

通道相关代码在 `infra/channels/` 和 `bootstrap/channels.py`。

入口通道包括：

- `infra/channels/cli.py` 和 `cli_tui.py`：本地 CLI 客户端。
- `infra/channels/ipc_server.py` 和 `ipc_endpoint.py`：CLI 与 agent 服务之间的 IPC。
- `infra/channels/telegram_channel.py`：Telegram 通道。
- `infra/channels/qq_channel.py`：QQ/NapCat 通道。
- `infra/channels/base.py`：通道抽象。

`bootstrap/channels.py::start_channels()` 做了几件事：

- 启动 IPC server，让 CLI 可以连接。
- 如果配置了 Telegram token，就启动 Telegram channel。
- 如果配置了 QQ bot_uin，就启动 QQ channel。
- 把通道注册给 `MessagePushTool`，这样 agent 后续可以主动往某个通道发消息。

可以这样介绍这个设计：

```text
外部通道只负责收发消息和权限过滤。
真正的 agent 行为仍然走同一个 AgentLoop / AgentCore。
```

这点是多通道 agent 的关键：不是给每个平台写一套 agent，而是把平台差异收束在 channel 层。

## 4. 一次被动对话怎么跑完

“被动对话”指用户先发消息，agent 再响应。核心在：

- `agent/looping/core.py`
- `agent/core/passive_turn.py`
- `agent/lifecycle/`

最值得看的文件是 `agent/core/passive_turn.py`。它里面的 `PassiveTurnPipeline` 把一次 turn 拆成几个阶段：

```text
BeforeTurn
  -> BeforeReasoning
    -> Reasoner.run_turn()
      -> AfterReasoning
        -> AfterTurn
```

对应代码对象：

- `PassiveTurnPipeline.run()`：一次 turn 的总流程。
- `DefaultReasoner.run_turn()`：真正进入 LLM/tool loop 的地方。
- `BeforeTurnFrame`、`AfterReasoningFrame`、`AfterTurnFrame`：生命周期阶段的 frame。

这套设计的价值是：项目没有把“准备上下文、调用 LLM、解析回复、写消息、发出站消息”混在一个函数里，而是拆成生命周期阶段。

你可以按下面方式理解：

```text
BeforeTurn：准备会话、上下文、触发事件。
BeforeReasoning：进入推理前补齐 prompt 所需信息。
Reasoner：执行 LLM + tool loop。
AfterReasoning：解析模型输出、持久化消息、生成出站消息。
AfterTurn：广播 TurnCommitted，真正 dispatch 出站消息。
```

相关目录：

- `agent/lifecycle/phases/before_turn.py`
- `agent/lifecycle/phases/before_reasoning.py`
- `agent/lifecycle/phases/before_step.py`
- `agent/lifecycle/phases/after_step.py`
- `agent/lifecycle/phases/after_reasoning.py`
- `agent/lifecycle/phases/after_turn.py`
- `agent/lifecycle/types.py`

如果面试里讲设计思想，可以说：这个项目把 agent 执行过程做成了可插拔生命周期，而不是一个黑盒调用链。插件和观测逻辑可以在明确阶段介入。

## 5. Reasoner：LLM 和工具循环

`DefaultReasoner` 在 `agent/core/passive_turn.py` 里，它负责把准备好的上下文交给模型，并处理工具调用。

它大致做这些事：

- 构造 attempt plan。
- 裁剪或组织历史消息。
- 渲染 prompt。
- 调用 LLM。
- 如果模型请求工具，就执行工具并把结果放回下一轮。
- 处理安全重试、上下文过长重试等情况。

工具的基础设施在：

- `agent/tools/registry.py`：工具注册表。
- `agent/tool_runtime.py`：工具执行 runtime。
- `agent/tool_hooks/`：工具 hook，比如执行前改写或拦截。
- `bootstrap/toolsets/`：按领域组装工具，如 memory、schedule、mcp、peer。

这说明这个项目里的 tool use 不是临时写死在 prompt 里，而是经过注册、发现、路由、执行、hook 的一套机制。

## 6. 会话系统：短期上下文从哪里来

会话相关代码在 `session/`：

- `session/manager.py`
- `session/store.py`

`SessionStore` 用 SQLite 存：

- `sessions`
- `messages`
- `last_consolidated`
- `last_user_at`
- `last_proactive_at`
- session metadata

`SessionManager` 负责运行时对象：

- 加载 session。
- 追加用户消息和 assistant 消息。
- 控制历史窗口。
- 特殊处理 proactive assistant message。
- 维护 `last_consolidated`。

这里要区分两个概念：

```text
短期上下文：当前 session 里的 messages。
长期记忆：memory2.db 里的结构化 memory_items。
```

`last_consolidated` 是连接两者的重要字段。它表示当前 session 里哪些消息已经被沉淀进长期记忆，避免重复 consolidation。

## 7. 记忆系统总览

记忆系统是这个项目最值得讲的部分之一。核心代码在：

- `memory2/store.py`
- `memory2/retriever.py`
- `memory2/memorizer.py`
- `memory2/embedder.py`
- `memory2/query_rewriter.py`
- `memory2/sufficiency_checker.py`
- `agent/looping/consolidation.py`
- `core/memory/port.py`
- `core/memory/default_runtime_facade.py`

它不是“把聊天记录丢进向量库”这么简单，而是分成四个阶段：

```text
短期消息
  -> consolidation 抽取长期信息
  -> MemoryStore2 写入结构化记忆和向量
  -> MemoryRetriever 混合检索
  -> injection block 注入后续 prompt
```

可以把它理解成：

```text
Session messages 是原始聊天历史。
ConsolidationService 把聊天历史提炼成 memory item。
MemoryStore2 负责存储、去重、强化、替换。
MemoryRetriever 负责召回和排序。
DefaultMemoryRetrievalPipeline 把召回结果交给 agent turn。
```

## 8. MemoryStore2：记忆怎么存

`memory2/store.py::MemoryStore2` 是底层存储。它基于 SQLite，并在可用时使用 `sqlite-vec` 存向量。

重要表结构在同一个文件顶部：

- `memory_items`：核心记忆表。
- `consolidation_events`：记录某次 consolidation 来源，避免重复写入。
- `memory_replacements`：记录旧记忆被新记忆替代的关系。
- `vec_items`：sqlite-vec 虚拟表，存 embedding。

每条记忆不只是文本，还包含这些重要字段：

- `memory_type`：如 `event`、`profile`、`preference`、`procedure`。
- `summary`：记忆摘要。
- `confidence`：可信度。
- `reinforcement`：重复出现时的强化次数。
- `emotional_weight`：情绪权重。
- `status`：如 `active` 或 `superseded`。
- `extra_json`：结构化扩展信息。

`MemoryStore2.upsert_item()` 是写入入口之一。它的设计不是简单 insert，而是会考虑：

- 内容 hash。
- 相同或相近记忆是否已经存在。
- 如果重复出现，增加 `reinforcement`。
- 写入或更新 embedding。
- 如果来自 consolidation，记录 `consolidation_events`。

`_hotness_score()` 是排序里的重要函数。它让记忆排序不只看语义相似度，还看：

- 最近是否更新。
- 出现或强化次数。
- 情绪权重。
- 时间衰减。

所以这个系统里“容易被召回的记忆”不是只有 embedding 相似这一条路，而是相似度、重要性、新鲜度共同决定。

## 9. 记忆不是 append-only：它会演化

真实长期记忆会更新、合并、覆盖，这个项目也做了类似设计。

相关代码在：

- `memory2/store.py`
- `memory2/memorizer.py`

几个关键概念：

- `status = active`：当前有效记忆。
- `status = superseded`：被新记忆替代的旧记忆。
- `memory_replacements`：记录替代关系。
- `merge_item_raw()`：合并或更新已有记忆。
- `mark_superseded()`：把旧记忆标记为被替代。
- `save_item_with_supersede()`：写入新记忆并处理替代关系。

这点可以作为项目亮点来讲：系统没有无限追加记忆，而是允许长期记忆随着新信息被修正。

## 10. 记忆检索：不是纯向量检索

检索逻辑主要在 `memory2/retriever.py`。

`MemoryRetriever.retrieve()` 里有三步：

```text
1. _retrieve_vector_lanes()
2. _retrieve_keyword_lane()
3. _rrf_merge()
```

含义分别是：

- 向量召回：用 embedding 找语义相关的记忆。
- 关键词召回：用文本匹配找精确命中的记忆。
- RRF 融合：把两路结果合并排序。

所以它是 hybrid retrieval，而不是 naive vector search。

这一点对模型名、文件名、包名、命令名这种 query 特别重要，因为这类内容通常更适合关键词检索，而不是纯语义检索。

检索后不是全部塞进 prompt，而是继续进入 injection：

- `_select_injection_sections()`：决定哪些记忆进入注入区。
- `_apply_char_budget()`：按字符预算裁剪。
- `build_injection_block()`：生成最终放进 prompt 的记忆块。

这说明记忆系统有两层决策：

```text
先决定找哪些记忆。
再决定哪些记忆值得放进当前上下文。
```

## 11. 记忆分数怎么理解

在 `memory2/store.py` 里，最终分数不是纯 semantic score。它会融合 hotness：

```python
final = (1.0 - hotness_alpha) * semantic + hotness_alpha * hotness
```

因此调试记忆召回时，要分清：

- `semantic`：语义相似度。
- `hotness`：基于强化、时间、情绪权重得到的重要性/新鲜度。
- `final`：最终排序分。

结果里还有 `_score_debug`，可以用来解释“为什么这条记忆排在这里”。

你之前遇到“模型名得分低”的问题，就属于这里的典型调试场景：模型名是结构化字符串，embedding 分数可能天然不高，最终分还会被 hotness 影响。

## 12. Consolidation：把短期对话沉淀成长期记忆

`agent/looping/consolidation.py` 是长期记忆形成的核心。

重点对象：

- `ConsolidationService`
- `ConsolidationService.consolidate()`
- `_select_consolidation_window()`
- `_format_conversation_for_consolidation()`
- `ConsolidationRuntime.trigger_memory_consolidation()`

它做的事情大致是：

```text
选择还没有 consolidation 的旧消息
  -> 格式化成 LLM 可读的 conversation
  -> 读取已有长期记忆和近期上下文
  -> 让 LLM 抽取 history entries 和 pending items
  -> 保存到 history / pending / memory store
  -> 抽取 profile / preference / procedure 等隐式记忆
  -> 更新 session.last_consolidated
```

这个模块解决的是 agent memory 里最关键的问题之一：

```text
不是所有聊天历史都应该永久保存。
需要把对话压缩、抽取、分类，再变成长期记忆。
```

如果你要重点介绍记忆系统，`ConsolidationService.consolidate()` 很值得顺着读。它是“短期上下文”和“长期记忆库”之间的桥。

## 13. Memory facade：为什么有 core/memory

项目里除了 `memory2/`，还有 `core/memory/`。

这不是重复，而是分层：

- `memory2/` 更偏具体实现，如 store、retriever、memorizer、embedder。
- `core/memory/port.py` 定义运行时需要的记忆能力接口。
- `core/memory/default_runtime_facade.py` 把具体实现包装成 agent core 可以调用的 facade。

这种设计让 agent core 不直接依赖底层 SQLite 或 sqlite-vec 细节，而是通过 facade 调用：

- `retrieve_related`
- `retrieve_related_vec`
- `save_from_consolidation`
- `build_injection_block`

可以这样讲：`memory2` 是引擎，`core/memory` 是面向 agent runtime 的接口层。

## 14. 主动推送：不是用户问一句才动

主动推送在 `proactive_v2/`。

重点文件：

- `proactive_v2/agent_tick.py`
- `proactive_v2/agent_tick_factory.py`
- `proactive_v2/gateway.py`
- `proactive_v2/drift_runner.py`
- `proactive_v2/state.py`
- `bootstrap/proactive.py`

`AgentTick.tick()` 是主动推送的一次 tick。它的流程不是直接发消息，而是先做 pre-gate：

- 有没有目标通道。
- 当前 session 是否正被被动对话占用。
- 是否处于投递冷却。
- 是否允许 any-action。
- 是否允许 context fallback。

通过后才进入：

```text
_run_loop(ctx)
  -> 读取 gateway 输入
  -> 判断 alert / content / context fallback
  -> 必要时进入 drift
  -> 调 LLM 产出候选消息

_post_loop(ctx)
  -> 做投递守卫
  -> 记录 delivery
  -> ack 已处理事件
```

这里的设计思想是：主动 agent 必须更克制。它不能一有信息就发，而要经过 gating、post guard、ack、cooldown，避免打扰用户或重复消费外部事件。

## 15. Drift：没有外部事件时的主动探索

`proactive_v2/drift_runner.py` 和 `driftPlugin/` 说明项目有一种 drift 机制。

可以把 drift 理解为：

```text
当没有明确 alert 或 content 输入时，
agent 可以根据已有上下文、记忆、技能队列做低频主动探索。
```

这和普通 proactive 的区别是：

- proactive 更像对外部事件的响应。
- drift 更像基于长期状态和兴趣的自发探索。

这部分可以作为项目特色讲，但如果没有深入读代码，简历或面试里不要说得太满。稳妥表达是：项目预留并实现了主动探索框架，和普通用户触发式对话分离。

## 16. 插件系统：不只是加载几个命令

插件系统在：

- `agent/plugins/manager.py`
- `agent/plugins/base.py`
- `agent/plugins/context.py`
- `plugins/`

`PluginManager` 做这些事：

- 扫描 `plugins/*/plugin.py`。
- 加载 plugin class。
- 读取 manifest/config。
- 注册 lifecycle handlers。
- 注册 tools。
- 注册 tool hooks。
- 收集 prompt render / before turn / after reasoning 模块。
- 注册 Dashboard 面板。

现有插件例子：

- `plugins/01_citation`：引用/来源相关能力。
- `plugins/02_meme`：meme 相关能力。
- `plugins/recall_inspector`：查看记忆召回上下文。
- `plugins/shell_restore`：通过 tool hook 改写危险 shell 行为。
- `plugins/status_commands`：状态命令，可以在进入正常 LLM 前处理。

这里最值得讲的设计点是：插件不是只能加命令，它能插入 agent 生命周期、工具系统和 Dashboard。因此扩展点覆盖了“推理前、推理后、工具执行、可观测界面”。

## 17. EventBus 和 lifecycle 事件

事件总线在 `bus/`：

- `bus/event_bus.py`
- `bus/events.py`
- `bus/events_lifecycle.py`
- `bus/internal_events.py`
- `bus/queue.py`
- `bus/processing.py`

它和 lifecycle 配合，让系统里的模块不必互相硬调用。

例如一次 turn 完成后，可以发出 `TurnCommitted` 之类事件，让插件、observe、后处理逻辑各自响应。

可以这样理解：

```text
lifecycle phase 负责组织主流程。
EventBus 负责把关键节点广播给周边模块。
```

这个结构让插件和观测逻辑更容易挂进去。

## 18. Dashboard 和可观测性

Dashboard API 在 `bootstrap/dashboard_api.py`。

它暴露的主要能力包括：

- sessions：查看会话和消息。
- memories：查看、编辑、删除记忆，查相似记忆。
- proactive：查看主动推送的 delivery、seen items、tick logs。
- observe：查看 cache / observe 摘要。
- plugin dashboard：加载插件自己的面板。

相关运行时状态：

- session 存在 `workspace/sessions.db`。
- memory 存在 `workspace/memory/memory2.db`。
- proactive 存在 `workspace/proactive.db`。
- observe 存在 `workspace/observe/observe.db`。

这说明项目不是只追求“能回复”，还考虑了长期运行时如何检查状态、调试记忆、追踪主动推送行为。

## 19. MCP、peer agent 和技能系统

外部能力编排主要在：

- `agent/mcp/`
- `bootstrap/toolsets/mcp.py`
- `agent/peer_agent/`
- `bootstrap/toolsets/peer.py`
- `agent/skills.py`
- `skills/`

MCP 让 agent 能接外部工具服务；peer agent 让它能派生或调用其他 agent；skills 则像一组可加载的行为说明或工具说明。

这块可以在项目介绍里轻轻带过：

```text
系统支持通过 MCP、peer agent、skills 扩展外部能力，不把所有工具写死在核心 agent loop 中。
```

如果没有深入改过这部分，面试时建议作为架构扩展点讲，不要把它包装成你主要实现的模块。

## 20. 推荐阅读顺序

如果你想尽量少翻代码，但能讲清设计，建议按这个顺序：

1. `main.py`
2. `bootstrap/app.py`
3. `bootstrap/tools.py`
4. `bootstrap/channels.py`
5. `agent/core/passive_turn.py`
6. `session/manager.py`
7. `agent/looping/consolidation.py`
8. `memory2/store.py`
9. `memory2/retriever.py`
10. `core/memory/default_runtime_facade.py`
11. `proactive_v2/agent_tick.py`
12. `agent/plugins/manager.py`
13. `bootstrap/dashboard_api.py`

这个顺序对应的是：

```text
怎么启动
  -> 怎么装配
  -> 消息从哪进来
  -> 一次对话怎么执行
  -> 短期会话怎么存
  -> 长期记忆怎么形成
  -> 长期记忆怎么存和召回
  -> 主动推送怎么做
  -> 插件和 Dashboard 怎么扩展
```

## 21. 可以怎么对外介绍这个项目

一句话版本：

```text
这是一个多通道个人 AI Agent 系统，围绕被动对话、长期记忆、主动推送和插件扩展构建了一套完整运行时。
```

稍微技术一点的版本：

```text
项目通过 bootstrap 层装配 LLM provider、工具注册表、通道、会话、记忆和插件；通过生命周期管线拆分一次 agent turn；通过 sqlite + sqlite-vec 实现结构化长期记忆，并用 consolidation 将短期对话沉淀成可检索记忆；同时支持 proactive tick 和 drift，让 agent 具备主动触达能力。
```

简历 bullet 可以写：

- 构建多通道个人 AI Agent，支持 CLI、QQ/NapCat、Telegram 等入口，并通过 channel 层统一消息收发、权限过滤与主动推送。
- 设计并接入长期记忆系统，基于 SQLite 和 sqlite-vec 实现结构化记忆存储、向量检索、关键词检索、RRF 融合排序与上下文注入。
- 实现对话 consolidation 流程，将短期会话抽取为 `event`、`profile`、`preference`、`procedure` 等长期记忆，并支持记忆强化、合并与替换。
- 基于 lifecycle pipeline 拆分 agent turn，在 `BeforeTurn`、`BeforeReasoning`、`AfterReasoning`、`AfterTurn` 等阶段支持插件和事件扩展。
- 接入 proactive runtime，通过 pre-gate、post-guard、ack、cooldown 等机制控制主动推送，降低重复触达和无效打扰。

## 22. 面试里讲记忆系统的 1 分钟版本

可以这样说：

```text
这个项目的记忆系统不是简单向量库。短期对话先存在 session messages 里，然后由 ConsolidationService 选择未处理过的历史窗口，调用 LLM 抽取长期有价值的信息，转成 event/profile/preference/procedure 等结构化 memory item。底层 MemoryStore2 用 SQLite 存元数据，并用 sqlite-vec 存 embedding，同时记录 reinforcement、emotional_weight、status 和 replacement 关系。检索时走 hybrid retrieval，同时做向量召回和关键词召回，再用 RRF 融合，最后根据类型阈值和字符预算生成 injection block 放回 prompt。
```

如果面试官追问“为什么这么设计”，可以补：

```text
因为长期记忆有三个难点：不能把所有聊天原文都塞进 prompt，不能只追加不修正，也不能只靠 embedding 排序。这个项目分别用 consolidation、supersede/reinforcement、hybrid retrieval + hotness scoring 来处理这些问题。
```

## 23. 你可以优先深入的三个点

如果准备简历或面试，最值得深入的是：

- `ConsolidationService.consolidate()`：这是短期聊天变长期记忆的桥。
- `MemoryRetriever.retrieve()`：这是 hybrid retrieval 和 injection 的核心。
- `PassiveTurnPipeline.run()`：这是一次 agent turn 的执行骨架。

这三个点连起来，就能讲清楚：

```text
用户消息如何进入 agent。
agent 如何拿到上下文和长期记忆。
对话结束后系统如何把新信息沉淀回长期记忆。
```

这也是这个项目最像“完整 agent 系统”的地方。
