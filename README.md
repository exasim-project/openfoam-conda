<!--
SPDX-FileCopyrightText: 2026 NeoFOAM authors
SPDX-License-Identifier: MIT
-->

# openfoam-conda

Conda packages for ESI OpenFOAM, built for `linux-64` and `osx-arm64` and published to a
[prefix.dev](https://prefix.dev) channel.

```bash
pixi add openfoam -c https://prefix.dev/greole/exasim-project -c conda-forge
```

Versions built: **v2506**, **v2512**, **v2606**.

### Docker images

`ghcr.io/exasim-project/openfoam:<version>` (and `:latest` for v2606) contain the same conda
build, installed in `/opt/openfoam` with the OpenFOAM environment active in every shell:

```bash
docker run --rm -it ghcr.io/exasim-project/openfoam:2512 blockMesh -help
```

`docker/Dockerfile` installs the published package rather than compiling, so an image builds
in minutes. It takes a `BASE_IMAGE` build arg, which layers OpenFOAM on other images.

`ghcr.io/exasim-project/openfoam-ginkgo-{cpu,cuda,rocm,sycl}:<version>` put OpenFOAM on the
Ginkgo images from [ginkgo-packaging](https://github.com/exasim-project/ginkgo-packaging):
OpenFOAM + Ginkgo develop + (in the GPU images) a GPU-aware MPICH. OpenFOAM's conda copy
of `libmpi` is removed in these images, so OpenFOAM uses the base image's MPICH; both are
MPICH ABI. They are rebuilt weekly to follow the Ginkgo nightlies; every image also gets a
dated `<version>-<YYYYMMDD>` tag for consumers that cache images by name, such as
Apptainer-based CI runners.

## Why this exists

conda-forge has an [`openfoam` feedstock](https://github.com/conda-forge/openfoam-feedstock),
and where it works you should prefer it. Three things made it unusable for NeoFOAM:

**1. Only v2412 is packaged.** It is the single version in the channel, on `linux-64` only.
There is no v2506, v2512 or v2606 anywhere in the conda ecosystem — the other `openfoam`
packages on anaconda.org are the OpenFOAM *Foundation* lineage (3.x, 9, 13), a different
codebase.

**2. Its builds are reported to compute wrong results in 3-D.**
[openfoam-feedstock#8](https://github.com/conda-forge/openfoam-feedstock/issues/8) reports
that both published v2412 artifacts give a developed viscous pressure gradient ≈24–26% too
high in every 3-D or axisymmetric case, while the solver converges normally and velocity
looks right. The cause is that the recipe appends conda's default `$CXXFLAGS`
(`-O2 -ftree-vectorize`) after wmake's `-O3`, which lets GCC vectorise OpenFOAM's field
transpose `Foam::T()` without a runtime overlap check — legal, since OpenFOAM marks its
list storage `__restrict__`, but false, because OpenFOAM performs that transpose *in place*
for reusable temporaries such as `dev2(T(fvc::grad(U)))` inside every turbulence model's
`divDevReff`. Planar 2-D cases are bit-for-bit immune, which is why the feedstock's
`pitzDaily` run-test never caught it. The underlying in-place transpose is an upstream
defect (OpenFOAM issue #3166, commit `b5aa32f0`) whose fix was never merged, so it is still
present in v2606 — there is no version to bump to, only a flags fix.

**3. It ships neither `src/` nor `applications/`,** while its activation script exports
`FOAM_SRC`, `FOAM_APP`, `FOAM_SOLVERS` and `FOAM_UTILITIES` pointing at them. Headers go to
`include/OpenFOAM-<version>/src` instead, and the application sources are compiled and
discarded. Anything that *compiles* against OpenFOAM has to work around this; anything that
compiles OpenFOAM's own application sources — pybFoam's `meshing` module builds five files
from `applications/utilities/mesh/manipulation/checkMesh` — cannot build at all.

## What this build does differently

| | conda-forge | here |
|---|---|---|
| Optimisation | conda `$CXXFLAGS` appended after wmake's, giving `-O2 -ftree-vectorize` | `-O*` and `-ftree-vectorize` scrubbed; wmake's `-O3` stands, as in ESI's own binaries |
| `src/` | lnInclude dirs copied to `include/OpenFOAM-<ver>/src` | complete tree at `$PREFIX/src`, where `FOAM_SRC` points |
| `applications/` | not installed | complete tree at `$PREFIX/applications` |
| Run test | `pitzDaily` (planar 2-D, immune to the defect above) | 3-D laminar square duct checked against the Shah & London analytic gradient |
| Versions | 2412 | 2506, 2512, 2606 |
| Platforms | linux-64 | linux-64, osx-arm64 |

The dependency set is ported from conda-forge's `meta.yaml` and is the work of its
maintainers. The build script is not.

## Layout

```
recipe/
  recipe.yaml        rattler-build recipe; version comes from the variant config
  build.sh           flag scrubbing, build, install of the full source tree
  activate.sh        FOAM_* environment; every path it exports exists
  deactivate.sh
  run_test.sh        3-D duct regression test
  test_case/         the duct case it runs
ci/
  build_conda_packages.sh   one version x one platform; holds the tarball checksums
  install_rattler_build.sh  pinned, checksum-verified rattler-build
docker/
  Dockerfile         conda package -> image, on a configurable base image
  activate.sh        FOAM_* environment for shells in the image, without conda
.github/workflows/
  conda_packages.yaml       matrix over versions x platforms, publish to prefix.dev
  docker.yaml               matrix over versions x base images (plain, Ginkgo), test, push
```

## Building locally

```bash
ci/install_rattler_build.sh 0.75.0 ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
ci/build_conda_packages.sh --openfoam-version 2506
```

The target platform defaults to the host. You cannot build `linux-64` on macOS without a
Linux container, and emulating x86-64 on Apple Silicon for a build this size is not
practical — use CI for anything you intend to publish.

## Publishing

`workflow_dispatch` with `publish: true`, or push a `v*` tag. Requires
`vars.PREFIX_DEV_CHANNEL` and `secrets.PREFIX_DEV_API_KEY` (scope the secret to the
`prefix-dev` environment, not the repository).

## Status and known risks

Nothing here has been built yet. Specifically:

- **`osx-arm64` is the higher-risk target.** OpenFOAM ships `wmake/rules/darwin64`,
  `darwin64Clang` and `darwin64Gcc`, so macOS is supported upstream, but conda-forge has no
  macOS OpenFOAM build and this recipe's `WM_ARCH`/`WM_OPTIONS` handling for Apple Silicon
  is untested. Expect to iterate, and look at the
  [`gerlero/homebrew-openfoam`](https://github.com/gerlero/homebrew-openfoam) casks for any
  patches Apple Silicon needs. `linux-64` is the target to get green first.
- **The 3-D test case is unvalidated.** The dictionaries follow ESI conventions and the
  method follows the issue report, but the case has never been run. Check it on the first CI
  build before trusting a pass.
- **Build time** is hours per job and the GitHub cap is 6. `timeout-minutes` is set to 350.
- **Package size** is large, since the full `src/` and `applications/` trees ship. Splitting
  into `openfoam` / `openfoam-src` outputs is the obvious follow-up if that hurts.
- **Trademark.** OpenFOAM is a registered trademark of OpenCFD Ltd. This is an unofficial
  build, not endorsed by or affiliated with ESI-OpenCFD.

## Licence

The recipe and CI scripts are Unlicense/MIT as marked. OpenFOAM itself is GPL-3.0-only and
is neither modified nor redistributed in source form by this repository — the build
downloads it from SourceForge at a pinned checksum.
