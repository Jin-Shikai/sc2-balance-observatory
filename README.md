# SC2 Balance Observatory

宏观视角的星际2平衡性观测平台：补丁事件研究（Δ胜率 + Δ人口 + 置信区间）、分段位平衡剖面、地图池 vs 补丁归因、种族迁移流、职业 vs 天梯平衡差。观测对象为职业选手与 Diamond+ 天梯玩家。

AWS (Lambda / EventBridge / S3 / Secrets Manager) + Terraform + Databricks (Unity Catalog / Medallion / Lakeview)。

## 结构

```
infra/          Terraform（storage / ingestion / databricks 三个 module，S3 remote state）
ingestion/      Python 采集层，零第三方依赖（boto3/urllib3 由 Lambda runtime 提供）
databricks/sql/ Medallion：bronze.sql (COPY INTO) → silver.sql → gold.sql，由 Databricks Job 按 git 源执行
web/            Opponent Lens 静态页（GitHub Pages，直连 SC2 Pulse API，无后端）
```

## 数据源

| 源 | 用途 | 鉴权 |
|---|---|---|
| [SC2 Pulse](https://sc2pulse.nephest.com/sc2/) | 天梯胜率帧、活跃度、段位门槛、D+ 队伍扫描 | 无（响应头动态限流） |
| [Aligulac](https://aligulac.com/about/api/) | 职业比赛与 Elo | apikey |
| Battle.net API | 联赛构成官方口径、GM 榜 | OAuth client credentials |

数据仅作非商业用途，遵循各源许可。

## 部署

1. 建 tfstate bucket，`terraform -chdir=infra init -backend-config=...`
2. 填入 secrets（值不进 Terraform state 之外的任何地方）：
   ```
   aws secretsmanager put-secret-value --secret-id sc2obs/blizzard \
     --secret-string '{"client_id":"...","client_secret":"..."}'
   aws secretsmanager put-secret-value --secret-id sc2obs/aligulac \
     --secret-string '{"apikey":"..."}'
   ```
3. Databricks 按版本二选一：
   - **Free Edition**：tfvars 里设 `databricks_free_edition = true`。复用内置 Starter Warehouse
     （Free Edition 只允许一个 warehouse），跳过 S3 挂载，原始数据走 managed volume
     `/Volumes/sc2/bronze/raw`，需要手动同步：
     ```
     aws s3 sync s3://<raw桶>/raw ./raw
     databricks fs cp -r ./raw dbfs:/Volumes/sc2/bronze/raw
     ```
   - **付费/试用 workspace**：Unity Catalog storage credential 需要两阶段 apply——首次 apply 后读取
     output `storage_credential_external_id`，写入变量 `databricks_storage_credential_external_id`
     再 apply 一次（IAM trust policy 的 ExternalId 依赖 Databricks 生成的值）。
4. 历史回填：
   ```
   aws lambda invoke --function-name sc2obs-pulse_daily \
     --payload '{"seasons":[59,60,61,62,63,64,65,66,67,68]}' /dev/null
   aws lambda invoke --function-name sc2obs-aligulac_daily \
     --payload '{"since":"2023-01-01"}' /dev/null
   ```

## 已知取舍

- Silver/Gold 用 `CREATE OR REPLACE ... AS` 全量重建：当前数据量（数万行/天）下最简单且幂等，量级上来后再换 MERGE 增量。
- 胜率帧的时间粒度由 Pulse 的 `frameDuration`（通常 7 天）决定，补丁事件窗口按帧边界取整。
- 镜像对局不计入胜率；所有胜率带 Wilson 95% CI，事件研究以 CI 不重叠为显著标准。
- `blizzard_league` 的 division member_count 结构以官方响应为准，`silver.fct_league_composition` 中的解析在首批数据落地后需校验一次。
- Opponent Lens 依赖 Pulse 对 `*.github.io` 的 CORS 白名单，本地开发需以 github.io 域名或代理访问。

## Credits

Ladder data by [SC2 Pulse](https://sc2pulse.nephest.com/sc2/) (non-commercial). Pro data by
[Aligulac](https://aligulac.com/). Battle.net data © Blizzard Entertainment. This is not an official
Blizzard product.
