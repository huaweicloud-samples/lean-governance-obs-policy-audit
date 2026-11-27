# -*- coding: utf-8 -*-
"""
restore —— OBS 桶策略版本化（还原侧）
---------------------------------------------------------------------------
调用方式：手动调用 / API / SDK，传入 {"BucketPolicyHash": "<哈希>"}。
凭哈希从 OBS 存储桶取出历史桶策略快照，校验完整性后调用 SetBucketPolicy 还原到目标桶。

注意：还原目标桶的 SetBucketPolicy 走 OBS 控制面，由委托的 OBS Administrator
          IAM 权限授权；若目标桶已存在桶策略且该策略未授予本委托 PutBucketPolicy，
          需先在目标桶策略中加入对
          "domain/<domain_id>:agency/<agency_name>" 的 PutBucketPolicy/GetBucketPolicy 允许语句。
"""
import json
import hashlib
import os
import logging

import obs  # esdk-obs-python

logger = logging.getLogger()
logger.setLevel(logging.INFO)

POLICY_PREFIX = "policies"


def get_obs_client(context, region):
    ak = context.getSecurityAccessKey()
    sk = context.getSecuritySecretKey()
    token = context.getSecurityToken()
    if not ak or not sk:
        raise RuntimeError("未取到委托临时凭证，请确认函数已绑定 FunctionGraph 委托")
    server = "https://obs.{}.myhuaweicloud.com".format(region)
    return obs.ObsClient(
        access_key_id=ak,
        secret_access_key=sk,
        security_token=token,
        server=server,
    )


def handler(event, context):
    region = os.environ.get("REGION")
    store_bucket = os.environ.get("STORE_BUCKET")

    hash_code = (event or {}).get("BucketPolicyHash")
    if not hash_code:
        raise Exception("请提供事件 {\"BucketPolicyHash\": \"<哈希>\"}")

    hash_code = hash_code.strip()
    client = get_obs_client(context, region)
    key = "{}/{}.json".format(POLICY_PREFIX, hash_code)

    resp = client.getObject(store_bucket, key, loadStream=True)
    if resp.status >= 300:
        raise Exception("在 OBS 快照中未找到哈希 {}（桶 {}）".format(hash_code, store_bucket))

    # esdk-obs-python: loadStream=True 时 resp.body.buffer 为 BytesIO
    raw = resp.body.buffer.read().decode("utf-8")
    record = json.loads(raw)

    policy_str = record["bucket_policy"]
    bucket_name = record["bucket_name"]

    # 完整性校验：重新计算哈希，防止快照被篡改/损坏
    if hashlib.md5(policy_str.encode("utf-8")).hexdigest() != hash_code:
        raise Exception("给定哈希对应的桶策略已损坏或不一致")

    logger.info("还原桶 %s 的策略, hash=%s", bucket_name, hash_code)
    put_resp = client.setBucketPolicy(bucket_name, policy_str)
    if put_resp.status >= 300:
        raise Exception("SetBucketPolicy 失败: HTTP {}".format(put_resp.status))

    return {
        "message": "桶策略已还原: {} -> {}".format(hash_code, bucket_name),
        "bucket_name": bucket_name,
    }
