#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense

set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. Optimisation flags — the reason this package exists.
#
# conda-forge's openfoam appends conda's default $CXXFLAGS after wmake's own flags.
# Those defaults carry `-O2 -ftree-vectorize`, so the effective level drops to -O2 with
# the vectoriser's "cheap" cost model explicitly enabled. Under that model GCC
# vectorises OpenFOAM's field transpose Foam::T() with no runtime overlap check — which
# it is entitled to do, because OpenFOAM marks its list storage __restrict__ — but
# OpenFOAM performs that transpose IN PLACE for reusable temporaries, as in
# dev2(T(fvc::grad(U))) inside every turbulence model's divDevReff. The no-alias promise
# is false, and the explicit part of the viscous stress is silently corrupted: ~25% wrong
# pressure gradients in 3-D and axisymmetric cases, while the solver converges normally.
# See conda-forge/openfoam-feedstock#8, and upstream OpenFOAM issue #3166 / commit
# b5aa32f0, whose fix has never been merged (it is still absent in v2606).
#
# So: strip the optimisation and vectorisation flags out of the conda defaults and let
# wmake's -O3 stand, which is what ESI's own binaries use and what the feedstock issue
# confirms produces correct results.
# ---------------------------------------------------------------------------
scrub_flags() {
    # shellcheck disable=SC2001
    echo "$1" | sed -E 's/(^| )-O[0-9s]*( |$)/ /g; s/(^| )-ftree-vectorize( |$)/ /g; s/  +/ /g'
}

export CFLAGS="$(scrub_flags "${CFLAGS:-}")"
export CXXFLAGS="$(scrub_flags "${CXXFLAGS:-}")"
echo "Scrubbed CFLAGS  : ${CFLAGS}"
echo "Scrubbed CXXFLAGS: ${CXXFLAGS}"

FOAM_DIR_NAME="OpenFOAM-v${PKG_VERSION}"
cd "${SRC_DIR}/${FOAM_DIR_NAME}" 2>/dev/null || cd "${SRC_DIR}"

# ---------------------------------------------------------------------------
# 2. Point OpenFOAM's own config at the conda prefix, as conda-forge does.
# ---------------------------------------------------------------------------
CONFIGSHDIR="etc/config.sh"
sed -i.bak 's|\$WM_PROJECT_DIR/platforms/\$WM_OPTIONS|${PREFIX}|g' "${CONFIGSHDIR}/settings"
for dep in scotch zoltan kahip metis petsc hypre FFTW; do
    [[ -f "${CONFIGSHDIR}/${dep}" ]] || continue
    sed -i.bak -E "s|^export [A-Z]+_ARCH_PATH=.*|export $(echo "${dep}" | tr '[:lower:]' '[:upper:]')_ARCH_PATH=${PREFIX}|" \
        "${CONFIGSHDIR}/${dep}" || true
done
if [[ -f "${CONFIGSHDIR}/CGAL" ]]; then
    sed -i.bak "s|^export BOOST_ARCH_PATH=.*|export BOOST_ARCH_PATH=${PREFIX}|" "${CONFIGSHDIR}/CGAL"
    sed -i.bak "s|^export CGAL_ARCH_PATH=.*|export CGAL_ARCH_PATH=${PREFIX}|" "${CONFIGSHDIR}/CGAL"
fi
find etc -name '*.bak' -delete

# setSet's Allwmake needs readline; drop it as conda-forge does.
rm -f applications/utilities/mesh/manipulation/setSet/Allwmake

# ---------------------------------------------------------------------------
# 3. Build.
# ---------------------------------------------------------------------------
# OpenFOAM's etc/bashrc reads variables before assigning them (v2512 and v2606 fail on
# "WM_PROJECT_DIR: unbound variable" at line 184), so it cannot be sourced under `set -u`.
# Drop nounset across the source only.
#
# WM_MPLIB is pinned rather than left to the bashrc's own detection, which picks
# SYSTEMOPENMPI: the recipe depends on mpich, so an openmpi-flavoured Pstream would link
# against an MPI the package does not ship. SYSTEMMPI takes the implementation from
# MPI_ARCH_PATH, which is the conda prefix.
export WM_MPLIB=SYSTEMMPI
export MPI_ARCH_PATH="${PREFIX}"

set +u
# shellcheck disable=SC1091
source etc/bashrc || true
set -u

# The bashrc derives FOAM_MPI from WM_MPLIB; capture it so the activation script and the
# rpaths below name the same directory rather than a guessed one.
: "${FOAM_MPI:?etc/bashrc did not set FOAM_MPI}"
echo "Building with WM_MPLIB=${WM_MPLIB}, FOAM_MPI=${FOAM_MPI}"

./Allwmake -j "${CPU_COUNT}" -q -l

# ---------------------------------------------------------------------------
# 4. Install.
#
# Unlike conda-forge, ship the COMPLETE src/ and applications/ trees rather than only
# the lnInclude directories copied into include/. Three reasons:
#   * FOAM_SRC=$PREFIX/src then names a directory that exists. conda-forge exports that
#     path while installing headers to include/OpenFOAM-<version>/src, so every
#     downstream build has to guess.
#   * FOAM_APP / FOAM_SOLVERS / FOAM_UTILITIES likewise.
#   * Projects that compile OpenFOAM application sources — pybFoam's meshing module
#     compiles five files from applications/utilities/mesh/manipulation/checkMesh —
#     cannot work at all without the applications tree.
# The cost is package size. Splitting into openfoam / openfoam-src outputs is the
# obvious follow-up if that becomes a problem.
# ---------------------------------------------------------------------------
echo "Installing ..."
cp -r etc "${PREFIX}"
cp -r bin "${PREFIX}"
cp -r wmake "${PREFIX}"
cp -r platforms "${PREFIX}"
cp -r tutorials "${PREFIX}"
cp -r src "${PREFIX}"
cp -r applications "${PREFIX}"

# wmake scripts resolve their own directory; re-point at the installed tree.
sed -i.bak 's|\${0%\/\*}|${WM_PROJECT_DIR:?}/wmake|g' wmake/w* || true
cp wmake/w* "${PREFIX}/bin"
find "${PREFIX}/bin" -name '*.bak' -delete

# Activation scripts.
ACTIVATE_DIR="${PREFIX}/etc/conda/activate.d"
DEACTIVATE_DIR="${PREFIX}/etc/conda/deactivate.d"
mkdir -p "${ACTIVATE_DIR}" "${DEACTIVATE_DIR}"
sed -e "s|@OPENFOAM_API@|${PKG_VERSION}|g" \
    -e "s|@FOAM_MPI@|${FOAM_MPI}|g" \
    "${RECIPE_DIR}/activate.sh" > "${ACTIVATE_DIR}/openfoam_activate.sh"
cp "${RECIPE_DIR}/deactivate.sh" "${DEACTIVATE_DIR}/openfoam_deactivate.sh"

# ---------------------------------------------------------------------------
# 5. Post-install assertions. Each of these is a bug we have actually been bitten by
#    downstream, so fail here rather than in someone else's build.
# ---------------------------------------------------------------------------
test -d "${PREFIX}/src/OpenFOAM/lnInclude"
test -d "${PREFIX}/src/Pstream/mpi/lnInclude"
test -f "${PREFIX}/applications/utilities/mesh/manipulation/checkMesh/checkGeometry.C"
