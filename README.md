# ImageMagick and Ghostscript static universal build for macOS

A self-contained `Makefile` that builds ImageMagick and Ghostscript from source
on macOS with every library they can use. It links everything statically and
produces a universal (x86_64 and arm64) or single-architecture binaries. It
links Ghostscript's library (`libgs`) statically into `magick`, so PDF/PS/EPS
support needs no external `gs`.

It downloads all sources, builds its own small toolchain (GNU m4, autoconf,
automake, libtool, pkgconf, nasm), builds each dependency per architecture, and
merges the results with `lipo`. You can rebuild every dependency on its own, so
updates stay cheap.

> The binaries are as static as macOS allows: the build links in all third-party
> libraries and leaves only Apple system libraries (`libSystem`, `libc++`,
> `libiconv`, etc.) dynamic. `make verify` checks this. The build uses no X11
> anywhere.

---

## 1. Prerequisites

| Requirement                  | Notes                                                                        |
|------------------------------|------------------------------------------------------------------------------|
| macOS                        | 11 (Big Sur) or newer recommended                                            |
| Xcode **Command Line Tools** | compiler, SDK, `make`, `lipo`, `perl`, `curl`, Apple `libtool`, etc.         |
| **CMake** 3.15 or newer      | used by about a dozen libraries (libjpeg-turbo, libheif, libjxl, x265, etc.) |
| Internet access              | to download the sources (GitHub, GNU, xiph/videolan/freedesktop, etc.)       |
| ~12 GB free disk space       | sources, per-arch build trees, libraries                                     |
| Time                         | a full universal build takes a long time (libjxl, libheif, x265, OpenEXR)    |

### Installing the macOS Command Line Tools

```sh
xcode-select --install
```

macOS shows a dialog, accept it and wait for the installation to finish. Check
with `xcode-select -p` (prints a path) and `clang --version`. Installing the
full Xcode from the App Store also provides them.

### Installing CMake

Any one of these works. The build only needs to find CMake in your `PATH`, or
you can point at it with `make CMAKE=/path/to/cmake`:

```sh
brew install cmake          # Homebrew (https://brew.sh)
sudo port install cmake     # MacPorts
```

or download the macOS `.dmg` from <https://cmake.org/download/>, drag
**CMake.app** to `/Applications`, and make the command available with:

```sh
sudo "/Applications/CMake.app/Contents/bin/cmake-gui" --install   # installs /usr/local/bin/cmake
```

Check with `cmake --version`. The build does not use Homebrew, and it tells
CMake to ignore `/opt/homebrew`, `/usr/local` and `/opt/local`, so libraries you
installed there cannot leak in.

---

## 2. Quick start

```sh
make check-system     # optional: verify prerequisites
make                  # download, toolchain, libraries, Ghostscript, ImageMagick, and 'make dist'
make verify           # check architectures, static linkage, delegates, formats, and run tests
```

Result (with the default `OUTPUT_DIR=dist` and `DIST_PREFIX=/usr/local`):

```
dist/
├── x86_64/usr/local/{bin,lib,include,share}     # one tree per architecture that was built
├── arm64/usr/local/{bin,lib,include,share}
└── universal/usr/local/{bin,lib,include,share}  # only when more than one arch was built
```

For example `dist/arm64/usr/local/bin/magick` and `dist/universal/usr/local/bin/gs`.
Each tree contains:

```
├── bin/magick (plus convert, identify, mogrify, compare, composite, montage, stream, conjure symlinks)
├── bin/gs (plus the ps2pdf, ps2ps, pdf2ps, eps2eps, ... helper scripts)
├── include/ghostscript/          Ghostscript API headers (iapi.h, ierrors.h, etc.)
├── lib/libgs.a                   Ghostscript static library (only the gsapi_* functions are exported)
├── share/ghostscript/            Ghostscript shared data: iccprofiles/ (.icc), lib/ (.ps, .upp, .ppd, ...), Resource/
├── share/imagemagick/fonts/      fontconfig configuration (see section 7)
├── share/man/                    Ghostscript man pages
└── share/imagemagick/licenses/   ImageMagick licences, vendors/<software_name>/ holds every other package's (see section 8)
```

You can copy a tree straight onto a target (for example
`sudo cp -R dist/universal/usr/local/ /usr/local/`) or package it.
Per-architecture trees hold thin binaries, the `universal` tree holds the
`lipo`-merged ones. With a single architecture (e.g. `ARCHS=arm64`) the build
creates only that arch's tree.

Useful variants:

```sh
make ARCHS=arm64                          # Apple Silicon only
make ARCHS=x86_64 MACOSX_DEPLOYMENT_TARGET=10.15
make TOOLCHAIN_DIR=$HOME/im-toolchain DEPS_DIR=/Volumes/Fast/deps
make DIST_PREFIX=/opt/imagemagick         # dist/<arch>/opt/imagemagick/bin/magick
make GS_TESSERACT=no                      # Ghostscript without the OCR devices
make IM_QUANTUM_DEPTH=8 IM_HDRI=no        # smaller, faster Q8 ImageMagick
make JOBS=1                               # serial inner builds, for debugging
```

Do not pass `-j` to the top-level `make`. Each package build uses `JOBS` for
parallelism (default: number of CPU cores). `make -n` does not work as a
reliable dry run, because the build runs package builds as recursive make
invocations.

---

## 3. How it works

```
├── build/<arch>/<pkg>/    extracted and compiled sources for each architecture
├── deps/<arch>/           static libraries/headers installed for that architecture
│   └── .stamps/           one stamp file per installed package+version
├── dist/<arch>/<prefix>/  final per-arch output, dist/universal/<prefix>/ when several archs
├── downloads/             source tarballs (shared by everything)
├── packages/              final per-arch packages
└── toolchain/             native tools: m4, autoconf, automake, libtool, pkgconf, nasm
    └── .stamps/           one stamp file per installed tool+version
```

1. Download: the Makefile fetches each archive with `curl` into `downloads/`
   and verifies it when you configured a checksum.
2. Toolchain: the build compiles the tools once with the host compiler and
   installs them into `TOOLCHAIN_DIR`. It puts them first on `PATH` for all
   other builds. It uses `pkgconf` with `--static` so static dependency chains
   resolve correctly, automake supplies current `config.sub`/`config.guess`,
   and `nasm` assembles the x86_64 SIMD code of libjpeg-turbo, x265 and libaom.
   CMake comes from the system.
3. Libraries: the build compiles every library once per architecture
   (`clang -arch x86_64` / `-arch arm64`, or `CMAKE_OSX_ARCHITECTURES`) as a
   static archive into `deps/<arch>`. It cross-compiles the non-native
   architecture. It builds Ghostscript's helper programs with the native
   compiler (`CCAUX`), so the autotools builds need no Rosetta.
4. Ghostscript: the build uses the library sources bundled in its tarball. It
   produces both the `gs` program and a static `libgs`. It pre-links all
   objects of the library into one object that exports only the `gsapi_*`
   functions, this hides Ghostscript's private copies of jpeg, freetype,
   lcms2mt, etc., so they cannot clash with the libraries ImageMagick links.
5. ImageMagick: the build configures it against `deps/<arch>` (Q16-HDRI, zero
   configuration, no modules, no X, `--with-gslib`), builds it per
   architecture, then `make dist` copies each arch into `dist/<arch>/<prefix>`
   and merges them with `lipo` into `dist/universal/<prefix>`.

Stamp files named `<package>-<version>.stamp` drive rebuilds. When you change a
version, the stamp name changes and the build rebuilds that package. It also
rebuilds dependents (for example ImageMagick after a library rebuild) because
their stamps are older than their dependencies' stamps.

### Libraries and formats included

| Feature in ImageMagick                                    | Provided by                                                                                |
|-----------------------------------------------------------|--------------------------------------------------------------------------------------------|
| PDF, PS, EPS, AI (reading, rendering)                     | Ghostscript (`libgs.a`, linked in)                                                         |
| JPEG                                                      | libjpeg-turbo (libjpeg v8 API, arithmetic coding)                                          |
| PNG, MNG/JNG                                              | libpng (and zlib)                                                                          |
| TIFF / BigTIFF                                            | libtiff, with zlib, libdeflate, JPEG, JBIG, LZMA, ZSTD, WebP                               |
| JBIG                                                      | jbigkit                                                                                    |
| WebP                                                      | libwebp                                                                                    |
| HEIC / HEIF / AVIF                                        | libheif with libde265 plus x265 (HEVC), libaom (AV1), OpenJPEG/OpenJPH, uncompressed codec |
| JPEG XL                                                   | libjxl (with highway, brotli, lcms2)                                                       |
| Ultra HDR (JPEG with gain map)                            | libultrahdr                                                                                |
| JPEG 2000 (JP2, J2K)                                      | OpenJPEG                                                                                   |
| OpenEXR                                                   | OpenEXR (with Imath, libdeflate, OpenJPH, zstd)                                            |
| Camera RAW (DNG, CR2, NEF, ARW, etc.)                     | LibRaw                                                                                     |
| DjVu                                                      | djvulibre                                                                                  |
| SVG / MSVG                                                | ImageMagick's built-in renderer, with libxml2                                              |
| Colour management                                         | lcms2                                                                                      |
| Fonts and text rendering                                  | freetype (with zlib, bzip2, libpng, brotli), fontconfig, expat                             |
| FFT (`-fft`, `-ift`)                                      | FFTW                                                                                       |
| Compression inside formats                                | zlib, bzip2, xz (LZMA), zstd                                                               |
| GIF, BMP, ICO, PNM, TGA, XPM, PCX, PSD, and many more     | built into ImageMagick                                                                     |
| Extra PDF/PS/EPS/XPS/PCL **writing** and conversion tools | the bundled `gs` (`ps2pdf`, `pdf2ps`, `eps2eps`, etc.)                                     |

Ghostscript itself includes its bundled jpeg, freetype, openjpeg, jbig2dec,
lcms2mt, tiff, brotli, zlib, libpng, and (by default) Tesseract/Leptonica OCR
code. It also includes all of its output devices that do not need X (`pdfwrite`,
`ps2write`, `png16m`, `tiff*`, `jpeg`, `pcx*`, `pnm*`, `pdfocr*`, etc.),
including the contrib printer drivers.

### Deliberately not included

| Left out                                              | Reason                                                            |
|-------------------------------------------------------|-------------------------------------------------------------------|
| X11 (`display`, `animate`, `import`, X devices)       | required not to use X                                             |
| librsvg, Pango, Cairo, liblqr, libraqm                | pull in the glib/Rust/harfbuzz stack (SVG uses the built-in MSVG) |
| libwmf, FlashPix, autotrace, FLIF, Display PostScript | unmaintained or practically unbuildable with a modern clang       |
| libzip, C2PA, OpenCL, OpenMP                          | not worth the weight / Apple clang has no OpenMP                  |
| Dynamic modules (libltdl)                             | everything is linked in statically                                |
| Magick++, PerlMagick                                  | not needed for the command line tools                             |
| Windows, LibreOffice, ffmpeg based formats            | not ImageMagick delegates                                         |

---

## 4. Configuration

Every variable can be set on the command line (`make VAR=value`), in the
environment, or in an optional `config.mk` next to the Makefile. The Makefile
reads `config.mk` automatically:

```make
# config.mk example
TOOLCHAIN_DIR   = /opt/im-toolchain
OUTPUT_DIR      = $(HOME)/im-dist
ARCHS           = arm64
LIBHEIF_VERSION = 1.23.6
X265_SHA256     = <sha256 of the x265 tarball>
```

| Variable                       | Default                                  | Purpose                                                                                                                                        |
|--------------------------------|------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `ARCHS`                        | `x86_64 arm64`                           | architectures to build (one or both)                                                                                                           |
| `MACOSX_DEPLOYMENT_TARGET`     | `11.0`                                   | minimum macOS version (arm64 needs ≥ 11.0)                                                                                                     |
| `BASE_DIR`                     | Makefile folder                          | root for the folders below                                                                                                                     |
| `DOWNLOAD_DIR`                 | `$(BASE_DIR)/downloads`                  | source tarballs                                                                                                                                |
| `TOOLCHAIN_DIR`                | `$(BASE_DIR)/toolchain`                  | native toolchain                                                                                                                               |
| `BUILD_DIR`                    | `$(BASE_DIR)/build`                      | build trees                                                                                                                                    |
| `DEPS_DIR`                     | `$(BASE_DIR)/deps`                       | per-arch static libraries                                                                                                                      |
| `OUTPUT_DIR`                   | `$(BASE_DIR)/dist`                       | root of the final per-arch / universal trees                                                                                                   |
| `PACKAGE_DIR`                  | `$(BASE_DIR)/packages`                   | where `make package` writes the `.pkg` files                                                                                                   |
| `PKG_IDENTIFIER`               | `<username>.imagemagick`                 | package identifier, default is the current user name in lower case plus `.imagemagick`                                                         |
| `PKG_VERSION`                  | `$(IMAGEMAGICK_VERSION)`                 | package version                                                                                                                                |
| `DIST_PREFIX`                  | `/usr/local`                             | prefix recreated inside every `OUTPUT_DIR/<arch>` and `OUTPUT_DIR/universal` folder (also compiled into fontconfig)                            |
| `DEPENDENCIES_FILE`            | `$(BASE_DIR)/DEPENDENCIES.txt`           | dependency map                                                                                                                                 |
| `JOBS`                         | CPU count                                | parallelism inside each package build                                                                                                          |
| `TARGET_CC` / `TARGET_CXX`     | `clang` / `clang++`                      | compilers                                                                                                                                      |
| `CMAKE`                        | `cmake`                                  | CMake executable                                                                                                                               |
| `CMAKE_IGNORE_PREFIXES`        | `/opt/homebrew;/usr/local;/opt/local`    | prefixes CMake must not search (`;` separated)                                                                                                 |
| `MACOS_SDK`                    | `xcrun --show-sdk-path`                  | SDK used for `-isysroot`                                                                                                                       |
| `OPT_FLAGS`                    | `-O2`                                    | optimisation flags                                                                                                                             |
| `LEGACY_WARN`                  | `-Wno-error=...`                         | downgrades errors that modern clang raises on old code                                                                                         |
| `STRIP_BINARIES`               | `yes`                                    | strip the final executables                                                                                                                    |
| `IM_QUANTUM_DEPTH`             | `16`                                     | ImageMagick quantum depth (8, 16 or 32)                                                                                                        |
| `IM_HDRI`                      | `yes`                                    | build ImageMagick with HDRI                                                                                                                    |
| `IMAGEMAGICK_EXTRA_LIBS`       | `-lc++ -liconv -lm`                      | extra `LIBS` for ImageMagick's configure link tests (needed by `libgs.a`)                                                                      |
| `GS_TESSERACT`                 | `yes`                                    | build Ghostscript's bundled Tesseract OCR devices (`no` to leave them out)                                                                     |
| `GS_FONTPATH`                  | `/Library/Fonts:/System/Library/Fonts`   | extra font folders Ghostscript searches                                                                                                        |
| `REQUIRED_FORMATS`             | see Makefile                             | formats `make verify` must find in `magick -list format`                                                                                       |
| `REQUIRED_DELEGATES`           | see Makefile                             | delegates `make verify` must find in `magick -version`                                                                                         |
| `VERIFY_ROUNDTRIP`             | `png jpg tif webp avif heic jxl jp2 exr` | extensions `make verify` writes and reads back                                                                                                 |
| `DIST_BINARIES`                | `magick gs`                              | real executables copied into the dist trees                                                                                                    |
| `DIST_IM_LINKS`                | `convert identify mogrify etc.`          | legacy command names created as symlinks to `magick`                                                                                           |
| `DIST_GS_SCRIPTS`              | `ps2pdf ps2ps pdf2ps etc.`               | Ghostscript helper scripts copied into the dist trees                                                                                          |
| `DIST_MAN`                     | see Makefile                             | man pages copied into the dist trees                                                                                                           |
| `DIST_LICENSES_DIR`            | `share/imagemagick/licenses`             | folder (relative to the prefix) receiving the licence files (`make licenses`)                                                                  |
| `DIST_FONT_DIR`                | `share/imagemagick/fonts`                | folder (relative to the prefix) holding fontconfig's configuration. Compiled in, so changing it needs `make rebuild-fontconfig`                |
| `DIST_GS_SHARE_DIR`            | `share/ghostscript`                      | folder (relative to the prefix) receiving Ghostscript's shared data. gs is built to search it, so changing it needs `make rebuild-ghostscript` |
| `DIST_GS_SHARE_ITEMS`          | `iccprofiles lib Resource`               | which Ghostscript data folders are copied there (missing ones are skipped)                                                                     |
| `GHOSTSCRIPT_LIB_DEFAULT`      | see Makefile                             | search path compiled into `gs` (the shared folder above plus `GS_FONTPATH`). Empty keeps Ghostscript's own default                             |
| `GHOSTSCRIPT_STRIP_INVOCATION` | `yes`                                    | remove the `%%Invocation:` comment that Ghostscript (the `gs` command line) writes into the PDF and PostScript files it creates                |

Per package: `<PKG>_VERSION`, `<PKG>_URL`, `<PKG>_ARCHIVE` (file name to save
the download as), `<PKG>_SHA256` (empty = no verification), `<PKG>_CFG` (extra
`./configure` options) or `<PKG>_CMAKE` (extra CMake options, which also makes
the package a CMake package) with `<PKG>_CMAKE_SRC` (CMake source folder), plus
the optional hooks `<PKG>_CONFIGURE`, `_PRE`, `_BUILD`, `_INSTALL`, `_POST`.
`<PKG>` is the upper-cased package name with `-` replaced by `_`
(`LIBJPEG_TURBO_VERSION`). Run `make versions` to list the current versions.

The toolchain is not relocatable after you build it (autoconf/automake record
absolute paths). If you change `TOOLCHAIN_DIR`, the build rebuilds the tools
in the new location. Avoid spaces in all paths.

---

## 5. Targets

| Command                          | Effect                                                                                                       |
|----------------------------------|--------------------------------------------------------------------------------------------------------------|
| `make` / `make all`              | everything                                                                                                   |
| `make download`                  | download all sources only                                                                                    |
| `make checksums`                 | download everything and print `<PKG>_SHA256 = ...` lines, ready for `config.mk`                              |
| `make toolchain`                 | build only the toolchain                                                                                     |
| `make deps`                      | build all libraries (all architectures)                                                                      |
| `make <name>`                    | build one package for all architectures, e.g. `make libheif`                                                 |
| `make <name>-<arch>`             | one package, one architecture, e.g. `make libheif-arm64`                                                     |
| `make ghostscript`               | build Ghostscript (`gs` and `libgs.a`) per architecture                                                      |
| `make imagemagick`               | build ImageMagick per architecture (no `lipo` step)                                                          |
| `make dist`                      | (re)create `OUTPUT_DIR/<arch>/<prefix>` for each built arch, plus `OUTPUT_DIR/universal/<prefix>` if several |
| `make rebuild-<name>`            | force-rebuild one package or tool                                                                            |
| `make clean-<name>`              | forget one package (stamp and build tree)                                                                    |
| `make licenses`                  | collect licence files from the source archives into every `dist` tree (part of `make`)                       |
| `make package`                   | build `.pkg` installers from the `dist` trees (see below)                                                    |
| `make verify`                    | check `magick` and `gs`: architectures, system-only linkage, delegates, formats, and run conversion tests    |
| `make info`, `versions`, `graph` | show configuration, versions, dependency map                                                                 |
| `make clean`                     | remove `build/`                                                                                              |
| `make distclean`                 | also remove toolchain, libraries and output                                                                  |
| `make purge`                     | also remove downloaded sources                                                                               |

Valid `<name>` values: the toolchain (`m4`, `autoconf`, `automake`, `libtool`,
`pkgconf`, and `nasm`), the libraries (`zlib`, `bzip2`, `xz`, `zstd`, `brotli`,
`libdeflate`, `libpng`, `libjpeg-turbo`, `jbigkit`, `libwebp`, `libtiff`,
`lcms2`, `openjpeg`, `freetype`, `expat`, `fontconfig`, `libxml2`, `imath`,
`openjph`, `openexr`, `highway`, `libjxl`, `libultrahdr`, `libde265`, `x265`,
`aom`, `libheif`, `libraw`, `fftw`, `djvulibre`, and `ghostscript`) and
`imagemagick`.

### Building installer packages

```sh
make package    # runs 'make dist' first, then pkgbuild
```

The build writes one flat `.pkg` per architecture you built, plus one for
`universal` when you built more than one. It writes them to `packages/` in the
project root:

```
packages/
├── imagemagick-7.1.2-33-darwin-x86_64.pkg
├── imagemagick-7.1.2-33-darwin-arm64.pkg
└── imagemagick-7.1.2-33-darwin-universal.pkg
```

Each package uses the matching `dist/<arch>` (or `dist/universal`) tree as its
payload, installed relative to `/`, so with the default prefix it installs
`/usr/local/bin/magick`, `/usr/local/bin/gs`, and so on. The package identifier
defaults to `<username>.imagemagick` (your user name in lower case, override
with `PKG_IDENTIFIER`) and the version is the ImageMagick version
(`IMAGEMAGICK_VERSION`). `pkgbuild` (part of macOS) builds them unsigned, so
sign them yourself with `productsign` if you distribute them.
Inspect one with `pkgutil --payload-files packages/<file>.pkg`.

### Updating a dependency

```sh
make libheif LIBHEIF_VERSION=1.23.7   # or set LIBHEIF_VERSION in config.mk
make                                  # relink everything that depends on it, rebuild ImageMagick, refresh dist/
```

A new version number gives a new stamp, so the build rebuilds the package and
everything that depends on it. To rebuild the _same_ version, use
`make rebuild-libheif` and then `make`. Updating a toolchain tool works the same
way (`make pkgconf PKGCONF_VERSION=...`). Library builds do not rebuild
when a tool changes. Run `make rebuild-<name>` for those you want
refreshed.

If a new version has a different download URL layout, also set `<PKG>_URL` (and
`<PKG>_ARCHIVE` when the file name is not unique). Ghostscript and ImageMagick
are independent of each other's version, except that ImageMagick links the
`libgs.a` of the current Ghostscript build.

---

## 6. Tracking dependencies: `DEPENDENCIES.txt`

`DEPENDENCIES.txt` defines the build order, and the Makefile reads it:

```
<package>: <space-separated direct dependencies>
```

For example `openexr: imath libdeflate openjph zstd`. Lines starting with `#`
are comments. Use `make graph` to print what the Makefile understood.

**Adding a new library:**

1. Add it to `PACKAGES` in the Makefile.
2. Add `NEWLIB_VERSION`, `NEWLIB_URL` (and optionally `_ARCHIVE`, `_SHA256`,
   `_CFG` or `_CMAKE`) in section 4/5.
3. Add its line to `DEPENDENCIES.txt` and append it to the `imagemagick:` line if
   ImageMagick should use it (plus the matching `--with-...` option in
   `IMAGEMAGICK_CFG`).

---

## 7. Notes and troubleshooting

- If `make verify` reports a missing delegate or format, ImageMagick missed a
  library through pkg-config. Read `build/<arch>/imagemagick/config.log` to see
  why the check failed (usually a library whose `.pc` file lacks a private
  dependency; add it to `IMAGEMAGICK_EXTRA_LIBS`).
- When a build fails, logs go to the terminal. To investigate, run
  `make <pkg>-<arch> JOBS=1` and inspect `build/<arch>/<pkg>/config.log` (or
  `_cmake/CMakeFiles/CMakeError.log` for CMake packages). Fix it by passing
  `<PKG>_CFG`/`<PKG>_CMAKE`, or edit hooks in `config.mk`, then run
  `make rebuild-<pkg>`.
- If your clang does not know one of the `-Wno-error=` options in `LEGACY_WARN`,
  remove it in `config.mk`.
- The autotools builds do not run any x86_64 code. Some CMake projects run small
  test programs while configuring, so if the x86_64 slice fails on an Apple
  Silicon Mac with an "Bad CPU type in executable" error, install Rosetta once
  (`softwareupdate --install-rosetta --agree-to-license`) or build only
  `ARCHS=arm64`.
- The OCR devices use Ghostscript's bundled Tesseract (C++17) and need
  `tessdata` language files at run time, which the build does not include. If
  Ghostscript fails to configure or link because of C++, run
  `make GS_TESSERACT=no rebuild-ghostscript` and then `make`.
- Ghostscript always prefers the library sources inside its tarball, so it does
  not use the toolchain's libjpeg, freetype, etc. They stay hidden inside
  `libgs.a`: the build pre-links all objects with `-exported_symbols_list` so
  that only `gsapi_*` stays visible. The build prints
  `libgs.a exports N global symbols` and warns when N is large (hiding failed).
  In that case ImageMagick will fail to link with duplicate symbols or crash in
  JPEG/lcms code. Report it or fall back to building ImageMagick without
  `--with-gslib` and relying on the `gs` binary only.
- PDFs contain no `%%Invocation:` comment. Ghostscript normally writes its
  startup arguments into every file it creates (`%%Invocation: gs ...`). Three
  functions do that: `pdfwrite_write_args_comment` (regular PDF and PostScript
  output, 2 calls), `pdfwrite_fwrite_args_comment` (linearised PDF) and
  `pdfimage_write_args_comment` (the `pdfimage8/24/32` devices). By default,
  `GHOSTSCRIPT_STRIP_INVOCATION=yes` makes `GHOSTSCRIPT_PRE` delete the four
  calls with `sed` before the build and fail if any call remains, so no comment
  can be written. Set `GHOSTSCRIPT_STRIP_INVOCATION=no` to keep the comment,
  then run `make rebuild-ghostscript` and `make`.
- `gs` carries its initialisation files and fonts inside itself, so it runs
  without the extra files. You still get them on disk because you can use them
  directly: `lib` (`.ps` helper programs, `.upp`/`.ppd` printer settings),
  `Resource` and `iccprofiles` (`.icc`). Ghostscript's own `make install` skips
  `Resource` and `iccprofiles` in the default build, so the Makefile runs
  `install-resdata0` and `install-iccdata0` itself. The build compiles `gs` to
  search `<DIST_PREFIX>/<DIST_GS_SHARE_DIR>/{Resource/Init,lib,Resource/Font,fonts}`
  and `GS_FONTPATH` (see `GHOSTSCRIPT_LIB_DEFAULT`). `gs` checks the built-in
  copy for ICC profiles first. To use the shipped files run `gs` with
  `-sICCProfilesDir=<DIST_PREFIX>/<DIST_GS_SHARE_DIR>/iccprofiles/ ...`.
- ImageMagick reads PDF/PS/EPS through the linked `libgs`. It writes with its
  own PDF encoder, and a few delegates still call the plain command `gs` (the
  build sets `PSDelegate=gs` on purpose, so no build-machine path is baked in).
  Install the `bin/gs` of the same tree in the same folder as `magick`, or put
  it in your `PATH`.
- ImageMagick builds with `--enable-zero-configuration --disable-installed`, so
  it does not need its `etc/ImageMagick-7` and `share/ImageMagick-7` folders and
  can sit anywhere. You can still provide a `policy.xml`, `delegates.xml`, etc.
  through `MAGICK_CONFIGURE_PATH`.
- Fontconfig compiles its configuration folder (`fonts.conf`, `conf.d` and the
  `conf.avail` templates that `conf.d` links to) in as
  `<DIST_PREFIX>/<DIST_FONT_DIR>` (default `/usr/local/share/imagemagick/fonts`),
  and `make dist` copies that folder into every tree. This folder only holds
  the configuration; the fonts themselves still come from
  `/System/Library/Fonts`, `/Library/Fonts` and `~/Library/Fonts`. Changing
  `DIST_PREFIX` or `DIST_FONT_DIR` needs `make rebuild-fontconfig` and then
  `make`.
- x265 (GPL-2.0-or-later) and the HEVC/AV1 codecs have patent considerations
  that are separate from the copyright licences. Check them for your use.
- Several sources (`brotli`, `openjpeg`, `imath`, `openjph`, `openexr`, `libjxl`,
  `libultrahdr`, `libxml2`, `imagemagick`) are the tag archives GitHub generates,
  saved under a unique file name through `<PKG>_ARCHIVE`. The shipped SHA-256
  values were computed from them, but GitHub does not formally guarantee
  byte-identical archives forever. If a checksum ever mismatches, check the
  archive and update `<PKG>_SHA256` (or leave it empty).
- If a download fails (SourceForge is occasionally unavailable), fetch the
  archive manually into `downloads/` under its original file name. The build
  does not download existing archives again. The official ImageMagick release
  archives (`https://imagemagick.org/archive/ImageMagick-<version>.tar.xz`) work
  too: set `IMAGEMAGICK_URL`, clear `IMAGEMAGICK_ARCHIVE`, and update the
  checksum.
- The build links formats, coders and filters in statically. It disables dynamic
  loading of modules (libltdl).

---

## 8. License and third-party notices

> This section is informational and **not legal advice**. Check each component's
> own licence files (they are collected by `make licenses`) before
> redistributing.

### This project

The build scripts (`Makefile`, `DEPENDENCIES.txt`, `README.md`) are licensed
under the **GNU General Public License v3.0 only** (`GPL-3.0-only`), see
[`LICENSE`](LICENSE).

### The resulting binaries

The `magick` executable, `gs`, `libgs.a` and the `.pkg` installers contain
third-party code under the licences below. Ghostscript is licensed under the
**AGPL-3.0-or-later**, and it is linked into `magick` (through `libgs`), together
with GPL libraries (x265, FFTW, djvulibre, jbigkit). The combined `magick` binary
is therefore distributed under the **GNU Affero General Public License version 3
or later** (the AGPL's network clause applies if you offer it as a service). When
you redistribute the binaries you must also provide the corresponding source (the
archives listed by `make versions` plus these scripts, or a written offer) and
keep the licence notices. Artifex also offers Ghostscript under a commercial
licence if the AGPL does not suit you.

| Component                        | Used for                           | Licence (SPDX)                                      |
|----------------------------------|------------------------------------|-----------------------------------------------------|
| ImageMagick                      | the tool                           | ImageMagick (Apache-2.0 based)                      |
| Ghostscript (`gs`, `libgs`)      | PDF/PS/EPS, bundled libraries      | AGPL-3.0-or-later                                   |
| x265                             | HEVC encoding (HEIC)               | GPL-2.0-or-later                                    |
| FFTW                             | Fourier transforms                 | GPL-2.0-or-later                                    |
| djvulibre                        | DjVu                               | GPL-2.0-or-later                                    |
| jbigkit                          | JBIG                               | GPL-2.0-or-later                                    |
| libheif, libde265                | HEIC/AVIF container, HEVC decoding | LGPL-3.0-or-later                                   |
| LibRaw                           | camera RAW                         | LGPL-2.1-only or CDDL-1.0                           |
| libaom                           | AV1                                | BSD-2-Clause (plus AOM patent licence)              |
| libjxl, highway                  | JPEG XL                            | BSD-3-Clause, Apache-2.0 or BSD-3-Clause            |
| libultrahdr                      | Ultra HDR                          | Apache-2.0                                          |
| libjpeg-turbo                    | JPEG                               | IJG, BSD-3-Clause, Zlib                             |
| libpng                           | PNG                                | libpng-2.0                                          |
| libtiff                          | TIFF                               | libtiff (BSD-style)                                 |
| libwebp                          | WebP                               | BSD-3-Clause                                        |
| OpenJPEG, OpenJPH                | JPEG 2000, HTJ2K                   | BSD-2-Clause                                        |
| OpenEXR, Imath                   | OpenEXR                            | BSD-3-Clause                                        |
| lcms2                            | colour management                  | MIT                                                 |
| freetype                         | font rendering                     | FTL or GPL-2.0-or-later                             |
| fontconfig                       | font lookup                        | HPND-sell-variant (MIT-style)                       |
| expat, libxml2                   | XML                                | MIT                                                 |
| zlib                             | compression                        | Zlib                                                |
| bzip2                            | compression                        | bzip2-1.0.6                                         |
| xz (liblzma)                     | compression                        | 0BSD / public domain                                |
| zstd                             | compression                        | BSD-3-Clause or GPL-2.0-only                        |
| brotli                           | compression                        | MIT                                                 |
| libdeflate                       | compression                        | MIT                                                 |

The identifiers above reflect the upstream projects' published licences at the
time of writing and can change between versions. The files collected into
`licenses/` are authoritative.

The build tools (m4, autoconf, automake, libtool, pkgconf, nasm) and CMake only
run on your machine, are not part of the output, and are not covered here.

### Where the licence files end up

`make licenses` (also run by `make` and required by `make package`) reads the
original source archives in `downloads/` and copies every root-level `COPYING*`,
`LICENSE*`/`LICENCE*`, `COPYRIGHT*`, `NOTICE*`, `LGPL*`, `GPL*` and `PATENTS*`
file (plus any `<PKG>_LICENSE_FILES`, for example zlib's `README`, which holds
its licence) into each `dist` tree:

```
dist/<arch|universal>/usr/local/share/imagemagick/licenses/
├── LICENSE, NOTICE                 ImageMagick licences
└── vendors/<software_name>/...     one folder per dependency (ghostscript, libheif, x265, etc.)
```

The location follows `DIST_PREFIX` and `DIST_LICENSES_DIR`. A warning is printed
for any package from which no licence file could be found. Since the `.pkg`
installers are built from these trees, they install the licences too.

---

## 9. Contributing

Contributions are welcome! See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to
contribute.

This project has a [Code of Conduct](CODE_OF_CONDUCT.md). By interacting with
this repository, organization, or community you agree to abide by its terms.

### Basic steps

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Submit a pull request
