# ============================================================================
# OBS 桶策略版本化 —— 华为云 Serverless 实践（Terraform + huaweicloud Provider）
# ----------------------------------------------------------------------------
# 业务能力：
#   1. 账号内任意 OBS 桶发生 PutBucketPolicy（设置桶策略）时，自动把该策略快照
#      记录到 OBS 存储桶（按 md5 哈希命名，天然去重/可追溯）。
#   2. 需要时可通过 Restore 函数，凭策略哈希把历史策略一键还原到目标桶。
#
# 事件链路：
#   OBS PutBucketPolicy (CTS 记录) -> FunctionGraph CTS 触发器 -> register 函数
#     -> 写 OBS 快照
#
# 数据链路：
#   OBS 存储桶（对象即记录，前缀 policies/<hash>.json）
#   按桶名查询通过“列举 policies/ 前缀并按 bucket_name 过滤”实现。
#
# 凭据：provider 从环境变量 HW_ACCESS_KEY / HW_SECRET_KEY 读取，绝不硬编码。
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "= 1.96.0"
    }
  }

  backend "local" {}
}

provider "huaweicloud" {
  region = var.region
  # AK/SK 通过环境变量注入：
  #   export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
  #   export HW_SECRET_KEY="<HW_SECRET_KEY>"
  # 临时凭证再加 export HW_SECURITY_TOKEN="<TOKEN>"
}

# 账号主域 ID —— 用于 OBS 桶策略 Principal（OBS 数据面只认桶策略，不认 IAM/委托临时凭证）
data "huaweicloud_account" "current" {}

# ============================================================================
# Layer 1: 存储 —— OBS 存储桶（serverless、按用量计费）
# ============================================================================

resource "huaweicloud_obs_bucket" "policy_store" {
  bucket        = var.store_bucket_name
  acl           = "private"
  force_destroy = false # 版本化快照桶，禁止误删；清理见部署指南
  versioning    = true  # 开启多版本，策略快照防误覆盖/误删

  tags = {
    project = var.project_name
    service = "obs-bucket-policy-versioning"
  }
}

# 桶策略：授予 FunctionGraph 委托对存储桶的读写权限（必填，否则 403）
# Principal 格式固定为 "domain/<domain_id>:agency/<agency_name>"（OBS 控制面格式）
resource "huaweicloud_obs_bucket_policy" "policy_store" {
  bucket = huaweicloud_obs_bucket.policy_store.bucket
  policy = jsonencode({
    # 注意：OBS 存储/回读桶策略时会丢弃 Version 字段（华为官方桶策略示例亦不带 Version），
    # 若写上会导致 terraform plan 出现永久漂移，故省略。
    Statement = [
      {
        Sid       = "AllowFunctionGraphAgency"
        Effect    = "Allow"
        Principal = {
          ID = [
            "domain/${data.huaweicloud_account.current.id}:agency/${huaweicloud_identity_agency.fgs.name}"
          ]
        }
        Action = [
          "GetObject",
          "PutObject",
          "DeleteObject",
          "ListBucket"
        ]
        Resource = [
          huaweicloud_obs_bucket.policy_store.bucket,
          "${huaweicloud_obs_bucket.policy_store.bucket}/*"
        ]
      }
    ]
  })
}

# ============================================================================
# Layer 2: IAM 委托 —— 让 FunctionGraph 以临时凭证访问 OBS
# OBS Administrator 是 AX（全局/domain 级）角色，必须用 domain_roles，
#   不能用 project_role，否则授权静默失效。
# ============================================================================

resource "huaweicloud_identity_agency" "fgs" {
  name                  = "${var.project_name}-fgs-agency"
  description           = "Agency for FunctionGraph to read/write OBS bucket-policy snapshots"
  duration              = "FOREVER"
  delegated_service_name = "op_svc_cff" # FunctionGraph 服务主体
  domain_roles          = ["OBS Administrator"]
}

# ============================================================================
# Layer 3: 计算 —— FunctionGraph 函数
# 访问密钥供给：函数运行期临时 AK/SK/Token 只经 handler(event, context) 的
#   context 提供，不在任何环境变量里；客户端必须在 handler 内构建。
# 依赖打包：FGS Python3.9 运行时【内置】esdk-obs-python，zip 只放 index.py；
#   严禁 pip install --target 把 obs/cryptography 打进去（Windows .pyd 会让 FGS Linux 加载失败）。
# ============================================================================

resource "huaweicloud_fgs_function" "register" {
  name        = "${var.project_name}-register"
  app         = "obs_bucket_policy_versioning" # FunctionGraph app(包)名仅允许 [A-Za-z0-9_]，不可含连字符
  agency      = huaweicloud_identity_agency.fgs.name
  handler     = "index.handler"
  memory_size = 256
  timeout     = 30
  runtime     = "Python3.9"

  code_type = "obs"
  # 函数代码 zip 由 src/functions/build.sh 打包并上传到本存储桶 function-code/ 下
  code_url = "https://${huaweicloud_obs_bucket.policy_store.bucket}.obs.${var.region}.myhuaweicloud.com/function-code/register.zip"

  user_data = jsonencode({
    REGION       = var.region
    STORE_BUCKET = huaweicloud_obs_bucket.policy_store.bucket
  })

  description = "CTS 触发：捕获 OBS PutBucketPolicy，将策略快照写入 OBS 存储桶"
}

resource "huaweicloud_fgs_function" "restore" {
  name        = "${var.project_name}-restore"
  app         = "obs_bucket_policy_versioning" # FunctionGraph app(包)名仅允许 [A-Za-z0-9_]，不可含连字符
  agency      = huaweicloud_identity_agency.fgs.name
  handler     = "index.handler"
  memory_size = 256
  timeout     = 30
  runtime     = "Python3.9"

  code_type = "obs"
  code_url = "https://${huaweicloud_obs_bucket.policy_store.bucket}.obs.${var.region}.myhuaweicloud.com/function-code/restore.zip"

  user_data = jsonencode({
    REGION       = var.region
    STORE_BUCKET = huaweicloud_obs_bucket.policy_store.bucket
  })

  description = "手动/API 调用：凭策略哈希从 OBS 快照还原桶策略到目标桶"
}

# ============================================================================
# Layer 4: 触发器 —— CTS 关键事件通知 -> SMN -> FunctionGraph(SMN 触发器)
# OBS 是全局服务，CTS 直连 FunctionGraph 触发器实测不可靠，统一走官方推荐的 SMN 桥接
# （已端到端验证可用：setBucketPolicy -> CTS -> SMN -> FGS -> 写 OBS 快照）：
#   CTS notification(customized, 精准订阅 OBS:bucket:setBucketPolicy)
#     -> SMN topic -> FunctionGraph SMN 触发器。
# 关键：agency_name="cts_admin_trust" 会让 CTS 在创建通知时【自动建好】
#       “CTS 发布到 SMN”所需的云服务委托，无需手动建 identity_agency。
# register 函数按 trace_name 过滤 setBucketPolicy，并兼容 SMN 信封
# event["message"] 与直投 event["cts"] 两种形态（见 index.py 的 _extract_cts）。
# ============================================================================

resource "huaweicloud_smn_topic" "policy_events" {
  name = "${var.project_name}-policy-events"
}

resource "huaweicloud_cts_notification" "policy_events" {
  name           = "policyctsnotifysmn" # 换名避撞之前 func_urn 孤儿通知(不可经 terraform 管理)
  operation_type = "customized"         # 精准订阅 OBS bucket setBucketPolicy
  smn_topic      = huaweicloud_smn_topic.policy_events.topic_urn
  agency_name    = "cts_admin_trust"    # CTS 自动创建发布到 SMN 的云服务委托
  enabled        = true

  operations {
    service     = "OBS"
    resource    = "bucket"
    trace_names = ["setBucketPolicy"]
  }
}

resource "huaweicloud_fgs_function_trigger" "register_smn" {
  function_urn = huaweicloud_fgs_function.register.urn
  type         = "SMN"
  event_data = jsonencode({
    topic_urn = huaweicloud_smn_topic.policy_events.topic_urn
    events    = ["message.publish"]
  })
}
