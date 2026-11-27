# OBS 桶策略版本化 —— 部署指导书

## 1. 前置条件

- 华为云账号，具备创建 OBS / FunctionGraph / IAM 委托的权限。
- 本地安装：
- Terraform >= 1.5（`>= 1.5` 即可，provider 由 required_providers 自动解析）
- Python 3.9+（打包脚本用其标准库 `zipfile`，无需额外 `zip` 二进制；pip3 仅本地开发用）
- obsutil（用于上传函数代码到 OBS）：https://support.huaweicloud.com/utiltg-obs/obs_11_0001.html
- 配置访问凭证（**仅用环境变量，禁止写入任何文件**）：
```bash
export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
export HW_SECRET_KEY="<HW_SECRET_KEY>"
# 临时凭证场景再加：export HW_SECURITY_TOKEN="<TOKEN>"
export HW_REGION_NAME="cn-north-4"
```
- 修改 `infra/variables.tf` 中的 `store_bucket_name` 为**全局唯一**的桶名。

## 2. 快速开始

```bash
# 1) 初始化 Terraform（自动拉取 huaweicloud provider）
cd infra
terraform init

# 2) 预览将创建的资源
terraform plan

# 3) 打包并上传函数代码到 OBS（见第 3 步）

# 4) 应用（创建 OBS 桶 / 委托 / 函数 / CTS 触发器）
terraform apply
```

> 建议在 `terraform plan` 输出中核对资源清单是否符合预期。

## 3. 打包并上传函数代码

FGS Python3.9 运行时**已内置** `esdk-obs-python`（`import obs` 即用），**zip 只需放 index.py**
严禁用 `pip install --target` 把 obs/cryptography 打进去（Windows .pyd 会让 FGS Linux 加载失败）；
代码仍经 OBS 托管（`code_type=obs`）。

> ⚠️ **必须在 `terraform apply` 之前完成上传**：函数 `code_url` 指向本存储桶的
> `function-code/*.zip`，若 zip 不存在，apply 会失败或函数挂载空代码（日志全空、执行失败）。

```bash
cd ../src/functions
STORE_BUCKET=<你的存储桶名> ./build.sh upload
# 或仅打包： ./build.sh （生成 register.zip / restore.zip，再手动用 obsutil 上传）
```

上传路径需与 `infra/main.tf` 中 `code_url` 一致：`function-code/register.zip`、`function-code/restore.zip`。

## 4. 验证

应用成功后，做端到端验证：

```bash
# (a) 给某个测试桶设置一条桶策略，观察是否被自动记录
obsutil put-bucket-policy obs://<测试桶> -policy=<policy.json>

# (b) 列出存储桶中的策略快照
obsutil ls obs://<STORE_BUCKET>/policies/ -s

# (c) 手动调用 restore 函数还原（事件体 {"BucketPolicyHash":"<上一步的 md5>"}）
# 控制台「函数 → restore → 测试」粘贴该 JSON，或用 FunctionGraph SDK 同步调用
```

预期：`policies/` 下出现 `<hash>.json`；restore 调用返回
`{"message":"桶策略已还原: <hash> -> <桶名>", ...}`。

> 凭据与临时凭证：函数运行期通过 `context` 获取临时 AK/SK，无需在代码里写任何密钥。

## 5. 区域与触发器注意事项

- **事件链路（已端到端验证可用）**：`register` 函数走 `CTS 关键事件通知 → SMN → FunctionGraph(SMN 触发器)`
桥接（OBS 是全局服务，CTS 直连 FGS 触发器不可靠，故不采用）。`register` 函数内按
`trace_name == "setBucketPolicy"` 过滤事件，并兼容 `event["cts"]` 与 SMN 信封
`event["record"][0]["smn"]["message"]` 两种形态（见 index.py 的 `_extract_cts`）。
- 若 `register` 未随 PutBucketPolicy 触发，按序排查：
1. SMN 主题订阅是否「已确认」（`ListSubscriptions` 的 `status=1`）；
2. CTS 关键事件通知是否 `enabled=true`、操作类型含 `setBucketPolicy`；
3. `register` 函数是否绑定了 SMN 触发器（`huaweicloud_fgs_function_trigger` type=SMN）。
- **还原目标桶授权**：目标桶已存在桶策略时，需在其桶策略中加入对本委托主体的
`PutBucketPolicy`/`GetBucketPolicy` 允许语句，否则还原会被拒绝（403）。

## 6. 清理资源

```bash
cd infra
terraform destroy
# OBS 存储桶开启了多版本，destroy 前建议先清空所有版本与删除标记：
obsutil rm obs://<STORE_BUCKET> -r -f -allversions
```

