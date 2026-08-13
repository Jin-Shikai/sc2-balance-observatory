# SC2 Balance Observatory

[English](README.md)

每天采集星际2的天梯和职业比赛数据，在数仓中建模，输出为两个静态页面。覆盖钻石及以上段位。

**在线页面：** [平衡看板](https://jin-shikai.github.io/sc2-balance-observatory/balance.html) · [Opponent Lens](https://jin-shikai.github.io/sc2-balance-observatory/)

技术栈：AWS Lambda · S3 · EventBridge · Terraform · Databricks · GitHub Actions · Chart.js

## 两个页面

### 平衡看板

![平衡看板](docs/balance.jpg)

四个视图，带赛季/地区/段位筛选和中英切换：

- 对阵胜率热力图（对阵 × 段位）
- 胜率 × 比赛时长。SC2 Pulse 按比赛结束的分钟数分桶，曲线呈现平衡从前期到后期的变化。
- 赛季环比胜率变化表，可排序，悬停显示该赛季的平衡补丁。加粗行通过了双比例 z 检验。
- 平衡补丁前后 28 天的职业胜率变化（Aligulac 比赛数据）。实色柱为统计显著。

### Opponent Lens

![Opponent Lens](docs/opponent-lens.jpg)

搜索任意玩家，从对手的角度看他最近 100 场天梯 1v1：对手按种族分组并给出交手战绩，每个对手近 30 或 90 天的 MMR 曲线，被查玩家自己的曲线以白色粗线显示。点击任意一条线可只对比这两人；点击对手名字可跳转到他。

## 目前的发现

- 5.0.16 补丁后，天梯上 Zerg 对 Protoss 的胜率在 9 个"地区 × 段位"切片中的 8 个上升（+0.5 到 +1.3 个百分点）；随后 28 天的职业比赛中上升 8.4 个百分点。
- 水平越高，平衡补丁的影响越显著。5.0.16 所在赛季，TvZ 在钻石段的变动不超过 ±1 个百分点，大师段下降 1.6–2.2 个百分点，韩服宗师下降 4.8 个百分点；职业比赛中同一补丁使 ZvP 变动 +8.4 个百分点，约为钻石段变动的八倍。

## 工作原理

![架构](docs/architecture.svg)

**采集。** 五个 Lambda 函数。EventBridge 每天触发其中两个采集器，分别拉取 SC2 Pulse 和 Aligulac，原始 JSON 按来源、端点、日期分区写入 S3。

**同步。** Databricks Free Edition 读不到 S3，所以 S3 的文件创建事件会触发一个 Lambda，通过 Files API 把新文件复制进 Databricks volume。

**数仓。** Databricks 上的三层 SQL，每天由一个直接从本仓库读 SQL 文件的 job 执行。

- Bronze 用 `COPY INTO` 把原始 JSON 装载为 `VARIANT`，已装载过的文件自动跳过。
- Silver 解析成 11 张表，并做清洗：快照去重、玩家更换 division/种族后重置的计数器等。
- Gold 产出 7 张分析表：带 Wilson 区间的胜率、赛季环比、每个平衡补丁前后 28 天的职业事件研究、种族迁移流。

**发布。** GitHub Actions 每天早上通过 SQL Statement API 查询 gold 表，把结果写成 JSON 存入 `web/data/`，提交并部署 GitHub Pages。两个页面都是单个 HTML 文件，用 Chart.js 渲染。

**基础设施。** AWS 和 Databricks 侧全部由 Terraform 定义，分 storage、ingestion、databricks 三个模块，状态存在 S3。CI 在每次 push 时跑 ruff、pytest 和 `terraform validate`。

## 仓库结构

```
infra/            Terraform 模块
ingestion/        Python 采集器（Lambda）
databricks/sql/   bronze / silver / gold
web/              两个页面 + 导出的数据
scripts/          数据导出和同步脚本
.github/          CI、Pages 部署、每日数据刷新
```

## 数据

天梯数据来自 [SC2 Pulse](https://sc2pulse.nephest.com/sc2/)，职业数据来自 [Aligulac](https://aligulac.com/)，官方联赛人数来自 Battle.net API（用于校验管道：EU/US 的人口计数偏差在 1–5% 以内）。所有数据均为非商业使用并注明来源。与暴雪娱乐无关联。
