#!/bin/bash

src="$1"
version="$2"
major_ver=$(echo "$version" | cut -d. -f1)
minor_ver=$(echo "$version" | cut -d. -f2)
patch_ver=$(echo "$version" | cut -d. -f3)
ver_num=$(( 10#${major_ver} * 1000000 + 10#${minor_ver} * 1000 + 10#${patch_ver} ))


# 源码适配
src_adaption()
{
    cat << 'EOF' >> ${src}/src/conditions/BUILD.tools
config_setting(
    name = "linux_loongarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:loongarch64",
    ],
    visibility = ["//visibility:public"],
)
EOF

    cat << 'EOF' >> ${src}/src/conditions/BUILD
config_setting(
    name = "linux_loongarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:loongarch64",
    ],
    visibility = ["//visibility:public"],
)
EOF

    sed -i '/RISCV64("riscv64"/a \
  LOONGARCH64("loongarch64", ImmutableSet.of("loong64", "loongarch64")),' "${src}/src/main/java/com/google/devtools/build/lib/util/CPU.java"
    
    if [ "${ver_num}" -ge 8000000 ]; then
        sed -i '/link_children "${PWD}" tools "${BAZEL_TOOLS_REPO}"/a \
  mv -f ${BAZEL_TOOLS_REPO}/tools/BUILD.tools ${BAZEL_TOOLS_REPO}/tools/BUILD' "${src}/scripts/bootstrap/compile.sh"
    fi

    local AutoCpuConverter="${src}/src/main/java/com/google/devtools/build/lib/analysis/config/AutoCpuConverter.java"
    if [ "${ver_num}" -lt 8000000 ]; then
        sed -i '/return "riscv64";/a \
            case LOONGARCH64:\
              return "loongarch64";' ${AutoCpuConverter}
    else
        sed -i '/case RISCV64 -> "riscv64";/a \
              case LOONGARCH64 -> "loongarch64";' ${AutoCpuConverter}
    fi

    # 8.0.0 之后c++配置逻辑通过三方库管理
    if [ "${ver_num}" -lt 8000000 ]; then
        sed -i '/return "riscv64"/a \
    if arch in ["loong64", "loongarch64"]:\
        return "loongarch64"' "${src}/tools/cpp/lib_cc_configure.bzl"
    fi

    # 较旧版本适应较新GCC
    if [ "${ver_num}" -lt 8005000 ]; then
        sed -i '/namespace blaze {/i \
#include <cstdint>' "${src}/src/main/cpp/archive_utils.h"
        sed -i '/namespace blaze {/i \
#include <cstdint>' "${src}/src/main/cpp/blaze.h"
    fi
}


# 三方库适配
dep_adaption()
{
    local deps=("platforms" "rules_go" "rules_java")
    if [ "${ver_num}" -ge 8000000 ]; then
        deps+=("rules_cc")
    fi

    for dep in "${deps[@]}"; do
        # 待补丁三方库的版本
        DEP_VER=$(sed -n '/name = "'${dep}'"/ s/.*version = "\([^"]*\)".*/\1/p' ${src}/MODULE.bazel)
        
        # 三方库源码
        [ -d "/tmp/${dep}" ] && rm -rf "/tmp/${dep}"
        mkdir -p "/tmp/${dep}"
        if [ "${dep}" = "rules_go" ]; then
            DEP_URL="https://github.com/bazel-contrib/${dep}/releases/download/v${DEP_VER}/rules_go-v${DEP_VER}.zip"
            wget -O "/tmp/${dep}.zip" --quiet --show-progress ${DEP_URL}
            unzip -q "/tmp/${dep}.zip" -d "/tmp/${dep}"
        else
            DEP_URL="https://github.com/bazelbuild/${dep}/releases/download/${DEP_VER}/${dep}-${DEP_VER}.tar.gz"
            wget -O "/tmp/${dep}.tar.gz" --quiet --show-progress ${DEP_URL}
            strip_param=""
            [ "${dep}" = "rules_cc" ] && strip_param="--strip-components=1"
            
            tar -xzf "/tmp/${dep}.tar.gz" -C "/tmp/${dep}" ${strip_param}
        fi

        pushd "/tmp/${dep}"
        git init && git add .
        
        # 适配三方库
        # === platforms ===
        if [ "${dep}" = "platforms" ]; then
	    local platform_v="${DEP_VER}"
            sed -i '/return "riscv64"/a \
    if arch in ["loongarch64"]:\
        return "loongarch64"' host/extension.bzl

            cat << 'EOF' >> cpu/BUILD
alias(
    name = "loong64",
    actual = ":loongarch64",
)
constraint_value(
    name = "loongarch64",
    constraint_setting = ":cpu",
)
EOF

        # === rules_go ===
        elif [ "${dep}" = "rules_go" ]; then
	    local rules_go_v="${DEP_VER}"
            sed -i '/BAZEL_GOARCH_CONSTRAINTS = {/a \
    "loong64": "@platforms//cpu:loongarch64",' go/private/platforms.bzl
            sed -i '/("linux", "riscv64"),/a \
    ("linux", "loong64"),' go/private/platforms.bzl
            sed -i '/("linux", "riscv64"): None,/a \
    ("linux", "loong64"): None,' go/private/platforms.bzl
	    sed -i '/goarch = "amd64"/a \
    elif goarch == "loongarch64":\
        goarch = "loong64"' go/private/sdk.bzl

        # === rules_java ===
        elif [ "${dep}" = "rules_java" ]; then
	    local rules_java_v="${DEP_VER}"
            sed -i '/linux_riscv64": \[":jni_md_header-linux"\],/a \
        "@bazel_tools//src/conditions:linux_loongarch64": \[":jni_md_header-linux"\],' toolchains/BUILD
            sed -i '/linux_aarch64": \["include\/linux"\],/a \
        "@bazel_tools//src/conditions:linux_loongarch64": \["include/linux"\],' toolchains/BUILD
             
        # === rules_cc ===
        elif [ "${dep}" = "rules_cc" ]; then
	    local rules_cc_v="${DEP_VER}"
            sed -i '/return "riscv64"/a \
    if arch in ["loong64", "loongarch64"]:\
        return "loongarch64"' cc/private/toolchain/lib_cc_configure.bzl

        fi

        # 制作 patch 文件
        git diff > "${src}/third_party/${dep}_${DEP_VER}.patch"

        popd
        echo "Patch generated for ${dep} (${DEP_VER})"
    done

    # 应用 patch
    apply_dep_patch "${platform_v}" "${rules_go_v}" "${rules_java_v}" "${rules_cc_v}"
}


# 应用三方库补丁
apply_dep_patch()
{
    local PLATFORMS_VER="${1}"
    local RULES_GO_VER="${2}"
    local RULES_JAVA_VER="${3}"
    local RULES_CC_VER="${4}"

    # 9.0.0 开始会自动包含 third_party 中所有的 .patch 文件，但此前的版本需要显式包含
    if [ "${ver_num}" -lt 9000000 ]; then
        sed -i '/third_party:BUILD",/a \
        "//third_party:platforms_'${PLATFORMS_VER}'.patch",\
        "//third_party:rules_go_'${RULES_GO_VER}'.patch",\
        "//third_party:rules_java_'${RULES_JAVA_VER}'.patch",' "${src}/BUILD"
    fi

    # 应用
    cat << EOF >> ${src}/MODULE.bazel
single_version_override(
    module_name = "platforms",
    patch_strip = 1,
    patches = ["//third_party:platforms_${PLATFORMS_VER}.patch"],
)
single_version_override(
    module_name = "rules_java",
    patch_strip = 1,
    patches = ["//third_party:rules_java_${RULES_JAVA_VER}.patch"],
)
single_version_override(
    module_name = "rules_go",
    patch_strip = 1,
    patches = ["//third_party:rules_go_${RULES_GO_VER}.patch"],
)
EOF

    if [ "${ver_num}" -ge 8000000 ]; then
    cat << EOF >> ${src}/MODULE.bazel
single_version_override(
    module_name = "rules_cc",
    patch_strip = 1,
    patches = ["//third_party:rules_cc_${RULES_CC_VER}.patch"],
)
EOF
    fi
}

main()
{
    src_adaption
    dep_adaption
}

main

