#!/usr/bin/env bash
# ============================================================================
# 打包 FunctionGraph 函数代码并上传到 OBS（供 code_type=obs 引用）
# ----------------------------------------------------------------------------
# ⚠️ 关键：FGS Python3.9 运行时【内置】esdk-obs-python，
#    函数里 `import obs` 即用。严禁用 `pip install --target` 把 obs / cryptography 打进
#    zip —— Windows 上会带入 .pyd 原生模块，FGS(Linux x86_64) 加载即
#    `module initialization error: Cannot load native module 'Crypto.Util._cpuid_c'`，
#    handler 永不执行、日志全空。故 zip 只放 index.py。
#
# 用 Python 的 zipfile 打包（不依赖外部 zip 二进制，Windows/Linux/macOS 通用，
# 且避免 Windows 原生 zip.exe 不认 /d/... 绝对路径的问题）。
#
# 用法：
#   ./build.sh            # 仅打包 register.zip / restore.zip（各仅含 index.py）
#   STORE_BUCKET=xxx ./build.sh upload   # 打包并上传到该桶的 function-code/ 前缀
# 依赖：python3（可用 PY=python 覆盖）；upload 模式还需 obsutil。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 转换为 Python(Windows 原生解释器) 能识别的路径：
# Git Bash 下 ROOT 是 /d/... 的 MSYS 路径，需 cygpath -w 转成 D:\...；
# Linux/macOS 无 cygpath，原样使用即可。
if command -v cygpath >/dev/null 2>&1; then
  ROOT_PY="$(cygpath -w "$ROOT")"
else
  ROOT_PY="$ROOT"
fi
PY="${PY:-python3}"

for fn in register restore; do
  echo "==> packaging $fn (index.py only, 依赖 FGS 内置 esdk-obs-python)"
  "$PY" - "$ROOT_PY" "$fn" <<'PYEOF'
import sys, os, zipfile
root, fn = os.path.normpath(sys.argv[1]), sys.argv[2]
src = os.path.join(root, fn, "index.py")
out = os.path.join(root, fn + ".zip")
if not os.path.isfile(src):
    sys.exit("找不到 %s" % src)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(src, "index.py")   # 仅压成 index.py（arcname 必须为 index.py，FGS handler=index.handler）
print("    ->", out)
PYEOF
done

if [ "${1:-}" = "upload" ]; then
  : "${STORE_BUCKET:?请设置 STORE_BUCKET 环境变量（存储桶名）}"
  for fn in register restore; do
    echo "==> upload $fn.zip -> obs://$STORE_BUCKET/function-code/$fn.zip"
    obsutil cp "$ROOT/$fn.zip" "obs://$STORE_BUCKET/function-code/$fn.zip"
  done
else
  echo ""
  echo "请将生成的 register.zip / restore.zip 上传到存储桶的 function-code/ 前缀："
  echo "  STORE_BUCKET=<桶名> ./build.sh upload"
  echo "  # 或手动： obsutil cp register.zip obs://<STORE_BUCKET>/function-code/register.zip"
  echo "  #           obsutil cp restore.zip  obs://<STORE_BUCKET>/function-code/restore.zip"
fi
