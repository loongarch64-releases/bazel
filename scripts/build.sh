#!/bin/bash
set -euo pipefail

ulimit -n 65536

UPSTREAM_OWNER=bazelbuild
UPSTREAM_REPO=bazel
VERSION="${1}"
echo "   🏢 Org:   ${UPSTREAM_OWNER}"
echo "   📦 Proj:  ${UPSTREAM_REPO}"
echo "   🏷️  Ver:   ${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DISTS="${ROOT_DIR}/dists"
SRCS="${ROOT_DIR}/srcs"
PATCHES="${ROOT_DIR}/patches"

mkdir -p "${DISTS}/${VERSION}" "${SRCS}"

# ==========================================
# 👇 用户自定义构建逻辑 (示例)
# ==========================================

echo "🔧 Compiling ${UPSTREAM_OWNER}/${UPSTREAM_REPO} ${VERSION}..."

# 1. 准备阶段：安装依赖、下载代码、应用补丁等
prepare()
{
    echo "📦 [Prepare] Setting up build environment..."
    
    wget -O "${SRCS}/${VERSION}.zip" --quiet --show-progress "https://github.com/bazelbuild/bazel/releases/download/${VERSION}/bazel-${VERSION}-dist.zip"
    [ -d "${SRCS}/${VERSION}" ] && rm -rf "${SRCS}/${VERSION}"
    mkdir -p "${SRCS}/${VERSION}"
    unzip -q "${SRCS}/${VERSION}.zip" -d "${SRCS}/${VERSION}"

    "${PATCHES}/patch.sh" "${SRCS}/${VERSION}" "${VERSION}"

    echo "✅ [Prepare] Environment ready."
}

# 2. 编译阶段：核心构建命令
build()
{
    echo "🔨 [Build] Compiling source code..."
 
    pushd "${SRCS}/${VERSION}"
    export EXTRA_BAZEL_ARGS="--cpu=loongarch64 --host_cpu=loongarch64 \
                             --java_runtime_version=local_jdk \
                             --tool_java_runtime_version=local_jdk \
                             --extra_toolchains=@local_jdk//:runtime_toolchain_definition"
    ./compile.sh
    popd   

    echo "✅ [Build] Compilation finished."
}

# 3. 后处理阶段：整理产物、清理临时文件、验证版本
post_build()
{
    echo "📦 [Post-Build] Organizing artifacts..."

    cp "${SRCS}/${VERSION}/output/bazel" "${DISTS}/${VERSION}/bazel_nojdk-${VERSION}-linux-loongarch64"
    chown -R "${HOST_UID}:${HOST_GID}" "${DISTS}" "${SRCS}"

    echo "✅ [Post-Build] Artifacts ready in ./dists/${VERSION}."
}

# 主入口
main()
{
    prepare
    build
    post_build
}

main

# ==========================================
# 👆 自定义逻辑结束
# ==========================================

cat > "${DISTS}/${VERSION}/release.txt" <<EOF
Project: ${UPSTREAM_REPO}
Organization: ${UPSTREAM_OWNER}
Version: ${VERSION}
Build Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "✅ Compilation finished."
ls -lh "${DISTS}/${VERSION}"
