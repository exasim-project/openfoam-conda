#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense

# OpenFOAM environment for a conda prefix.
#
# Adapted from conda-forge/openfoam-feedstock's openfoam_activate.sh, with the paths
# corrected: that version exports FOAM_SRC=$PREFIX/src, FOAM_APP=$PREFIX/applications,
# FOAM_SOLVERS and FOAM_UTILITIES, none of which its package installs. This package
# ships both trees, so every variable below names a directory that exists.

export FOAM_API=@OPENFOAM_API@
export WM_PROJECT=OpenFOAM
export WM_PROJECT_VERSION=v${FOAM_API}
export WM_PROJECT_DIR="${CONDA_PREFIX}"

export WM_ARCH_OPTION=64
export WM_COMPILER_TYPE=system
export WM_COMPILER_LIB_ARCH=64
export WM_COMPILE_OPTION=Opt
export WM_LABEL_OPTION=Int32
export WM_LABEL_SIZE=32
export WM_PRECISION_OPTION=DP
export WM_MPLIB=MPICH

if [ "$(uname -s)" = "Darwin" ]; then
    export WM_ARCH=darwin64
    export WM_COMPILER=Clang
    export WM_OPTIONS=darwin64ClangDPInt32Opt
else
    export WM_ARCH=linux64
    export WM_COMPILER=Gcc
    export WM_OPTIONS=linux64GccDPInt32Opt
fi

export WM_DIR="${WM_PROJECT_DIR}/wmake"
export WM_THIRD_PARTY_DIR="${WM_PROJECT_DIR}/ThirdParty"

# Source and application trees. Unlike conda-forge's package these really are present.
export FOAM_SRC="${WM_PROJECT_DIR}/src"
export FOAM_ETC="${WM_PROJECT_DIR}/etc"
export FOAM_APP="${WM_PROJECT_DIR}/applications"
export FOAM_SOLVERS="${FOAM_APP}/solvers"
export FOAM_UTILITIES="${FOAM_APP}/utilities"
export FOAM_TUTORIALS="${WM_PROJECT_DIR}/tutorials"

# Binaries and libraries live in the conda prefix, not under platforms/.
export FOAM_APPBIN="${CONDA_PREFIX}/bin"
export FOAM_LIBBIN="${CONDA_PREFIX}/lib"
export FOAM_SITE_APPBIN="${CONDA_PREFIX}/bin"
export FOAM_SITE_LIBBIN="${CONDA_PREFIX}/lib"
export FOAM_USER_APPBIN="${HOME}/.OpenFOAM/${FOAM_API}/platforms/${WM_OPTIONS}/bin"
export FOAM_USER_LIBBIN="${HOME}/.OpenFOAM/${FOAM_API}/platforms/${WM_OPTIONS}/lib"
export FOAM_RUN="${HOME}/OpenFOAM/run"

# Substituted at build time with whatever etc/bashrc derived from WM_MPLIB,
# so this names the directory the libraries were actually installed into.
export FOAM_MPI=@FOAM_MPI@
export MPI_ARCH_PATH="${CONDA_PREFIX}"

# Consumers such as NeoFOAM link $FOAM_LIBBIN/$FOAM_MPI for libPstream.
export LD_LIBRARY_PATH="${FOAM_LIBBIN}/${FOAM_MPI}:${FOAM_LIBBIN}:${LD_LIBRARY_PATH:-}"
if [ "$(uname -s)" = "Darwin" ]; then
    export DYLD_LIBRARY_PATH="${FOAM_LIBBIN}/${FOAM_MPI}:${FOAM_LIBBIN}:${DYLD_LIBRARY_PATH:-}"
fi
