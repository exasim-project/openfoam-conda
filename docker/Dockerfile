# syntax=docker/dockerfile:1
#
# SPDX-FileCopyrightText: 2026 NeoFOAM authors
#
# SPDX-License-Identifier: Unlicense
#
# OpenFOAM image built from the published conda package rather than from source, so the
# image carries exactly the build that passed the 3-D regression test (see README.md),
# and building it takes minutes instead of hours.
#
#   docker build -f docker/Dockerfile --build-arg OPENFOAM_VERSION=2512 \
#     [--build-arg BASE_IMAGE=ghcr.io/exasim-project/ginkgo-rocm:nightly] .
#
# The conda environment is self-contained (glibc 2.17 baseline), so it can be layered on
# any glibc-based image, e.g. the Ginkgo GPU images from ginkgo-packaging.

ARG BASE_IMAGE=ubuntu:24.04
ARG MICROMAMBA_IMAGE=mambaorg/micromamba:2.9.0

FROM ${MICROMAMBA_IMAGE} AS env
ARG OPENFOAM_VERSION
ARG CHANNEL=https://prefix.dev/greole/exasim-project
USER root
RUN test -n "${OPENFOAM_VERSION}" \
    && micromamba create --yes --prefix /opt/openfoam \
        --channel "${CHANNEL}" --channel conda-forge \
        "openfoam=${OPENFOAM_VERSION}" \
    && micromamba clean --all --yes
COPY docker/activate.sh /opt/openfoam/activate.sh


FROM ${BASE_IMAGE}
ARG OPENFOAM_VERSION
ARG DEBIAN_FRONTEND=noninteractive
# Python for OpenFOAM tooling (foamlib, PyFoam, case setup scripts). Every base image
# used here is Ubuntu.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*
COPY --from=env /opt/openfoam /opt/openfoam
# A base image that brings its own MPICH, such as the GPU-aware one in the Ginkgo GPU
# images, must be the one OpenFOAM uses: drop the conda copy of libmpi so libPstream and
# the other conda libraries resolve to the base image's. Both are MPICH ABI
# (libmpi.so.12), and OpenFOAM was built against MPICH 5, so no rebuild is needed.
# Intel MPI (oneAPI images) is not in the ld.so cache but found through I_MPI_ROOT.
RUN if ldconfig -p | grep -q 'libmpi\.so\.12 ' \
        || [ -e "${I_MPI_ROOT:-/nonexistent}/lib/libmpi.so.12" ]; then \
        rm -f /opt/openfoam/lib/libmpi.so*; \
        echo "OpenFOAM uses the base image's MPI: $(ldconfig -p | grep 'libmpi\.so\.12 ' || echo "${I_MPI_ROOT}")"; \
    fi
# BASH_ENV covers non-interactive bash (CI scripts, `bash -c`), ENV covers POSIX sh,
# bash.bashrc covers interactive shells.
RUN echo '. /opt/openfoam/activate.sh' >> /etc/bash.bashrc
ENV BASH_ENV=/opt/openfoam/activate.sh \
    ENV=/opt/openfoam/activate.sh
LABEL org.opencontainers.image.title="openfoam" \
      org.opencontainers.image.description="ESI OpenFOAM v${OPENFOAM_VERSION} (conda build) in /opt/openfoam" \
      org.opencontainers.image.source="https://github.com/exasim-project/openfoam-conda" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${OPENFOAM_VERSION}"
