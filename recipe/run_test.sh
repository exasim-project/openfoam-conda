#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense

# 3-D regression test for the vectorisation defect described in
# conda-forge/openfoam-feedstock#8.
#
# conda-forge's only run-test is the pitzDaily tutorial, which is planar 2-D with empty
# front/back patches — precisely the class of case that is bit-for-bit immune to that
# defect. It passed on every affected build. This test is 3-D, so it does not.
#
# Method follows the issue report: run a laminar square duct to a developed state and
# take the least-squares slope of centre-line pressure over x in [9, 15]. For a square
# duct, Shah & London give f*Re_Dh = 56.908, hence
#
#     -dp/dx = 28.454 * nu * U / a^2 = 28.454 * 0.01 * 1 / 1 = 0.28454
#
# A correct build lands within a few per cent. The affected conda-forge builds report
# about 1.24x that value, so the tolerance below separates the two by a wide margin and
# does not need to be tight.

set -euo pipefail

TOL="${OPENFOAM_TEST_TOL:-0.08}"      # 8%; observed defect is ~24%
ANALYTIC="0.28454"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cp -r "${RECIPE_DIR}/test_case" "${work}/duct"
cd "${work}/duct"

echo "== blockMesh =="
blockMesh > blockMesh.log 2>&1 || { tail -40 blockMesh.log; exit 1; }

echo "== simpleFoam =="
simpleFoam > simpleFoam.log 2>&1 || { tail -60 simpleFoam.log; exit 1; }

# setFormat raw writes postProcessing/centreline/<time>/line_p.xy as "x p" columns.
sample="$(find postProcessing/centreline -name 'line_p.xy' | sort | tail -1)"
if [[ -z "${sample}" ]]; then
    echo "No sampled centre-line data was written." >&2
    find postProcessing -type f >&2 || true
    tail -40 simpleFoam.log >&2
    exit 1
fi

python3 - "${sample}" "${ANALYTIC}" "${TOL}" <<'PY'
import sys

path, analytic, tol = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

xs, ps = [], []
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        xs.append(float(parts[0]))
        ps.append(float(parts[1]))

if len(xs) < 5:
    raise SystemExit(f"Only {len(xs)} sample points in {path}; expected ~31")

n = len(xs)
mx = sum(xs) / n
mp = sum(ps) / n
sxx = sum((x - mx) ** 2 for x in xs)
sxp = sum((x - mx) * (p - mp) for x, p in zip(xs, ps))
slope = sxp / sxx
gradient = -slope                      # -dp/dx
ratio = gradient / analytic

print(f"  sampled points : {n}")
print(f"  -dp/dx         : {gradient:.6f}")
print(f"  analytic       : {analytic:.6f}")
print(f"  ratio          : {ratio:.4f}")

if abs(ratio - 1.0) > tol:
    raise SystemExit(
        f"FAIL: developed pressure gradient is {ratio:.3f}x the analytic value "
        f"(tolerance {tol:.0%}).\n"
        "A ratio near 1.24 is the signature of the vectorised in-place Foam::T() "
        "defect — check that the build did not append -O2/-ftree-vectorize over "
        "wmake's -O3. See conda-forge/openfoam-feedstock#8."
    )

print("PASS: 3-D duct pressure gradient matches the analytic value")
PY
