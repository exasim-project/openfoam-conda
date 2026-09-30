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

# Skip foamyMesh (the CGAL-based foamyHexMesh / foamyQuadMesh). It fails to link with
# hundreds of undefined __gmpz_* references, and because generation/Allwmake ends with
#     foamyMesh/Allwmake $targetType $*
# its exit status becomes that script's — which aborted the entire applications build. Every
# solver, simpleFoam included, was then silently never attempted, while blockMesh (built
# earlier in the same directory) succeeded and masked it.
#
# Stubbed rather than deleted: that call is unconditional, so a missing file fails just the
# same. Nothing in NeoFOAM's stack uses foamyMesh; reinstating it needs gmp on the link
# line, not merely cgal in the host environment.
_foamy="applications/utilities/mesh/generation/foamyMesh/Allwmake"
if [[ -f "${_foamy}" ]]; then
    printf '#!/bin/sh\necho "foamyMesh: skipped by the conda recipe"\nexit 0\n' > "${_foamy}"
    chmod +x "${_foamy}"
fi

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
# WM_MPLIB must be passed as a bashrc ARGUMENT, not exported beforehand: etc/bashrc
# assigns it unconditionally, so an earlier export is silently overwritten. Leaving it at
# the default SYSTEMOPENMPI made every build fail with "mpi.h: No such file or directory",
# since the recipe depends on mpich. SYSTEMMPI takes the implementation from
# MPI_ARCH_PATH.
# SYSTEMMPI does NOT derive its compile flags from MPI_ARCH_PATH. etc/config.sh/mpi reads
# MPI_ARCH_PATH while it is being sourced, and wmake/rules/General/mplibSYSTEMMPI uses
# MPI_ARCH_FLAGS / MPI_ARCH_INC / MPI_ARCH_LIBS verbatim:
#
#   PFLAGS = $(MPI_ARCH_FLAGS)
#   PINC   = $(MPI_ARCH_INC)
#   PLIBS  = $(MPI_ARCH_LIBS)
#
# OpenFOAM only prints a warning when they are unset, so an empty PINC shows up much later
# as "mpi.h: No such file or directory". All four must therefore be exported BEFORE the
# bashrc is sourced.
export MPI_ARCH_PATH="${PREFIX}"
export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"
export MPI_ARCH_INC="-isystem ${PREFIX}/include"
export MPI_ARCH_LIBS="-L${PREFIX}/lib -lmpi"

# errexit is disabled explicitly rather than relying on `|| true`. OpenFOAM's bashrc ends
# in a helper that returns 1 (_foamAddLibAuto with an empty argument), and on the macOS
# runners — bash 3.2, whose errexit handling inside a `||` list is unreliable — that killed
# the script even though the source was guarded. Linux (bash 5) was unaffected.
set +u
set +e
# shellcheck disable=SC1091
source etc/bashrc WM_MPLIB=SYSTEMMPI
_bashrc_status=$?
set -e
set -u
echo "etc/bashrc returned ${_bashrc_status} (non-zero is normal here)"

# The bashrc unsets MPI_ARCH_PATH in its cleanup, so re-export all four afterwards as well:
# wmake reads MPI_ARCH_INC / MPI_ARCH_FLAGS / MPI_ARCH_LIBS when it compiles, and referring
# to MPI_ARCH_PATH below would otherwise abort under `set -u`.
export MPI_ARCH_PATH="${PREFIX}"
export MPI_ARCH_FLAGS="-DMPICH_SKIP_MPICXX"
export MPI_ARCH_INC="-isystem ${PREFIX}/include"
export MPI_ARCH_LIBS="-L${PREFIX}/lib -lmpi"

# wmake builds its own compile lines from wmake/rules and ignores CFLAGS/CXXFLAGS entirely.
# The only supported injection point is FOAM_EXTRA_*, and etc/bashrc explicitly unsets those
# ("unset FOAM_EXTRA_CFLAGS FOAM_EXTRA_CXXFLAGS FOAM_EXTRA_LDFLAGS"), so they have to be set
# AFTER sourcing. Without them nothing conda provides is on the include path, and the build
# dies on "FlexLexer.h: No such file or directory" once it reaches src/fileFormats.
#
# This is also, precisely, how conda-forge's package became wrong: it injects the UNSCRUBBED
# conda flags here, so -O2 -ftree-vectorize lands after wmake's -O3. We inject the scrubbed
# ones, which keeps the include paths while leaving the optimisation level alone.
export FOAM_EXTRA_CFLAGS="${CFLAGS}"
export FOAM_EXTRA_CXXFLAGS="${CXXFLAGS}"
export FOAM_EXTRA_LDFLAGS="${LDFLAGS:-}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    # Do NOT hand conda's compiler flags to the macOS build. OpenFOAM's darwin rules compile
    # with /usr/bin/clang++ — Xcode's clang, using Xcode's SDK and its own libc++ — whereas
    # conda's CXXFLAGS (-stdlib=libc++ plus conda's include directories) are written for
    # conda's clang. Mixing them breaks libc++'s #include_next resolution:
    #   <cwchar> tried including <wchar.h> but didn't find libc++'s <wchar.h> header
    # and every std::string-dependent OpenFOAM typedef collapses after it. Reordering with
    # -idirafter was not enough; the conflicting flags have to go entirely.
    #
    # Keep only what OpenFOAM genuinely needs from the conda prefix: headers for flex and
    # friends, discoverable AFTER the SDK, and the library path.
    export FOAM_EXTRA_CFLAGS="-idirafter ${PREFIX}/include"
    export FOAM_EXTRA_CXXFLAGS="-idirafter ${PREFIX}/include"
    export FOAM_EXTRA_LDFLAGS="-L${PREFIX}/lib"
fi

echo "FOAM_EXTRA_CXXFLAGS=${FOAM_EXTRA_CXXFLAGS}"

: "${FOAM_MPI:?etc/bashrc did not set FOAM_MPI}"
echo "Building with WM_MPLIB=${WM_MPLIB}, FOAM_MPI=${FOAM_MPI}, MPI_ARCH_PATH=${MPI_ARCH_PATH}"

if [[ "${WM_MPLIB}" != "SYSTEMMPI" ]]; then
    echo "etc/bashrc overrode WM_MPLIB to '${WM_MPLIB}'; expected SYSTEMMPI." >&2
    exit 1
fi
if [[ ! -f "${MPI_ARCH_PATH}/include/mpi.h" ]]; then
    echo "No mpi.h under ${MPI_ARCH_PATH}/include — the mpich host dependency is missing." >&2
    exit 1
fi

# -q (wmakeCollect queue mode) is deliberately NOT used: it defers compilation into a
# batch, which makes a partial build hard to attribute. Plain parallel wmake reports each
# failure where it happens.
#
# Full parallelism: the earlier stall was a genuine compile error (missing FlexLexer.h),
# not memory pressure — the full job log contains no OOM, kill or cancellation marker.
set +e
./Allwmake -j "${CPU_COUNT}" -l
_allwmake_status=$?
set -e
echo "Allwmake exited with status ${_allwmake_status} (137 = SIGKILL, typically OOM)"
command -v free >/dev/null 2>&1 && free -h || true

# Allwmake's exit status is not trustworthy — it returns 0 even when targets fail to
# compile — and -l diverts compiler output into log.<WM_OPTIONS>, so nothing useful
# reaches CI. Surface whatever errors it recorded, then verify the artefacts directly.
if compgen -G "log.*" > /dev/null; then
    echo "--- errors recorded by wmake (last 60) ---"
    grep -hnE "Error [0-9]+|error:|fatal error" log.* | tail -n 60 || true
    echo "--- end of wmake errors ---"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    _lib_suffix=".dylib"
else
    _lib_suffix=".so"
fi

# Check a library AND an application: the previous build produced libOpenFOAM but no
# applications at all, and a libraries-only check passed it straight through to the test
# phase.
_missing=()
[[ -f "${FOAM_LIBBIN}/libOpenFOAM${_lib_suffix}" ]] || _missing+=("libOpenFOAM${_lib_suffix}")
[[ -f "${FOAM_LIBBIN}/libfiniteVolume${_lib_suffix}" ]] || _missing+=("libfiniteVolume${_lib_suffix}")
[[ -x "${FOAM_APPBIN}/blockMesh" ]] || _missing+=("blockMesh")
[[ -x "${FOAM_APPBIN}/simpleFoam" ]] || _missing+=("simpleFoam")

if (( ${#_missing[@]} > 0 )); then
    echo "Allwmake did not produce: ${_missing[*]}" >&2
    echo "FOAM_LIBBIN=${FOAM_LIBBIN} FOAM_APPBIN=${FOAM_APPBIN}" >&2
    echo "--- tail of the wmake log ---" >&2
    tail -n 300 log.* >&2 || true
    exit 1
fi
echo "Built libOpenFOAM, libfiniteVolume, blockMesh and simpleFoam"

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
