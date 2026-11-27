# -*- coding: utf-8 -*-
"""
register —— OBS 桶策略版本化（记录侧）
---------------------------------------------------------------------------
触发方式：FunctionGraph CTS 触发器（operations = ["OBS:bucket:setBucketPolicy"]）。
收到 CTS 事件后，把本次 PutBucketPolicy 的桶策略以 md5 哈希为键写入 OBS 存储桶，
实现「每次改桶策略都留痕、可追溯、可还原」。

实现说明：
  - 临时凭证只经 context 注入，必须在 handler 内构造客户端。
  - OBS 数据面不认 IAM/委托凭证，需在存储桶策略中显式授权。
"""
import json
import hashlib
import os
import logging
import time

import obs  # esdk-obs-python

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# OBS 策略快照对象前缀
POLICY_PREFIX = "policies"

# 诊断探针前缀：每次被触发都把原始事件落盘，便于确认触发器是否投递 / 事件结构
PROBE_KEY = "policies/_probe.json"


def get_obs_client(context, region):
    """从 FunctionGraph context 取临时凭证，构造 OBS 客户端。"""
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


def _coerce(value):
    """CTS 的 request 字段可能是 dict，也可能是 JSON 字符串，统一成 dict。"""
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return {}
    return value or {}


def _extract_cts(event):
    """从事件中抽取 CTS 记录，兼容三种触发器来源：
    - 直连 CTS 触发器：event["cts"] = {...}
    - CTS 关键操作通知经 SMN 桥接：event["record"][0]["smn"]["message"] = CTS 记录 JSON 字符串
    - 直接 SMN 发布测试：event["message"] = CTS 记录 JSON 字符串
    """
    if "cts" in event:
        return event["cts"]
    # CTS 通知经 SMN 投递的包结构：{ "record": [ { "smn": { "message": "<CTS记录JSON>" } } ] }
    if "record" in event:
        try:
            rec0 = event["record"][0]
            inner = rec0.get("smn", {}).get("message")
            if isinstance(inner, str):
                return json.loads(inner)
            return inner or event
        except (KeyError, IndexError, TypeError, ValueError):
            return event
    if "message" in event:
        try:
            inner = json.loads(event["message"])
            return inner.get("cts", inner)
        except (ValueError, TypeError):
            return event
    return event


def _read_body(body):
    """esdk getBucketPolicy 返回可能是字符串或流，统一成字符串。"""
    if body is None:
        return None
    if hasattr(body, "read"):
        body = body.read()
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    return body


def handler(event, context):
    region = os.environ.get("REGION")
    store_bucket = os.environ.get("STORE_BUCKET")

    # 诊断探针：先把原始事件写盘，确认触发器是否真的投递了事件、以及事件真实结构。
    try:
        client0 = get_obs_client(context, region)
        probe = {
            "invoked_at": int(time.time() * 1000),
            "raw_event": event,
        }
        client0.putContent(
            store_bucket,
            PROBE_KEY,
            json.dumps(probe, ensure_ascii=False, default=str).encode("utf-8"),
        )
    except Exception as e:  # 探针失败不应阻断主逻辑
        logger.warning("probe write failed: %s", e)

    client = get_obs_client(context, region)
    cts = _extract_cts(event)
    trace_name = cts.get("trace_name")

    # 兜底过滤：仅处理桶策略设置事件。
    # 注意：CTS 记录该操作的事件名 trace_name = "setBucketPolicy"（非 OBS API 名 PutBucketPolicy），
    # 同时兼容 "PutBucketPolicy" 以防不同 CTS 命名差异。
    if trace_name not in ("setBucketPolicy", "PutBucketPolicy"):
        logger.info("忽略非桶策略设置事件: %s", trace_name)
        return {"status": "ignored", "trace_name": trace_name}

    request = _coerce(cts.get("request", {}))
    bucket_name = (request.get("bucket_name") or request.get("bucketName")
                   or cts.get("resource_name") or cts.get("resource_id"))
    # CTS 对 OBS setBucketPolicy 的成功记录里，策略正文在 BucketPolicy 字段
    # （policy 字段恒为空串）；失败记录（NoSuchBucket）两者皆空，靠下方兜底读 OBS。
    bucket_policy = (request.get("bucket_policy") or request.get("bucketPolicy")
                     or request.get("BucketPolicy") or request.get("policy"))

    # 兜底：CTS 事件的 request 里不一定带策略正文，则直接读桶的当前策略。
    if not bucket_policy and bucket_name:
        try:
            gp = client.getBucketPolicy(bucket_name)
            logger.info("getBucketPolicy status=%s", gp.status)
            bucket_policy = _read_body(getattr(gp, "body", None))
        except Exception as e:
            logger.warning("getBucketPolicy 兜底失败: %s", e)

    if not bucket_name or not bucket_policy:
        raise Exception(
            "CTS request 中缺少 bucket_name 或 bucket_policy（原始事件已写入 %s）" % PROBE_KEY
        )

    # 桶策略统一成字符串，便于 md5 与落盘
    policy_str = bucket_policy if isinstance(bucket_policy, str) else json.dumps(bucket_policy, ensure_ascii=False)
    hash_code = hashlib.md5(policy_str.encode("utf-8")).hexdigest()

    record = {
        "bucket_name": bucket_name,
        "timestamp": cts.get("time"),
        "user_identity": json.dumps(cts.get("user", {}), ensure_ascii=False),
        "bucket_policy": policy_str,
        "bucket_policy_hash": hash_code,
    }

    key = "{}/{}.json".format(POLICY_PREFIX, hash_code)
    resp = client.putContent(store_bucket, key, json.dumps(record, ensure_ascii=False).encode("utf-8"))

    if resp.status >= 300:
        raise Exception("写入 OBS 快照失败: HTTP {}".format(resp.status))

    logger.info("已记录桶 %s 的策略快照, hash=%s", bucket_name, hash_code)
    return {
        "status": "recorded",
        "bucket_name": bucket_name,
        "bucket_policy_hash": hash_code,
    }
