# ============================================================================
# 变量定义 —— OBS 桶策略版本化（Serverless）
# 本实践以华为云原生服务实现 OBS 桶策略版本化能力，所有规格均显式写死。
# ============================================================================

variable "region" {
  description = "华为云区域（CTS 触发器对全局级服务 OBS 在部分区域可能受限，详见部署指南）"
  type        = string
  default     = "cn-north-4" # 北京四
}

variable "project_name" {
  description = "项目名称，用于资源命名前缀"
  type        = string
  default     = "obs-bucket-policy-versioning"
}

# OBS 桶名为全局唯一，请务必改成你账号下不会冲突的名字
variable "store_bucket_name" {
  description = "存储桶策略版本快照的 OBS 桶名（全局唯一）"
  type        = string
  default     = "obs-bucket-policy-versioning-store"
}
