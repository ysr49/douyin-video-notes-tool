# VideoKB 基础产品与架构设计

- 文档状态：初始需求冻结
- 冻结日期：2026-06-22
- 工作名称：VideoKB
- 第一阶段正式平台：抖音

## 1. 产品定位

VideoKB 是一个 Windows 本地运行的跨平台视频内容采集、转写和知识化材料生成工具。

它不是单纯的“视频转文字”工具。核心价值是将大量分散在视频平台中的公开内容，稳定地转化为可阅读、可检索、可迁移、可继续分析的标准材料。

产品形态固定为：

1. 本地命令行工具（CLI）。
2. Codex Skill 自然语言入口。
3. 普通文件形式的可迁移交付物。
4. 本地 SQLite 任务台账。

第一版不开发图形界面、云服务、内置聊天界面或内置 RAG 问答系统。

## 2. 用户与使用场景

### 2.1 核心用户

- 需要批量整理视频资料的个人研究者。
- 需要建立博主、主题或赛道资料库的内容从业者。
- 为客户提供视频转写、资料整理或内容研究服务的交付者。

### 2.2 核心场景

- 输入一个博主主页链接，首次同步其全部可访问公开视频。
- 后续重复运行时只同步新增或变化作品。
- 输入单个视频链接，生成该作品的原始文字稿和知识库材料。
- 按博主、主题或任务输出作品清单、合订本和标准知识片段。
- 在明确开启时，对选定或新增内容进行 AI 深加工。

## 3. 产品分层

### 3.1 平台采集层

每个平台由独立 Adapter 负责：

- 识别平台链接。
- 解析博主与作品身份。
- 枚举全部可访问作品。
- 处理该平台的登录与分页。
- 输出统一作品清单。

首批平台注册表：

| 平台 | Adapter ID | 初始状态 |
|---|---|---|
| 抖音 | `douyin` | `available` |
| B站 | `bilibili` | `planned` |
| 小红书 | `xiaohongshu` | `planned` |
| 视频号 | `wechat_channels` | `planned` |
| YouTube | `youtube` | `planned` |
| 快手 | `kuaishou` | `planned` |
| TikTok | `tiktok` | `planned` |

`planned` 只代表接口预留，不得伪装成已经支持。

### 3.2 内容加工层

- 统一下载媒体。
- 提取或下载音频。
- 使用本地 Faster-Whisper 转写。
- 保留分段和时间戳。
- 生成标准原稿文件。
- 支持断点续跑、去重和失败重试。

### 3.3 知识与交付层

零 Token 的确定性处理：

- 按时间戳切片。
- 清理格式和重复内容。
- 绑定来源、博主、标题、发布时间和作品 ID。
- 生成 Markdown、TXT、SRT、JSON、JSONL 和 CSV。
- 生成博主或任务合集索引。

可选 AI 处理：

- 一句话摘要。
- 内容大纲。
- 核心观点与论据。
- 方法、步骤和行动清单。
- 案例、数据和工具。
- 金句与可引用片段。
- 主题、标签、人物和实体。
- 可用于选题的角度。

原稿是不可覆盖的主数据；AI 结果始终是可删除、可重新生成的派生数据。

## 4. 商业交付定位

VideoKB 的技术核心不绑定具体售价，但必须能够支持以下交付层级：

| 层级 | 典型交付 |
|---|---|
| 低价工具型 | 少量链接的文字稿和摘要 |
| 批量交付型 | 指定博主或合集的文字稿、清单、Word/Excel 类材料 |
| 研究交付型 | 批量采集、摘要、分类、选题洞察和 AI 知识库材料 |

长期壁垒定义为：稳定采集、交付速度、断点续跑、统一材料格式和可复用研究模板，而不是“能把视频转成文字”。

## 5. 稳定架构边界

```text
平台链接
   ↓
Adapter Registry → Platform Adapter → 标准作品清单
                                      ↓
                               Media Downloader
                                      ↓
                                Audio Processor
                                      ↓
                              Local Transcriber
                                      ↓
                         Canonical Transcript Store
                           ↙                    ↘
                  Deterministic Exporters     Optional AI Processor
                           ↓                    ↓
                       原始材料              AI 加工材料
```

项目目录边界：

```text
video-knowledge-pipeline/
├─ adapters/          # 平台适配器
├─ core/              # 编排、配置、状态与安全控制
├─ downloader/        # 统一媒体下载
├─ transcriber/       # 本地转写
├─ knowledge/         # 切片、知识材料与可选 AI 加工
├─ exporters/         # 各种普通文件格式
├─ cli/               # 命令行入口
├─ skill/             # Codex Skill
├─ tests/             # 自动化测试
└─ workspace/         # 用户数据和任务结果
```

平台差异只允许进入 `adapters/`。下载、转写、知识材料和输出模块不得依赖具体平台。

## 6. Adapter 统一输出契约

Adapter 至少输出以下字段：

```json
{
  "schema_version": "1.0",
  "platform": "douyin",
  "creator_id": "platform-creator-id",
  "creator_name": "creator name",
  "video_id": "platform-video-id",
  "title": "video title",
  "source_url": "https://example.com/video/id",
  "published_at": "2026-06-22T00:00:00+08:00",
  "duration_ms": 75334,
  "media_candidates": [
    {
      "kind": "audio",
      "url": "temporary media URL",
      "expires_at": null
    }
  ]
}
```

平台 Adapter 不得直接调用转写器或 AI。

## 7. 原稿主数据

每条作品保存一份带时间戳的标准 JSON，至少包含：

```json
{
  "schema_version": "1.0",
  "platform": "douyin",
  "video_id": "platform-video-id",
  "source_url": "https://example.com/video/id",
  "language": "zh",
  "transcriber": {
    "engine": "faster-whisper",
    "model": "base"
  },
  "segments": [
    {
      "start_ms": 0,
      "end_ms": 3200,
      "text": "第一段原始文字"
    }
  ],
  "full_text": "完整原始文字"
}
```

由该 JSON 派生：

- 原稿 Markdown。
- 纯文本 TXT。
- 字幕 SRT。
- 知识库 JSONL。

## 8. AI 知识材料策略

### 8.1 默认行为

- 默认 `AI=off`。
- 抓取、转写、切片和知识库材料整理不调用 AI。
- 没有 AI Provider 时，核心任务仍必须成功。

### 8.2 Provider 规则

- AI Provider 可替换，不得与核心流程绑定。
- 可支持本地模型或用户显式配置的云端 API。
- 云端 AI 必须手动开启并设置处理范围和预算。
- AI 失败不得回滚或阻断原稿交付。

### 8.3 Token 控制

- 按内容哈希缓存结果，已处理内容不重复调用。
- 增量同步只处理新增或变化内容。
- 合集总览基于单篇短摘要生成，不重复提交全部原稿。
- 默认不预生成全部金句、选题和洞察。
- 用户可选择单条、选中集合或仅新增内容进行 AI 加工。

## 9. 登录与账号安全基线

以下规则属于不可绕过的核心约束：

1. 默认匿名访问；只有平台明确限制公开分页时才请求用户登录。
2. 每个平台使用独立、持久化的浏览器配置。
3. 通过平台官方页面由用户扫码或登录。
4. 不读取、导出、解密或要求用户粘贴 Cookie。
5. 登录会话只用于取得作品清单和必要的临时媒体地址。
6. 媒体下载器不得携带账号 Cookie。
7. 单次只处理一个博主的平台枚举任务。
8. 平台分页采用低频、带随机等待的访问策略。
9. 音频下载默认并发为 1–2，可在不增加平台请求的前提下调整本地处理并发。
10. 验证码、HTTP 403、HTTP 429、异常空响应或登录异常立即暂停任务。
11. 禁止代理池、账号轮换、验证码破解和风控绕过。
12. 必须支持增量同步，避免重复访问和处理已完成作品。
13. 每日安全上限由 Adapter 提供保守默认值；达到上限时停止并报告。

## 10. 数据保留策略

- 转写成功后默认删除下载的音频。
- `--keep-audio` 时保留音频。
- 下载或转写失败时保留临时文件用于重试。
- 原稿、元数据、知识片段、任务台账和交付文件长期保留。
- 用户复制整个 workspace 项目目录即可完成迁移。

## 11. SQLite 任务台账

SQLite 是项目目录内的单个本地数据库文件，不依赖网络或数据库服务。

至少记录：

- 平台和博主。
- 作品身份和内容哈希。
- 发现、下载、转写、导出和 AI 状态。
- 临时文件与最终文件路径。
- 重试次数、最后错误和更新时间。
- Adapter、转写模型、Schema 和 AI 材料版本。

普通用户不需要直接操作数据库；所有可阅读交付物仍为普通文件。

## 12. 任务状态与容错

单条作品状态：

- `discovered`
- `downloaded`
- `transcribed`
- `exported`
- `ai_processed`
- `failed`
- `blocked`

规则：

- 单条失败不得阻断整批任务。
- 网络波动自动重试，并逐步延长等待时间。
- 安全事件将整个平台枚举任务标记为 `blocked` 并立即停止。
- 只有转写成功后才能按默认策略删除音频。
- 原稿导出完成即视为核心任务完成。
- 所有失败可由 `retry` 命令单独重跑。
- 去重主键为 `platform + video_id`。

## 13. CLI 稳定接口

```powershell
videokb sync "<博主主页或视频链接>"
videokb status
videokb retry
videokb export
videokb ai
videokb platforms
```

- `sync`：识别平台并增量同步。
- `status`：查看任务进度。
- `retry`：重试失败作品或任务。
- `export`：重新生成交付文件，不重新下载。
- `ai`：按需生成 AI 加工材料。
- `platforms`：显示 Adapter 的 `available/planned/disabled` 状态。

Codex Skill 只负责将自然语言转换为一次或少量 CLI 调用，并读取最终摘要；不得把完整文字稿或长日志返回模型上下文。

## 14. 工作区交付结构

```text
workspace/
└─ <platform>/
   └─ <creator-id>/
      ├─ project.db
      ├─ manifest.csv
      ├─ manifest.json
      ├─ originals/
      │  ├─ <video-id>.json
      │  ├─ <video-id>.md
      │  ├─ <video-id>.txt
      │  └─ <video-id>.srt
      ├─ knowledge/
      │  ├─ chunks.jsonl
      │  └─ collection-index.md
      ├─ ai/
      │  └─ <video-id>.md
      ├─ audio/              # 仅失败任务或 --keep-audio
      ├─ complete-transcripts.md
      └─ failures.json
```

## 15. 性能基线

基于 2026-06-22 的一次本地实测：

- 41 条作品，总音频约 173.7 分钟。
- 当前 CPU/int8 Faster-Whisper Base 约为 5.2 倍实时速度。
- 首次全量同步预计约 40–50 分钟，主要耗时为本地转写。
- 无新增作品的增量检查目标为 1 分钟内结束。
- 平台访问速度不得为了缩短总耗时而突破安全基线。

性能数字是观测基线，不是对所有硬件的保证。

## 16. 核心验收标准

1. 输入已支持平台的博主主页链接，能够枚举全部可访问公开视频。
2. 重复运行只处理新增或变化作品，不重复下载和转写。
3. 任务中断后可断点续跑。
4. 每条作品生成原稿、时间戳分段 JSON、Markdown、TXT 和 SRT。
5. 每个博主生成 CSV 清单、JSONL 知识库材料和合订本。
6. 默认不调用任何 AI，不产生云端 Token 费用。
7. AI 加工失败不得影响原稿交付。
8. 转写成功后默认删除音频，`--keep-audio` 时保留。
9. 遇到验证码、403、429 或登录异常立即暂停，不绕过风控。
10. 任务最终只向 Codex 返回简短 JSON 摘要，不回传全文和长日志。
11. 抖音作为第一期正式 Adapter；其他主流平台显示为 `planned`。
12. Windows 本地环境一条安装命令、一条同步命令即可运行。
13. 单条失败不影响整批，其余作品继续完成。
14. 所有输出可脱离 VideoKB 直接阅读和迁移。
15. 自动测试覆盖链接识别、去重、断点续跑、导出和安全暂停规则。

## 17. 测试要求

| 测试层 | 覆盖内容 |
|---|---|
| 单元测试 | 链接识别、Adapter 注册、去重、状态转换、切片、导出、保留策略 |
| 集成测试 | 作品清单到下载、转写、导出的完整本地管线 |
| Adapter 合约测试 | 每个平台统一输出字段、分页、登录阻塞和临时地址处理 |
| 恢复测试 | 强制中断后继续、单条失败后重试、已有结果跳过 |
| 安全测试 | 403、429、验证码和异常登录触发立即暂停 |
| 回归测试 | 固定样本生成的文件结构和 Schema 保持兼容 |

测试不得依赖持续高频访问真实平台；平台响应应优先使用脱敏录制样本进行回放。

## 18. 冻结项与扩展项

### 18.1 冻结项

- 三层产品架构。
- Adapter 与核心管线的隔离。
- 原稿不可被 AI 覆盖。
- 默认零 AI Token。
- SQLite 管状态、普通文件做交付。
- 登录与账号安全基线。
- CLI 六个核心命令及其职责。
- 平台无关的主数据 Schema 1.x。
- 转写成功后默认删除音频。

### 18.2 允许扩展但不得破坏冻结项

- 新增平台 Adapter。
- 新增下载后端。
- 新增转写模型。
- 新增 AI Provider。
- 新增知识处理模板。
- 新增导出格式。
- 新增 GUI 或云服务作为独立上层产品。

破坏 Schema 兼容性或核心命令语义的修改必须进入新的主版本，不得作为普通功能迭代直接修改。

## 19. 实施顺序

1. 建立核心 Schema、SQLite 台账、CLI 和 Adapter 合约。
2. 将现有抖音抓取与 Faster-Whisper 能力迁入新边界。
3. 完成确定性知识材料和全部导出格式。
4. 建立 Codex Skill，并确保只返回短摘要。
5. 完成自动化测试和安全暂停测试。
6. 在核心稳定后逐个平台新增 Adapter。
7. 最后增加可选 AI Provider 与研究模板。

该顺序保证先冻结基础数据和安全边界，再扩展平台与 AI 能力。
