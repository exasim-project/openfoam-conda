#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense

# Build the OpenFOAM conda package for one version and one target platform.
#
# Usage:
#   ci/build_conda_packages.sh --openfoam-version 2506 [--target-platform linux-64]
#                              [--output-dir output] [--] [extra rattler-build arguments]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

openfoam_version="2506"
output_dir="${repo_root}/output"
target_platform=""
# 2.17 is the widest baseline conda-forge still ships a sysroot for; macOS uses the
# deployment target instead.
glibc_version="2.17"
macos_deployment_target="12.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --openfoam-version) openfoam_version="$2"; shift 2 ;;
        --output-dir) output_dir="$2"; shift 2 ;;
        --target-platform) target_platform="$2"; shift 2 ;;
        --glibc-version) glibc_version="$2"; shift 2 ;;
        --macos-deployment-target) macos_deployment_target="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Checksums of the SourceForge tarballs. develop.openfoam.com is not usable from CI:
# both its archive and raw-file endpoints require authentication and serve an HTML
# sign-in page to anonymous clients, with HTTP 200.
case "${openfoam_version}" in
    2506) openfoam_sha256="63d26f48ae7ee9a7806a0ceb339ef8a0ba485a4714d54fbfb31e78e1a4849965" ;;
    2512) openfoam_sha256="ae9a0a133a2e996b88bd1d0f3cc229e3c49968c368feae61bd3ec63deaf337aa" ;;
    2606) openfoam_sha256="2a1310e3ed192cc4c521e1d22dcc176f57bec61160c878dc4348f21d6672294d" ;;
    *)
        echo "Unknown OpenFOAM version '${openfoam_version}'." >&2
        echo "Supported: 2506, 2512, 2606. To add one, download" >&2
        echo "  https://sourceforge.net/projects/openfoam/files/v<ver>/OpenFOAM-v<ver>.tgz/download" >&2
        echo "and record its sha256 here." >&2
        exit 1
        ;;
esac

if [[ -z "${target_platform}" ]]; then
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64) target_platform="linux-64" ;;
        Darwin/arm64) target_platform="osx-arm64" ;;
        *) echo "Cannot infer the target platform on $(uname -s)/$(uname -m)" >&2; exit 1 ;;
    esac
fi

case "${target_platform}" in
    linux-64 | osx-arm64) ;;
    *)
        echo "Unsupported target platform '${target_platform}'." >&2
        echo "This repository builds linux-64 and osx-arm64." >&2
        exit 1
        ;;
esac

echo "Building openfoam ${openfoam_version} for ${target_platform}" >&2

variant_file="$(mktemp -t openfoam-variant.XXXXXX)"
trap 'rm -f "${variant_file}"' EXIT

{
    echo "openfoam_version:"
    echo "  - \"${openfoam_version}\""
    echo "openfoam_sha256:"
    echo "  - \"${openfoam_sha256}\""

    # ${{ stdlib('c') }} has no built-in default; name the C runtime floor per platform.
    case "${target_platform}" in
        osx-*)
            echo "c_stdlib:"
            echo "  - macosx_deployment_target"
            echo "c_stdlib_version:"
            echo "  - \"${macos_deployment_target}\""
            echo "MACOSX_DEPLOYMENT_TARGET:"
            echo "  - \"${macos_deployment_target}\""
            ;;
        *)
            echo "c_stdlib:"
            echo "  - sysroot"
            echo "c_stdlib_version:"
            echo "  - \"${glibc_version}\""
            ;;
    esac
} > "${variant_file}"

{
    echo "--- variant configuration ---"
    cat "${variant_file}"
    echo "-----------------------------"
} >&2

rattler_build="${RATTLER_BUILD:-rattler-build}"

"${rattler_build}" build \
    --recipe "${repo_root}/recipe/recipe.yaml" \
    --variant-config "${variant_file}" \
    --output-dir "${output_dir}" \
    --target-platform "${target_platform}" \
    --channel conda-forge \
    "$@"
