# 多 Agent 人才评估系统：面试流程图

> 核心认知：项目注册了 4 张 LangGraph 图。`talent_decision_engine` 是主图，依次调用要求理解、评估分发、报告生成 3 张子图。向量检索、BM25、RRF 和 Rerank **不是独立的 LangGraph 图**，而是 `talent_evaluation_dispatch` 子图中 `run_assessment_branch` 节点调用的证据检索工具链。

```mermaid
flowchart TB
    %% ---------- 离线/异步材料入库 ----------
    subgraph INDEX[一、材料入库与证据索引：异步数据链路，不属于决策主图]
        direction LR
        I1[HR 上传材料<br/>简历 / 项目复盘 / 面试记录] --> I2[对象存储<br/>保存原文件]
        I1 --> I3[(PostgreSQL<br/>文档、版本、权限、任务状态)]
        I3 --> I4[Redis 解析队列]
        I4 --> I5[Worker + MinerU<br/>解析 Markdown / 结构化内容]
        I5 --> I6[按标题或递归切片<br/>默认 800 字 + 100 overlap]
        I6 --> I7[Embedding<br/>text-embedding-v3 / 1024维]
        I7 --> I8[(Milvus talent_evidence_v2<br/>稠密向量 + BM25 稀疏索引)]
        I6 --> I3
    end

    %% ---------- 主图 ----------
    U[用户提出人才需求] --> M0

    subgraph MAIN[二、talent_decision_engine：决策引擎主图 / 总编排]
        direction TB

        subgraph REQUEST[图1 talent_request：要求理解、澄清、候选人预筛]
            direction TB
            M0[receive_request<br/>接收需求 + 注入可信租户和权限]
            M0 --> R1[interpret_input<br/>LLM 结构化理解用户要求]
            R1 --> R2{输入方式}
            R2 -->|岗位名称| R3[lookup_job_descriptions]
            R3 --> R4{唯一精确匹配?}
            R4 -->|否| R5[HITL interrupt<br/>人工选择岗位或取消]
            R4 -->|是| R6[确认岗位 JD]
            R5 --> R6
            R2 -->|详细要求| R7[直接编译]
            R6 --> R8[build_plan]
            R7 --> R8
            R8 --> R9[QueryPlan<br/>硬条件 / 语义要求 / 偏好 / 待澄清项]
            R9 --> R10{是否含糊、矛盾?}
            R10 -->|是| R11[HITL 修改完整要求<br/>重新解释并生成计划]
            R11 --> R1
            R10 -->|否| R12[PostgreSQL 参数化筛选<br/>地区、职级、年限等硬条件]
            R12 --> R13{候选集为空?}
            R13 -->|是| R11
            R13 -->|否| R14[candidates_ready<br/>输出 candidate_ids + TalentRequest + QueryPlan]
        end

        subgraph DISPATCH[图2 talent_evaluation_dispatch：生成评估维度、分发取证]
            direction TB
            D0[receive_input<br/>接收已确认候选人和 QueryPlan]
            D0 --> D1[generate_dimensions<br/>LLM 动态生成评估 Rubric]
            D1 --> D2[评估维度 EvaluationDimension<br/>名称 + 定义 + 权重<br/>证据要求 + 检索提示<br/>0/3/5分锚点 + 需求来源]
            D2 --> D3{程序校验<br/>权重合计是否等于100}
            D3 -->|不通过| D4[dimension_invalid<br/>停止执行]
            D3 -->|通过| D5[prepare_work_items<br/>候选人 × 评估维度]
            D5 --> D6{工作项是否超过24}
            D6 -->|超过| D7[capacity_exceeded<br/>缩小候选集或分批执行]
            D6 -->|未超过| D8[LangGraph Send 并行分发<br/>每个 work item 一个评估分支]

            subgraph BRANCH[run_assessment_branch：单个候选人 × 单个维度]
                direction TB
                B1[遍历本维度 evidence_requirements]
                B1 --> B2[组合证据要求 + retrieval_hints<br/>形成检索 Query]
                B2 --> B3[调用 search_candidate_evidence 工具]

                subgraph SEARCH[证据检索工具链：不是独立 LangGraph 图]
                    direction TB
                    S0[限定当前 tenant / permission / candidate]
                    S0 --> S1[Embedding 查询向量]
                    S0 --> S2[BM25 中文关键词查询]
                    S1 --> S3[Milvus HNSW 稠密召回]
                    S2 --> S4[Milvus BM25 稀疏召回]
                    S3 --> S5[RRF k=60 融合两路排名<br/>取得 Top 20]
                    S4 --> S5
                    S5 --> S6[gte-rerank-v2 Cross-Encoder 精排]
                    S6 --> S7[保留 Top 8 Chunk]
                    S7 --> S8[PostgreSQL 原文回表 + 二次鉴权]
                    S8 --> S9[LLM 事实抽取<br/>事实 / 缺失 / 冲突 / 引用]
                    S9 --> S10[程序校验证据<br/>Chunk白名单 / 候选人归属<br/>quote必须是连续原文]
                end

                B3 --> S0
                S10 --> B4[RequirementEvidence<br/>sufficient / partial / missing / conflicting]
                B4 --> B5[BranchEvidenceDraft<br/>聚合该候选人该维度的全部证据]
            end

            D8 --> B1
            B5 --> D9[operator.add reducer<br/>聚合所有 branch_results]
            D9 --> D10[branches_ready<br/>或 branches_ready_with_failures]
        end

        subgraph REPORT[图3 talent_evaluation_report：证据评分、稳定排名、报告]
            direction TB
            P0[receive_input<br/>校验候选人 × 维度矩阵完整性]
            P0 --> P1[为证据分配 E1 / E2 短编号<br/>保存到真实 Chunk ID 的映射]
            P1 --> P2[score_dimensions<br/>最多12并发，根据证据和0/3/5锚点评分]
            P2 --> P3[证据状态处理<br/>missing / conflicting / failed 分数为 null<br/>不能把材料缺失当成0分]
            P3 --> P4[review_consistency<br/>按候选人检查跨维度事实冲突]
            P4 --> P5[程序确定性聚合<br/>加权确认得分 + 理论上限 + 覆盖率]
            P5 --> P6[程序稳定排序<br/>确认得分 → 覆盖率 → candidate_id<br/>LLM不决定最终排名]
            P6 --> P7[report_writer<br/>生成带 E1/E2 引用的 Markdown 报告]
            P7 --> P8[validate_report<br/>恢复真实Chunk ID并校验引用白名单]
            P8 --> P9[最终人才评估与推荐报告]
        end

        R14 --> D0
        D10 -->|允许继续| P0
    end

    I8 -. 为在线检索提供证据 .-> S0
    I3 -. 提供结构化候选人和可信原文 .-> R12
    I3 -. 原文回表 .-> S8

    %% ---------- 样式 ----------
    classDef input fill:#fff4d6,stroke:#b7791f,color:#4a2c00,stroke-width:2px;
    classDef graph fill:#e8f3ff,stroke:#2563eb,color:#0f2a54,stroke-width:2px;
    classDef dimension fill:#f1e8ff,stroke:#7c3aed,color:#32156b,stroke-width:3px;
    classDef retrieval fill:#e8fbf2,stroke:#059669,color:#064e3b,stroke-width:2px;
    classDef guard fill:#fff0f0,stroke:#dc2626,color:#681313,stroke-width:2px;
    classDef output fill:#eaf7ff,stroke:#0284c7,color:#0c4a6e,stroke-width:3px;

    class U,I1 input;
    class M0,R1,R2,R3,R4,R5,R6,R7,R8,R9,R10,R11,R12,R13,R14,D0,D1,D3,D5,D6,D8,D9,D10,P0,P1,P2,P3,P4,P5,P6,P7,P8 graph;
    class D2 dimension;
    class B1,B2,B3,B4,B5,S0,S1,S2,S3,S4,S5,S6,S7,S8,S9,S10 retrieval;
    class D4,D7 guard;
    class P9 output;
```

## 一句话区分每张图

| 图 | 回答“它负责什么” | 关键节点或输出 |
|---|---|---|
| `talent_decision_engine` | 总编排，决定三个子图是否继续执行 | request → dispatch → report |
| `talent_request` | 理解需求、查岗位、人工澄清、SQL 预筛候选人 | `candidate_ids`、`QueryPlan` |
| `talent_evaluation_dispatch` | 生成评估维度，构造任务矩阵，并行检索和核验证据 | `dimensions`、`branch_results` |
| `talent_evaluation_report` | 按维度评分、一致性检查、程序排名、生成报告 | `ranking`、`report` |
| 混合检索工具链 | 向量 + BM25 → RRF → Rerank → 回表鉴权 | 在 `run_assessment_branch` 内被调用，不是第五张图 |

## 面试讲解顺序

1. 先讲材料如何解析、切片、Embedding 并写入 Milvus。
2. 再讲主图串联三张子图，任何含糊或空候选场景先经过 HITL。
3. 重点讲评估维度是动态评分 Rubric，不是简单关键词。
4. 解释候选人 × 维度形成任务矩阵，每个分支按证据要求检索。
5. 解释向量和 BM25 负责召回，RRF 负责融合，Rerank 负责精排。
6. 最后强调模型负责理解和评价，权限、引用校验、加权排名由程序控制。
