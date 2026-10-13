# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense

# Activates the OpenFOAM conda environment without conda: runs the package's activate.d
# scripts, which set the FOAM_* / WM_* environment. Guarded, so sourcing it twice (BASH_ENV
# and bash.bashrc) is harmless.
if [ -z "${OPENFOAM_IMAGE_ACTIVATED:-}" ]; then
    export OPENFOAM_IMAGE_ACTIVATED=1
    export CONDA_PREFIX=/opt/openfoam
    # Appended, so the base image's compilers and MPI keep precedence.
    export PATH="${PATH}:${CONDA_PREFIX}/bin"
    for _f in "${CONDA_PREFIX}"/etc/conda/activate.d/*.sh; do
        [ -r "${_f}" ] && . "${_f}"
    done
    unset _f
fi
