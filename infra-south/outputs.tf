# ============================================================================
# 输出
# ============================================================================

output "store_bucket" {
  description = "存储桶策略快照的 OBS 桶名"
  value       = huaweicloud_obs_bucket.policy_store.bucket
}

output "register_function_urn" {
  description = "register 函数 URN（CTS 触发，自动记录策略快照）"
  value       = huaweicloud_fgs_function.register.urn
}

output "restore_function_urn" {
  description = "restore 函数 URN（手动调用，按哈希还原策略）"
  value       = huaweicloud_fgs_function.restore.urn
}

output "fgs_agency_name" {
  description = "FunctionGraph 委托名（已授予 OBS Administrator）"
  value       = huaweicloud_identity_agency.fgs.name
}
