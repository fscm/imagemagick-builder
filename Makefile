# SPDX-FileCopyrightText: 2026 Frederico Martins
# SPDX-License-Identifier: GPL-3.0-only
# =============================================================================
# ImageMagick and Ghostscript: static, universal build system for macOS
# =============================================================================
# See README.md for full documentation and DEPENDENCIES.txt for the dependency
# map (which this Makefile reads). Compatible with the GNU Make 3.81 that ships
# with macOS.
#
#   make                 build everything -> $(OUTPUT_DIR)/<arch|universal>$(DIST_PREFIX)/bin/{magick,gs}
#   make help            list all targets
#   make libheif         (re)build one dependency for every architecture
#   make libheif-arm64   build one dependency for one architecture
#   make ARCHS=arm64     build a single architecture only
#
# You can override every setting below on the command line, from the
# environment, or in an optional config.mk placed next to this Makefile.
# =============================================================================

SHELL := /bin/bash
.SUFFIXES:
.DEFAULT_GOAL := all

ifneq ($(shell uname -s),Darwin)
$(error This Makefile only supports macOS (Darwin))
endif

MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# Optional user overrides (versions, paths, flags, etc.)
-include $(MAKEFILE_DIR)config.mk

# -----------------------------------------------------------------------------
# 1. General configuration
# -----------------------------------------------------------------------------
# Architectures to build: 'x86_64 arm64' (universal) or just one of them.
ARCHS                    ?= x86_64 arm64
# Minimum macOS version for the binaries you build (arm64 needs >= 11.0).
MACOSX_DEPLOYMENT_TARGET ?= 11.0
TARGET_CC                ?= clang
TARGET_CXX               ?= clang++
MACOS_SDK                ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
JOBS                     ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
STRIP_BINARIES           ?= yes
# CMake comes from the system (see README.md).
CMAKE                    ?= cmake
# Prefixes CMake must NOT search (keeps Homebrew/MacPorts libraries out).
CMAKE_IGNORE_PREFIXES    ?= /opt/homebrew;/usr/local;/opt/local
# macOS installer package (.pkg) settings.
# Default: <current user name, lower case>.imagemagick (e.g. user
# 'Alice' -> alice.imagemagick).
PKG_IDENTIFIER           ?= $(shell id -un | tr '[:upper:]' '[:lower:]').imagemagick
PKG_VERSION              ?= $(IMAGEMAGICK_VERSION)
OPT_FLAGS                ?= -O2
# Old code bases (jbigkit, djvulibre, etc.) fail on errors that modern clang
# promotes from warnings. The build downgrades them again.
LEGACY_WARN              ?= -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types
# ImageMagick build flavour.
IM_QUANTUM_DEPTH         ?= 16
IM_HDRI                  ?= yes
# Build the bundled Tesseract OCR devices in Ghostscript? (yes/no).
GS_TESSERACT             ?= yes
# Folders Ghostscript searches for extra (system) fonts, ':' separated.
GS_FONTPATH              ?= /Library/Fonts:/System/Library/Fonts
# Formats (as listed by 'magick -list format') that 'make verify' requires.
REQUIRED_FORMATS         ?= JPEG PNG GIF TIFF WEBP HEIC AVIF JXL JP2 EXR DJVU DNG PDF PS SVG
# Delegates (as listed by 'magick -version') that 'make verify' requires.
REQUIRED_DELEGATES       ?= bzlib djvu fftw fontconfig freetype gslib heic jbig jp2 jpeg jxl lcms lzma openexr png raw tiff uhdr webp xml zlib zstd
# File extensions 'make verify' encodes and decodes again with the new magick.
VERIFY_ROUNDTRIP         ?= png jpg tif webp avif heic jxl jp2 exr

# -----------------------------------------------------------------------------
# 2. Folders (all relocatable. Avoid spaces in paths)
# -----------------------------------------------------------------------------
BASE_DIR          ?= $(patsubst %/,%,$(MAKEFILE_DIR))
DOWNLOAD_DIR      ?= $(BASE_DIR)/downloads     # source tarballs
TOOLCHAIN_DIR     ?= $(BASE_DIR)/toolchain     # pkgconf, autoconf, automake, nasm ...
BUILD_DIR         ?= $(BASE_DIR)/build         # per-arch extracted/compiled sources
DEPS_DIR          ?= $(BASE_DIR)/deps          # per-arch static libs: $(DEPS_DIR)/<arch>
OUTPUT_DIR        ?= $(BASE_DIR)/dist          # final results (see 'make dist')
DEPENDENCIES_FILE ?= $(BASE_DIR)/DEPENDENCIES.txt
PACKAGE_DIR       ?= $(BASE_DIR)/packages      # .pkg installers (see 'make package')

# The build recreates the install prefix inside every $(OUTPUT_DIR)/<arch> and
# $(OUTPUT_DIR)/universal folder, e.g. dist/arm64/usr/local/bin/magick. It
# normalises it to start with '/' and not end with one. It also compiles it
# into fontconfig (configuration folder <prefix>/<DIST_FONT_DIR>), so changing
# it needs 'make rebuild-fontconfig'.
DIST_PREFIX         ?= /usr/local
# Folder (relative to the prefix) that receives the collected licence files. The
# ImageMagick licences go directly inside it, every other package's (including
# Ghostscript) into vendors/<software_name>/. The build normalises it to neither
# start nor end with '/'.
DIST_LICENSES_DIR   ?= share/imagemagick/licenses
# Folder (relative to the prefix) that holds fontconfig's configuration
# (fonts.conf, conf.d, conf.avail). The build compiles it into fontconfig, so
# changing it needs 'make rebuild-fontconfig'. The build normalises it to
# neither start nor end with '/'.
DIST_FONT_DIR       ?= share/imagemagick/fonts
# Folder (relative to the prefix) that receives Ghostscript's shared data, and
# which parts of it: iccprofiles (.icc), lib (.ps, .upp, .ppd, ...) and
# Resource. The build skips items it did not install. It builds gs to search
# this folder (see GHOSTSCRIPT_LIB_DEFAULT), so changing DIST_PREFIX or
# DIST_GS_SHARE_DIR needs 'make rebuild-ghostscript'. Normalised like
# DIST_LICENSES_DIR.
DIST_GS_SHARE_DIR   ?= share/ghostscript
DIST_GS_SHARE_ITEMS ?= iccprofiles lib Resource

override DOWNLOAD_DIR      := $(abspath $(strip $(DOWNLOAD_DIR)))
override TOOLCHAIN_DIR     := $(abspath $(strip $(TOOLCHAIN_DIR)))
override BUILD_DIR         := $(abspath $(strip $(BUILD_DIR)))
override DEPS_DIR          := $(abspath $(strip $(DEPS_DIR)))
override OUTPUT_DIR        := $(abspath $(strip $(OUTPUT_DIR)))
override PACKAGE_DIR       := $(abspath $(strip $(PACKAGE_DIR)))
override DIST_PREFIX       := $(patsubst %/,%,/$(patsubst /%,%,$(strip $(DIST_PREFIX))))
override DIST_LICENSES_DIR := $(patsubst %/,%,$(patsubst /%,%,$(strip $(DIST_LICENSES_DIR))))
override DIST_FONT_DIR     := $(patsubst %/,%,$(patsubst /%,%,$(strip $(DIST_FONT_DIR))))
override DIST_GS_SHARE_DIR := $(patsubst %/,%,$(patsubst /%,%,$(strip $(DIST_GS_SHARE_DIR))))

# Folder (inside OUTPUT_DIR) that holds the "main" result. Universal if several
# archs, else the single arch.
DIST_MAIN  = $(OUTPUT_DIR)/$(if $(word 2,$(ARCHS)),universal,$(firstword $(ARCHS)))$(DIST_PREFIX)

# What the build copies into the dist trees (only these come from the per-arch
# prefixes).
DIST_BINARIES     ?= magick gs
DIST_IM_LINKS     ?= convert identify mogrify compare composite montage stream conjure
DIST_GS_SCRIPTS   ?= ps2pdf ps2pdf12 ps2pdf13 ps2pdf14 ps2pdfwr ps2ps ps2ps2 ps2ascii pdf2ps eps2eps dvipdf pf2afm pfbtopfa printafm gsbj gsdj gsdj500 gslj gslp gsnd
DIST_MAN          ?= man1/gs.1 man1/ps2pdf.1 man1/ps2pdfwr.1 man1/ps2ps.1 man1/pdf2ps.1 man1/eps2eps.1 man1/ps2ascii.1 man1/dvipdf.1 man1/pf2afm.1 man1/pfbtopfa.1 man1/printafm.1 man1/gsnd.1 man1/gslp.1 man1/gsbj.1 man1/gsdj.1 man1/gsdj500.1 man1/gslj.1

# -----------------------------------------------------------------------------
# 3. What gets built
# -----------------------------------------------------------------------------
# Native build tools -> $(TOOLCHAIN_DIR). nasm assembles the x86_64 SIMD code
# of libjpeg-turbo, x265 and libaom. CMake itself comes from the system.
TOOLS    := m4 autoconf automake libtool pkgconf nasm
# Static libraries -> $(DEPS_DIR)/<arch> (order/relations: DEPENDENCIES.txt).
PACKAGES := zlib bzip2 xz zstd brotli libdeflate libpng libjpeg-turbo jbigkit \
            libwebp libtiff lcms2 openjpeg freetype expat fontconfig libxml2 \
            imath openjph openexr highway libjxl libultrahdr libde265 x265 aom \
            libheif libraw fftw djvulibre ghostscript
ALL_PKGS := $(PACKAGES) imagemagick
DL_LIST  := $(TOOLS) $(ALL_PKGS)

# -----------------------------------------------------------------------------
# 4. Versions, download URLs and (optional) SHA-256 checksums.
#    Bump a version here (or in config.mk) and run: make rebuild-<package>
#    Set <PKG>_SHA256 to enable checksum verification of that download
#    ('make checksums' prints the SHA-256 of every downloaded archive).
#    <PKG>_ARCHIVE overrides the saved file name (GitHub tag archives are all
#    called v1.2.3.tar.gz, which would clash in downloads/).
# -----------------------------------------------------------------------------
# --- toolchain ---
M4_VERSION       ?= 1.4.21
M4_URL           ?= https://ftp.gnu.org/gnu/m4/m4-$(M4_VERSION).tar.xz
M4_SHA256        ?= f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66
AUTOCONF_VERSION ?= 2.73
AUTOCONF_URL     ?= https://ftp.gnu.org/gnu/autoconf/autoconf-$(AUTOCONF_VERSION).tar.xz
AUTOCONF_SHA256  ?= 9fd672b1c8425fac2fa67fa0477b990987268b90ff36d5f016dae57be0d6b52e
AUTOMAKE_VERSION ?= 1.19
AUTOMAKE_URL     ?= https://ftp.gnu.org/gnu/automake/automake-$(AUTOMAKE_VERSION).tar.xz
AUTOMAKE_SHA256  ?= e3e2c2e3abf37898138db5b6c1d1dc35c9160c5978be7947d2c741705251d445
LIBTOOL_VERSION  ?= 2.6.2
LIBTOOL_URL      ?= https://ftp.gnu.org/gnu/libtool/libtool-$(LIBTOOL_VERSION).tar.xz
LIBTOOL_SHA256   ?= 2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e
PKGCONF_VERSION  ?= 3.0.7
PKGCONF_URL      ?= https://distfiles.ariadne.space/pkgconf/pkgconf-$(PKGCONF_VERSION).tar.xz
PKGCONF_SHA256   ?= c926ff491cbd9a331a589160811bd97ab1749b4d5198a519338f2cdfabe6940a
NASM_VERSION     ?= 3.02
NASM_URL         ?= https://www.nasm.us/pub/nasm/releasebuilds/$(NASM_VERSION)/nasm-$(NASM_VERSION).tar.xz
NASM_SHA256      ?= 87336eba53b4acfe917424ab5d500d2b0054d9f5148d35c2273ccf2cfb712f0d

# --- libraries: compression ---
ZLIB_VERSION         ?= 1.3.2
ZLIB_URL             ?= https://github.com/madler/zlib/releases/download/v$(ZLIB_VERSION)/zlib-$(ZLIB_VERSION).tar.xz
ZLIB_SHA256          ?= d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3
BZIP2_VERSION        ?= 1.0.8
BZIP2_URL            ?= https://sourceware.org/pub/bzip2/bzip2-$(BZIP2_VERSION).tar.gz
BZIP2_SHA256         ?= ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
XZ_VERSION           ?= 5.8.4
XZ_URL               ?= https://github.com/tukaani-project/xz/releases/download/v$(XZ_VERSION)/xz-$(XZ_VERSION).tar.xz
XZ_SHA256            ?= 4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
ZSTD_VERSION         ?= 1.5.7
ZSTD_URL             ?= https://github.com/facebook/zstd/releases/download/v$(ZSTD_VERSION)/zstd-$(ZSTD_VERSION).tar.gz
ZSTD_SHA256          ?= eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
BROTLI_VERSION       ?= 1.2.0
BROTLI_URL           ?= https://github.com/google/brotli/archive/refs/tags/v$(BROTLI_VERSION).tar.gz
BROTLI_ARCHIVE       ?= brotli-$(BROTLI_VERSION).tar.gz
BROTLI_SHA256        ?= 816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec
LIBDEFLATE_VERSION   ?= 1.26
LIBDEFLATE_URL       ?= https://github.com/ebiggers/libdeflate/releases/download/v$(LIBDEFLATE_VERSION)/libdeflate-$(LIBDEFLATE_VERSION).tar.gz
LIBDEFLATE_SHA256    ?= 125856d4656e0feab660f94842f835923410c9281fedbcee64598c918da42b5a

# --- libraries: image formats ---
LIBPNG_VERSION       ?= 1.6.59
LIBPNG_URL           ?= https://downloads.sourceforge.net/project/libpng/libpng16/$(LIBPNG_VERSION)/libpng-$(LIBPNG_VERSION).tar.xz
LIBPNG_SHA256        ?= d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
LIBJPEG_TURBO_VERSION ?= 3.2.0
LIBJPEG_TURBO_URL    ?= https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$(LIBJPEG_TURBO_VERSION)/libjpeg-turbo-$(LIBJPEG_TURBO_VERSION).tar.gz
LIBJPEG_TURBO_SHA256 ?= 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
JBIGKIT_VERSION      ?= 2.2
JBIGKIT_URL          ?= https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-$(JBIGKIT_VERSION).tar.gz
JBIGKIT_SHA256       ?= 3302109c93b7befbffa3cfe8bceb4355f19dea0ee7dcb5f33710b1648bf6645c
LIBWEBP_VERSION      ?= 1.6.0
LIBWEBP_URL          ?= https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$(LIBWEBP_VERSION).tar.gz
LIBWEBP_SHA256       ?= e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
LIBTIFF_VERSION      ?= 4.7.2
LIBTIFF_URL          ?= https://download.osgeo.org/libtiff/tiff-$(LIBTIFF_VERSION).tar.gz
LIBTIFF_SHA256       ?= 672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a
LCMS2_VERSION        ?= 2.19.1
LCMS2_URL            ?= https://github.com/mm2/Little-CMS/releases/download/lcms$(LCMS2_VERSION)/lcms2-$(LCMS2_VERSION).tar.gz
LCMS2_SHA256         ?= bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8
OPENJPEG_VERSION     ?= 2.5.4
OPENJPEG_URL         ?= https://github.com/uclouvain/openjpeg/archive/refs/tags/v$(OPENJPEG_VERSION).tar.gz
OPENJPEG_ARCHIVE     ?= openjpeg-$(OPENJPEG_VERSION).tar.gz
OPENJPEG_SHA256      ?= a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a
IMATH_VERSION        ?= 3.2.3
IMATH_URL            ?= https://github.com/AcademySoftwareFoundation/Imath/archive/refs/tags/v$(IMATH_VERSION).tar.gz
IMATH_ARCHIVE        ?= Imath-$(IMATH_VERSION).tar.gz
IMATH_SHA256         ?= e10c12b3f21f45bf08e09d4215d9c7691368d747beebd840de0b6fefed2df9f8
OPENJPH_VERSION      ?= 0.32.0
OPENJPH_URL          ?= https://github.com/aous72/OpenJPH/archive/refs/tags/$(OPENJPH_VERSION).tar.gz
OPENJPH_ARCHIVE      ?= OpenJPH-$(OPENJPH_VERSION).tar.gz
OPENJPH_SHA256       ?= 5cb1ebe18e5ee1322d23ff2130b37562d447d1ad5586c3d16cf84be3ae30f719
OPENEXR_VERSION      ?= 3.5.2
OPENEXR_URL          ?= https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v$(OPENEXR_VERSION).tar.gz
OPENEXR_ARCHIVE      ?= openexr-$(OPENEXR_VERSION).tar.gz
OPENEXR_SHA256       ?= 85a291b9b8563fabef1aa3f6e912d744ce1d4b9fd5a8f978eda194cd51b15ae9
HIGHWAY_VERSION      ?= 1.4.0
HIGHWAY_URL          ?= https://github.com/google/highway/releases/download/$(HIGHWAY_VERSION)/highway-$(HIGHWAY_VERSION).tar.gz
HIGHWAY_SHA256       ?= 36f672ab48ddb3c8555e9e89e16fe400cd7d16c6eb455a1a3d0c146a63ababdc
LIBJXL_VERSION       ?= 0.12.0
LIBJXL_URL           ?= https://github.com/libjxl/libjxl/archive/refs/tags/v$(LIBJXL_VERSION).tar.gz
LIBJXL_ARCHIVE       ?= libjxl-$(LIBJXL_VERSION).tar.gz
LIBJXL_SHA256        ?= 03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992
LIBULTRAHDR_VERSION  ?= 2.0.2
LIBULTRAHDR_URL      ?= https://github.com/google/libultrahdr/archive/refs/tags/v$(LIBULTRAHDR_VERSION).tar.gz
LIBULTRAHDR_ARCHIVE  ?= libultrahdr-$(LIBULTRAHDR_VERSION).tar.gz
LIBULTRAHDR_SHA256   ?= aa8d193bb887c348c419780511dd03b374f4e07af8812b6d3f80c8537cf1ef2c
LIBDE265_VERSION     ?= 1.1.3
LIBDE265_URL         ?= https://github.com/strukturag/libde265/releases/download/v$(LIBDE265_VERSION)/libde265-$(LIBDE265_VERSION).tar.gz
LIBDE265_SHA256      ?= 554228bd17788c99a7e63b37ab5634722190e6e2bf60c1dcb01cef328e133905
X265_VERSION         ?= 4.3
X265_URL             ?= https://github.com/Multicorewareinc/x265/releases/download/$(X265_VERSION)/x265_$(X265_VERSION).tar.gz
X265_SHA256          ?= 83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121
AOM_VERSION          ?= 3.15.2
AOM_URL              ?= https://storage.googleapis.com/aom-releases/libaom-$(AOM_VERSION).tar.gz
AOM_SHA256           ?= 67bb54b245f33ed98600e08269e6139986e48114e14042474ddd8885801dfddc
LIBHEIF_VERSION      ?= 1.23.6
LIBHEIF_URL          ?= https://github.com/strukturag/libheif/releases/download/v$(LIBHEIF_VERSION)/libheif-$(LIBHEIF_VERSION).tar.gz
LIBHEIF_SHA256       ?= 4484346dc5995319dbc11e3a1c35d0a2ec46511ce370900869337fd2c7033125
LIBRAW_VERSION       ?= 0.22.2
LIBRAW_URL           ?= https://www.libraw.org/data/LibRaw-$(LIBRAW_VERSION).tar.gz
LIBRAW_SHA256        ?= de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa
DJVULIBRE_VERSION    ?= 3.5.30
DJVULIBRE_URL        ?= https://downloads.sourceforge.net/project/djvu/DjVuLibre/$(DJVULIBRE_VERSION)/djvulibre-$(DJVULIBRE_VERSION).tar.gz
DJVULIBRE_SHA256     ?= ee5e457d4cfebe566f94b99e5e3d3cc7f5c79ddb741c2ac2ba2e456f00329644
FFTW_VERSION         ?= 3.3.11
FFTW_URL             ?= https://www.fftw.org/fftw-$(FFTW_VERSION).tar.gz
FFTW_SHA256          ?= 5630c24cdeb33b131612f7eb4b1a9934234754f9f388ff8617458d0be6f239a1

# --- libraries: fonts and XML ---
FREETYPE_VERSION     ?= 2.14.3
FREETYPE_URL         ?= https://download.savannah.gnu.org/releases/freetype/freetype-$(FREETYPE_VERSION).tar.xz
FREETYPE_SHA256      ?= 36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
EXPAT_VERSION        ?= 2.9.0
EXPAT_URL            ?= https://github.com/libexpat/libexpat/releases/download/R_$(subst .,_,$(EXPAT_VERSION))/expat-$(EXPAT_VERSION).tar.xz
EXPAT_SHA256         ?= 1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051
FONTCONFIG_VERSION   ?= 2.16.0
FONTCONFIG_URL       ?= https://www.freedesktop.org/software/fontconfig/release/fontconfig-$(FONTCONFIG_VERSION).tar.xz
FONTCONFIG_SHA256    ?= 6a33dc555cc9ba8b10caf7695878ef134eeb36d0af366041f639b1da9b6ed220
LIBXML2_VERSION      ?= 2.15.4
LIBXML2_URL          ?= https://github.com/GNOME/libxml2/archive/refs/tags/v$(LIBXML2_VERSION).tar.gz
LIBXML2_ARCHIVE      ?= libxml2-$(LIBXML2_VERSION).tar.gz
LIBXML2_SHA256       ?= bb01bd9ac9a7403f9706816fd6d3e7888041d32b0211075feb20e755d2a9f29d

# --- Ghostscript and ImageMagick themselves ---
GHOSTSCRIPT_VERSION  ?= 10.08.0
GHOSTSCRIPT_URL      ?= https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs$(subst .,,$(GHOSTSCRIPT_VERSION))/ghostscript-$(GHOSTSCRIPT_VERSION).tar.xz
GHOSTSCRIPT_SHA256   ?= c20492bc8ebb96c87fa2e52a0926e1cda8cde95d66145e018ac713fed5da38cf
IMAGEMAGICK_VERSION  ?= 7.1.2-33
IMAGEMAGICK_URL      ?= https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$(IMAGEMAGICK_VERSION).tar.gz
IMAGEMAGICK_ARCHIVE  ?= ImageMagick-$(IMAGEMAGICK_VERSION).tar.gz
IMAGEMAGICK_SHA256   ?= c768ff077cccff1b682aa56653b54247b268752427ca998992b24cc7c597d9e7

# -----------------------------------------------------------------------------
# 5. Per-package configure options / hooks
#    <PKG>_CFG       extra ./configure arguments (autotools packages)
#    <PKG>_CMAKE     extra CMake arguments. Setting it makes the package a CMake
#                    package (cmake configure/build/install instead of autotools)
#    <PKG>_CMAKE_SRC CMake source folder inside the source tree (default '.')
#    <PKG>_CONFIGURE complete replacement for the configure command
#    <PKG>_PRE       shell commands run in the source dir before configure
#    <PKG>_BUILD     replacement for the build command   (default: make -jN)
#    <PKG>_INSTALL   replacement for the install command (default: make install)
#    <PKG>_POST      shell commands run after install
#    In these snippets $$pfx is the per-arch install prefix, $$ARCH the arch
#    being built and 'cmk' a shell function that runs cmake with the common
#    options (arch, deployment target, prefix, static, no Homebrew paths).
# -----------------------------------------------------------------------------
PKGCONF_CFG      ?= --disable-shared --enable-static
NASM_CFG         ?=

# <PKG>_LICENSE_FILES: extra files (paths relative to the source root) that hold
# a licence ('make licenses' picks them up).
ZLIB_LICENSE_FILES ?= README

# ---- compression ----
ZLIB_CONFIGURE   ?= ./configure --prefix="$$pfx" --static
# bzip2 has no configure script: build only the static library by hand.
BZIP2_CONFIGURE  ?= :
BZIP2_BUILD      ?= $(MAKE) libbz2.a CC="$$CC" AR=ar RANLIB=ranlib CFLAGS="$$CFLAGS -D_FILE_OFFSET_BITS=64"
BZIP2_INSTALL    ?= mkdir -p "$$pfx/lib" "$$pfx/include" && cp libbz2.a "$$pfx/lib/" && cp bzlib.h "$$pfx/include/" && ranlib "$$pfx/lib/libbz2.a"
XZ_CFG           ?= --quiet --enable-silent-rules --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-lzma-links --disable-scripts --disable-doc --disable-nls
ZSTD_CMAKE_SRC   ?= build/cmake
ZSTD_CMAKE       ?= -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
BROTLI_CMAKE     ?= -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
# Make sure the library names the .pc files refer to (-lbrotlicommon ...) exist.
BROTLI_POST      ?= for n in common dec enc; do if [ -f "$$pfx/lib/libbrotli$$n-static.a" ] && [ ! -f "$$pfx/lib/libbrotli$$n.a" ]; then cp "$$pfx/lib/libbrotli$$n-static.a" "$$pfx/lib/libbrotli$$n.a"; fi; done
LIBDEFLATE_CMAKE ?= -DLIBDEFLATE_BUILD_STATIC_LIB=ON -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF

# ---- image formats ----
LIBPNG_CFG       ?= --quiet --enable-silent-rules
LIBJPEG_TURBO_CMAKE ?= -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_JPEG8=ON -DWITH_TURBOJPEG=ON -DWITH_TOOLS=OFF -DWITH_FUZZ=OFF -DCMAKE_ASM_NASM_COMPILER="$(TOOLCHAIN_DIR)/bin/nasm"
# jbigkit has no configure either; the build needs only libjbig and libjbig85.
JBIGKIT_CONFIGURE ?= :
JBIGKIT_BUILD    ?= $(MAKE) -C libjbig libjbig.a libjbig85.a CC="$$CC" CFLAGS="$$CFLAGS"
JBIGKIT_INSTALL  ?= mkdir -p "$$pfx/lib" "$$pfx/include" && cp libjbig/libjbig.a libjbig/libjbig85.a "$$pfx/lib/" && cp libjbig/jbig.h libjbig/jbig_ar.h libjbig/jbig85.h "$$pfx/include/" && ranlib "$$pfx/lib/libjbig.a" "$$pfx/lib/libjbig85.a"
LIBWEBP_CFG      ?= --quiet --enable-silent-rules --enable-libwebpmux --enable-libwebpdemux --enable-libwebpdecoder --enable-libwebpextras --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
LIBTIFF_CFG      ?= --quiet --enable-silent-rules --enable-zlib --enable-jpeg --enable-jbig --enable-lzma --enable-zstd --enable-webp --enable-libdeflate --disable-lerc --disable-tools --disable-tests --disable-contrib --disable-docs --without-x
LCMS2_CFG        ?= --quiet --enable-silent-rules --without-jpeg --without-tiff --without-zlib
OPENJPEG_CMAKE   ?= -DBUILD_CODEC=OFF -DBUILD_DOC=OFF -DBUILD_JPIP=OFF -DBUILD_UNIT_TESTS=OFF -DBUILD_TESTING=OFF -DBUILD_STATIC_LIBS=ON
IMATH_CMAKE      ?= -DBUILD_TESTING=OFF -DPYTHON=OFF -DBUILD_WEBSITE=OFF
OPENJPH_CMAKE    ?= -DOJPH_BUILD_EXECUTABLES=OFF -DOJPH_BUILD_TESTS=OFF -DOJPH_BUILD_STREAM_EXPAND=OFF -DOJPH_ENABLE_TIFF_SUPPORT=OFF
OPENEXR_CMAKE    ?= -DBUILD_TESTING=OFF -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_INSTALL_PKG_CONFIG=ON -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_OPENJPH=OFF -DOPENEXR_FORCE_INTERNAL_ZSTD=OFF
HIGHWAY_CMAKE    ?= -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=ON -DHWY_ENABLE_INSTALL=ON -DHWY_FORCE_STATIC_LIBS=ON
# The libjxl release archive has no git submodules, so brotli, highway and
# lcms2 come from this toolchain (no skcms, no jpegli, no tools).
LIBJXL_CMAKE     ?= -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DBUILD_TESTING=OFF
LIBULTRAHDR_CMAKE ?= -DUHDR_BUILD_EXAMPLES=OFF -DUHDR_BUILD_TESTS=OFF -DUHDR_BUILD_BENCHMARK=OFF -DUHDR_BUILD_DEPS=OFF -DUHDR_ENABLE_INSTALL=ON -DUHDR_ENABLE_HEIF=OFF
LIBDE265_CMAKE   ?= -DENABLE_SDL=OFF -DENABLE_DECODER=ON -DENABLE_ENCODER=OFF
AOM_CMAKE        ?= -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_TESTDATA=0 -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 -DCONFIG_RUNTIME_CPU_DETECT=1 -DAOM_TARGET_CPU="$$ARCH" -DCMAKE_ASM_NASM_COMPILER="$(TOOLCHAIN_DIR)/bin/nasm"
# x265 uses the official multilib recipe: the build links the 12-bit and 10-bit
# libraries into the 8-bit one and merges the three archives into a single
# libx265.a. (The build uses Apple's own libtool on purpose: GNU libtool is
# first in the PATH).
X265_CONFIGURE   ?= rm -rf _b8 _b10 _b12; \
	x265_common="-DENABLE_CLI=OFF -DENABLE_SHARED=OFF -DENABLE_TESTS=OFF -DENABLE_LIBNUMA=OFF -DCMAKE_ASM_NASM_COMPILER=$(TOOLCHAIN_DIR)/bin/nasm"; \
	cmk -S source -B _b12 $$x265_common -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF; \
	cmk -S source -B _b10 $$x265_common -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF; \
	cmk -S source -B _b8  $$x265_common -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
X265_BUILD       ?= cmake --build _b12 -j $(JOBS) && cmake --build _b10 -j $(JOBS) && \
	ln -sf ../_b12/libx265.a _b8/libx265_main12.a && ln -sf ../_b10/libx265.a _b8/libx265_main10.a && \
	cmake --build _b8 -j $(JOBS) && \
	mv _b8/libx265.a _b8/libx265_main.a && \
	/usr/bin/libtool -static -o _b8/libx265.a _b8/libx265_main.a _b8/libx265_main10.a _b8/libx265_main12.a
X265_INSTALL     ?= cmake --install _b8
X265_POST        ?= if [ -f "$$pfx/lib/pkgconfig/x265.pc" ]; then sed -e 's/-lstdc++/-lc++/g' -e 's/-lgcc_s//g' -e 's/-lgcc//g' "$$pfx/lib/pkgconfig/x265.pc" > "$$pfx/lib/pkgconfig/x265.pc.tmp" && mv "$$pfx/lib/pkgconfig/x265.pc.tmp" "$$pfx/lib/pkgconfig/x265.pc"; fi
# libheif links every codec in statically (no plugins).
LIBHEIF_CMAKE    ?= -DENABLE_PLUGIN_LOADING=OFF -DWITH_EXAMPLES=OFF -DWITH_EXAMPLE_HEIF_THUMB=OFF -DWITH_EXAMPLE_HEIF_VIEW=OFF -DWITH_GDK_PIXBUF=OFF -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF -DWITH_LIBDE265=ON -DWITH_X265=ON -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF -DWITH_KVAZAAR=OFF -DWITH_AOM_DECODER=ON -DWITH_AOM_ENCODER=ON -DWITH_DAV1D=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF -DWITH_JPEG_DECODER=ON -DWITH_JPEG_ENCODER=ON -DWITH_OpenJPEG_DECODER=ON -DWITH_OpenJPEG_ENCODER=ON -DWITH_OPENJPH_ENCODER=ON -DWITH_UNCOMPRESSED_CODEC=ON -DWITH_FFMPEG_DECODER=OFF -DWITH_LIBSHARPYUV=ON
LIBRAW_CFG       ?= --quiet --enable-silent-rules --disable-examples --disable-openmp --enable-lcms --enable-jpeg --enable-zlib
FFTW_CFG         ?= --quiet --enable-silent-rules --disable-fortran --disable-doc
DJVULIBRE_CFG    ?= --quiet --enable-silent-rules --disable-desktopfiles --disable-xmltools --disable-i18n --with-jpeg="$$pfx"

# ---- fonts and XML ----
FREETYPE_CFG       ?= --quiet --enable-silent-rules --with-zlib=yes --with-bzip2=yes --with-png=yes --with-brotli=yes --with-harfbuzz=no
EXPAT_CFG          ?= --quiet --enable-silent-rules --without-docbook --without-examples --without-tests --without-xmlwf
# fontconfig compiles its configuration folder (fonts.conf, conf.d and the
# conf.avail templates the conf.d links point to) in as
# <DIST_PREFIX>/<DIST_FONT_DIR> (not the build prefix), so 'make install' runs
# into a staging folder and the build keeps that folder in
# $$pfx/<DIST_FONT_DIR> for 'make dist'. It still reads the fonts themselves
# from the --with-default-fonts and --with-add-fonts folders.
FONTCONFIG_CFG     ?= --quiet --enable-silent-rules --disable-docs --disable-nls --disable-cache-build --with-baseconfigdir="$(DIST_PREFIX)/$(DIST_FONT_DIR)" --with-templatedir="$(DIST_PREFIX)/$(DIST_FONT_DIR)/conf.avail" --localstatedir="$(DIST_PREFIX)/var" --with-default-fonts="/System/Library/Fonts,/Library/Fonts" --with-add-fonts="~/Library/Fonts"
FONTCONFIG_INSTALL ?= stage="$$pfx/.fc-stage"; rm -rf "$$stage"; $(MAKE) install DESTDIR="$$stage" && cp -R "$$stage$$pfx/." "$$pfx/" && mkdir -p "$$pfx/$(DIST_FONT_DIR)" && cp -R "$$stage$(DIST_PREFIX)/$(DIST_FONT_DIR)/." "$$pfx/$(DIST_FONT_DIR)/" && rm -rf "$$stage"
LIBXML2_CMAKE      ?= -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_MODULES=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_ICONV=ON -DLIBXML2_WITH_LZMA=ON -DLIBXML2_WITH_ZLIB=ON -DLIBXML2_WITH_THREADS=ON

# ---- Ghostscript ----
# The build uses the library sources bundled in the Ghostscript tarball (jpeg,
# freetype, openjpeg, jbig2dec, lcms2mt, tiff, tesseract, etc.), so it does not
# use the libraries of this toolchain. It cross-compiles the non-native arch
# through CCAUX (native compiler for the helper programs the build runs).
GHOSTSCRIPT_LICENSE_FILES ?= DroidSansFallback.NOTICE
# Ghostscript writes a "%%Invocation: gs <arguments>" comment into the PDF (and
# PostScript) files it creates. Three functions write it:
#   pdfwrite_write_args_comment()   regular PDF and PS output   (gdevpdfu.c, 2 calls)
#   pdfwrite_fwrite_args_comment()  linearised PDF output       (gdevpdf.c, 1 call)
#   pdfimage_write_args_comment()   pdfimage8/24/32 devices     (gdevpdfimg.c, 1 call)
# The patch removes the calls rather than touching the functions (their bodies
# start with declarations, and Ghostscript is built with
# -Werror=declaration-after-statement). Three statements are deleted, and the
# assignment in gdevpdfimg.c becomes 'code = 0' (the function is static, so it
# stays referenced and avoids an unused-function warning). The build fails if
# any call remains.
GHOSTSCRIPT_STRIP_INVOCATION ?= yes
GHOSTSCRIPT_NO_INVOCATION ?= LC_ALL=C sed -e '/^[[:space:]]*pdfwrite_write_args_comment(pdev, s);[[:space:]]*$$/d' devices/vector/gdevpdfu.c > devices/vector/gdevpdfu.c.tmp && mv devices/vector/gdevpdfu.c.tmp devices/vector/gdevpdfu.c; \
	LC_ALL=C sed -e '/^[[:space:]]*pdfwrite_fwrite_args_comment(pdev, linear_params->Lin_File.file);[[:space:]]*$$/d' devices/vector/gdevpdf.c > devices/vector/gdevpdf.c.tmp && mv devices/vector/gdevpdf.c.tmp devices/vector/gdevpdf.c; \
	LC_ALL=C sed -e 's/code = pdfimage_write_args_comment(pdf_dev,pdf_dev->strm);/code = 0; (void)pdfimage_write_args_comment;/' devices/gdevpdfimg.c > devices/gdevpdfimg.c.tmp && mv devices/gdevpdfimg.c.tmp devices/gdevpdfimg.c; \
	if grep -Eq '^[[:space:]]+(code = )?(pdfwrite_write_args_comment|pdfwrite_fwrite_args_comment|pdfimage_write_args_comment)\(' devices/vector/gdevpdfu.c devices/vector/gdevpdf.c devices/gdevpdfimg.c; then echo "ERROR: could not remove the calls that write the %%Invocation comment"; exit 1; fi
GHOSTSCRIPT_PRE           ?= unset CPPFLAGS LDFLAGS PKG_CONFIG PKG_CONFIG_LIBDIR; export CCAUX="$(TARGET_CC) -arch $(NATIVE_ARCH) $(SYSROOT_FLAGS)" CFLAGSAUX="$(OPT_FLAGS)" CPPFLAGSAUX="" LDFLAGSAUX="" $(if $(filter yes,$(GHOSTSCRIPT_STRIP_INVOCATION)),; $(GHOSTSCRIPT_NO_INVOCATION))
# With '--without-versioned-path' ghostscript's data goes to
# share/ghostscript/{lib,Resource,iccprofiles,...} instead of
# share/ghostscript/<version>/..., and its documentation to share/doc/ghostscript.
# 'make dist' should find the data in either layout.
GHOSTSCRIPT_CFG           ?= --disable-cups --disable-dbus --disable-gtk --disable-fontconfig --without-x --without-libpaper --without-libidn --without-versioned-path --with-fontpath="$(GS_FONTPATH)" $(if $(filter no,$(GS_TESSERACT)),--without-tesseract)
# The build compiles this default search path into gs, pointing at the shared
# data that 'make dist' installs (see DIST_GS_SHARE_DIR). It also compiles the
# initialisation files and fonts into the program, so this is where gs looks
# for the extra files (lib/*.ps, *.upp, etc.). Set it empty to keep
# Ghostscript's default.
GHOSTSCRIPT_LIB_DEFAULT   ?= $(DIST_PREFIX)/$(DIST_GS_SHARE_DIR)/Resource/Init:$(DIST_PREFIX)/$(DIST_GS_SHARE_DIR)/lib:$(DIST_PREFIX)/$(DIST_GS_SHARE_DIR)/Resource/Font:$(DIST_PREFIX)/$(DIST_GS_SHARE_DIR)/fonts:$(GS_FONTPATH)
GS_MAKE_VARS               = $(if $(GHOSTSCRIPT_LIB_DEFAULT),GS_LIB_DEFAULT="$(GHOSTSCRIPT_LIB_DEFAULT)")
# Ghostscript's build system is not parallel-safe: fall back to a serial run.
GHOSTSCRIPT_BUILD         ?= ( $(MAKE) -j$(JOBS) $(GS_MAKE_VARS) || $(MAKE) -j1 $(GS_MAKE_VARS) ) && ( $(MAKE) -j$(JOBS) $(GS_MAKE_VARS) libgs || $(MAKE) -j1 $(GS_MAKE_VARS) libgs )
# With the default compiled-in initialisation files 'make install' skips the
# Resource and iccprofiles folders, so the build runs their install targets
# explicitly.
GHOSTSCRIPT_INSTALL       ?= $(MAKE) $(GS_MAKE_VARS) install && $(MAKE) $(GS_MAKE_VARS) install-resdata0 install-iccdata0
# For libgs.a the build pre-links every object of Ghostscript into ONE object
# that only exports the gsapi_* functions. bin/gs.a lists five members twice
# (imain.o, imainarg.o, iconfig.o, gconfig.o, gscdefs.o; the copies are
# identical), which a normal link ignores but a link that loads every member
# (-all_load) reports as 84 duplicate symbols, so the build unpacks the archive
# first ('ar x' keeps one copy). Everything else (its bundled jpeg, freetype,
# lcms2mt, etc.) stays private, so it cannot clash with the libraries
# ImageMagick links. ImageMagick's --with-gslib needs the headers, so the build
# puts them in include/ghostscript.
GHOSTSCRIPT_POST          ?= mkdir -p "$$pfx/lib" "$$pfx/include/ghostscript"; \
	if [ ! -f bin/gs.a ]; then echo "ERROR: Ghostscript did not produce bin/gs.a"; exit 1; fi; \
	grep -ho 'gsapi_[A-Za-z0-9_]*' psi/iapi.h | sort -u | sed 's/^/_/' > gsapi.exp; \
	rm -rf gsobj; mkdir gsobj; ( cd gsobj && ar x ../bin/gs.a ); \
	$(TARGET_CC) -arch "$$ARCH" $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -r -nostdlib -o gs_hidden.o gsobj/*.o -Wl,-exported_symbols_list,gsapi.exp; \
	rm -f "$$pfx/lib/libgs.a"; ar rcs "$$pfx/lib/libgs.a" gs_hidden.o; ranlib "$$pfx/lib/libgs.a"; \
	for h in psi/iapi.h psi/ierrors.h base/gserrors.h devices/gdevdsp.h; do cp "$$h" "$$pfx/include/ghostscript/"; done; \
	n=$$(nm -gU "$$pfx/lib/libgs.a" 2>/dev/null | grep -c ' [TDBSAC] ' || true); \
	echo "    libgs.a exports $$n global symbols"; \
	if [ "$$n" -gt 300 ]; then echo "WARNING: libgs.a exports too many symbols; hiding did not work, expect link clashes in ImageMagick"; fi

# ---- ImageMagick ----
# The build finds libraries through pkg-config (static mode). The extra LIBS
# cover libgs.a, which does not record its own dependencies (C++ for Tesseract,
# iconv).
# PSDelegate=gs makes delegates.xml call a plain 'gs' from the PATH instead of
# the path of a Ghostscript that might be installed on the build machine.
IMAGEMAGICK_EXTRA_LIBS ?= -lc++ -liconv -lm
IMAGEMAGICK_PRE  ?= export LIBS="$(IMAGEMAGICK_EXTRA_LIBS)"
IMAGEMAGICK_CFG  ?= --quiet --enable-silent-rules --disable-openmp --disable-opencl --disable-docs \
	--with-quantum-depth=$(IM_QUANTUM_DEPTH) $(if $(filter yes,$(IM_HDRI)),--enable-hdri,--disable-hdri) \
	--enable-zero-configuration --disable-installed --without-modules --without-x \
	--without-magick-plus-plus --without-perl --without-pango --without-rsvg --without-wmf --without-lqr \
	--without-raqm --without-zip --without-autotrace --without-dps --without-flif --without-fpx --without-gvc \
	--with-gslib --with-fftw --with-uhdr --with-djvu --with-heic --with-jxl --with-raw --with-openexr \
	--with-openjp2 --with-lcms --with-fontconfig --with-freetype --with-webp --with-tiff --with-xml \
	--with-lzma --with-zstd --with-bzlib --with-jbig --with-jpeg --with-png --with-zlib \
	PSDelegate=gs

# -----------------------------------------------------------------------------
# 6. Internals
# -----------------------------------------------------------------------------
NATIVE_ARCH   := $(shell uname -m)
triple_x86_64 := x86_64-apple-darwin
triple_arm64  := aarch64-apple-darwin

VALID_ARCHS := x86_64 arm64
$(foreach a,$(ARCHS),$(if $(filter $(a),$(VALID_ARCHS)),,$(error Unsupported architecture '$(a)'; use x86_64 and/or arm64)))
$(if $(strip $(ARCHS)),,$(error ARCHS is empty))
$(if $(triple_$(NATIVE_ARCH)),,$(error Unsupported host architecture '$(NATIVE_ARCH)'))
SYSROOT_FLAGS := $(if $(MACOS_SDK),-isysroot $(MACOS_SDK))

# ---- read DEPENDENCIES.txt -> <PKG>_DEPS variables ----
$(if $(wildcard $(DEPENDENCIES_FILE)),,$(error Cannot find $(DEPENDENCIES_FILE)))
uc = $(shell echo '$(1)' | tr 'a-z-' 'A-Z_')
DEP_TOKENS := $(shell sed -e 's/[\#].*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' -e '/^$$/d' -e 's/:[[:space:]]*/:/' -e 's/[[:space:]][[:space:]]*/:/g' '$(DEPENDENCIES_FILE)')
$(foreach t,$(DEP_TOKENS),$(eval $(call uc,$(firstword $(subst :, ,$(t))))_DEPS := $(wordlist 2,100,$(subst :, ,$(t)))))

# ---- helpers ----
pv      = $($(call uc,$(1))_$(2))
archive = $(DOWNLOAD_DIR)/$(or $(call pv,$(1),ARCHIVE),$(notdir $(call pv,$(1),URL)))
stamp   = $(DEPS_DIR)/$(2)/.stamps/$(1)-$(call pv,$(1),VERSION).stamp
tstamp  = $(TOOLCHAIN_DIR)/.stamps/$(1)-$(call pv,$(1),VERSION).stamp
TOOLCHAIN_STAMPS := $(foreach t,$(TOOLS),$(call tstamp,$(t)))

# Environment for native toolchain builds
tool_exports = export PATH="$(TOOLCHAIN_DIR)/bin:$$PATH"; \
	export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CC="$(TARGET_CC) -arch $(NATIVE_ARCH) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CFLAGS="$(OPT_FLAGS) $(LEGACY_WARN)"; \
	export MAKEINFO=true HELP2MAN=true; \
	unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR LIBS CPPFLAGS LDFLAGS;

# Environment for per-architecture library builds ($(1) = arch; needs $$pfx
# set). 'cmk' wraps cmake for the CMake based packages.
arch_exports = export PATH="$(TOOLCHAIN_DIR)/bin:$$PATH"; \
	export ARCH="$(1)"; \
	export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CC="$(TARGET_CC) -arch $(1) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)"; \
	export CXX="$(TARGET_CXX) -arch $(1) $(SYSROOT_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -stdlib=libc++"; \
	export CFLAGS="$(OPT_FLAGS) $(LEGACY_WARN)"; \
	export CXXFLAGS="$(OPT_FLAGS)"; \
	export CPPFLAGS="-I$$pfx/include"; \
	export LDFLAGS="-L$$pfx/lib"; \
	export PKG_CONFIG="$(TOOLCHAIN_DIR)/bin/pkgconf --static"; \
	export PKG_CONFIG_LIBDIR="$$pfx/lib/pkgconfig:$$pfx/share/pkgconfig"; \
	unset PKG_CONFIG_PATH LIBS; \
	export AR=ar RANLIB=ranlib; \
	export ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes; \
	export MAKEINFO=true; \
	cmk() { CC="$(TARGET_CC)" CXX="$(TARGET_CXX)" PKG_CONFIG="$(TOOLCHAIN_DIR)/bin/pkgconf" \
	  $(CMAKE) -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$$pfx" -DCMAKE_INSTALL_LIBDIR=lib \
	  -DCMAKE_OSX_ARCHITECTURES="$(1)" -DCMAKE_SYSTEM_PROCESSOR="$(1)" -DCMAKE_OSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)" \
	  $(if $(MACOS_SDK),-DCMAKE_OSX_SYSROOT="$(MACOS_SDK)") -DBUILD_SHARED_LIBS=OFF -DCMAKE_PREFIX_PATH="$$pfx" \
	  -DCMAKE_IGNORE_PREFIX_PATH="$(CMAKE_IGNORE_PREFIXES)" -DCMAKE_FIND_FRAMEWORK=NEVER -DCMAKE_FIND_APPBUNDLE=NEVER \
	  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$$@"; };

# Refresh config.sub/config.guess so old packages recognise arm64 macOS
refresh_config = for f in config.sub config.guess; do for t in $$(find . -name $$f -type f); do cp "$$(ls $(TOOLCHAIN_DIR)/share/automake-*/$$f | tail -n 1)" "$$t"; done; done

autoconf_cmd  = ./configure --prefix="$$pfx" --host=$(triple_$(2)) --build=$(triple_$(NATIVE_ARCH)) --enable-static --disable-shared --disable-dependency-tracking $(call pv,$(1),CFG)
cmake_cmd     = cmk -S "$(or $(call pv,$(1),CMAKE_SRC),.)" -B _cmake $(call pv,$(1),CMAKE)
configure_cmd = $(if $(call pv,$(1),CONFIGURE),$(call pv,$(1),CONFIGURE),$(if $(call pv,$(1),CMAKE),$(call cmake_cmd,$(1)),$(call autoconf_cmd,$(1),$(2))))
build_cmd     = $(if $(call pv,$(1),BUILD),$(call pv,$(1),BUILD),$(if $(call pv,$(1),CMAKE),$(CMAKE) --build _cmake -j $(JOBS),$(MAKE) -j$(JOBS)))
install_cmd   = $(if $(call pv,$(1),INSTALL),$(call pv,$(1),INSTALL),$(if $(call pv,$(1),CMAKE),$(CMAKE) --install _cmake,$(MAKE) install))

download = @set -e; mkdir -p "$(DOWNLOAD_DIR)"; \
	echo ">>> Downloading $(call pv,$(1),URL)"; \
	curl -sfL --retry 3 --connect-timeout 10 -o "$@.part" "$(call pv,$(1),URL)"; \
	if [ -n "$(call pv,$(1),SHA256)" ]; then echo "$(call pv,$(1),SHA256)  $@.part" | shasum -a 256 -c -; fi; \
	mv "$@.part" "$@"

build_tool = @set -e; \
	echo ">>> [toolchain] $(1) $(call pv,$(1),VERSION)"; \
	src="$(BUILD_DIR)/toolchain/$(1)"; \
	rm -rf "$$src"; mkdir -p "$$src" "$(dir $@)"; \
	tar -xf "$(call archive,$(1))" -C "$$src" --strip-components=1; \
	cd "$$src"; \
	$(tool_exports) \
	./configure --quiet --enable-silent-rules --prefix="$(TOOLCHAIN_DIR)" $(call pv,$(1),CFG); \
	$(MAKE) -j$(JOBS); \
	if [ -L "$(TOOLCHAIN_DIR)/bin/$(1)" ]; then rm -f "$(TOOLCHAIN_DIR)/bin/$(1)"; fi; \
	$(MAKE) install; \
	if [ "$(1)" = "pkgconf" ]; then ln -sf pkgconf "$(TOOLCHAIN_DIR)/bin/pkg-config"; fi; \
	touch "$@"

build_pkg = @set -e; \
	pfx="$(DEPS_DIR)/$(2)"; \
	echo ">>> [$(2)] $(1) $(call pv,$(1),VERSION)"; \
	src="$(BUILD_DIR)/$(2)/$(1)"; \
	rm -rf "$$src"; mkdir -p "$$src" "$$pfx/.stamps"; \
	tar -xf "$(call archive,$(1))" -C "$$src" --strip-components=1; \
	cd "$$src"; \
	$(call arch_exports,$(2)) \
	$(refresh_config); \
	$(or $(call pv,$(1),PRE),:); \
	$(call configure_cmd,$(1),$(2)); \
	$(call build_cmd,$(1)); \
	$(call install_cmd,$(1)); \
	$(or $(call pv,$(1),POST),:); \
	touch "$@"

# ---- rule templates ----
define DL_TEMPLATE
$(call archive,$(1)):
	$$(call download,$(1))
endef

define TOOL_TEMPLATE
$(call tstamp,$(1)): $(call archive,$(1)) $(foreach d,$(call pv,$(1),DEPS),$(call tstamp,$(d)))
	+$$(call build_tool,$(1))
.PHONY: $(1) clean-$(1) rebuild-$(1)
$(1): $(call tstamp,$(1))
clean-$(1):
	@rm -f "$(TOOLCHAIN_DIR)"/.stamps/$(1)-*.stamp
	@rm -rf "$(BUILD_DIR)/toolchain/$(1)"
rebuild-$(1): clean-$(1)
	@$$(MAKE) $(1)
endef

define PKG_PHONY
.PHONY: $(1) clean-$(1) rebuild-$(1)
$(1): $(foreach a,$(ARCHS),$(1)-$(a))
clean-$(1):
	@rm -f "$(DEPS_DIR)"/*/.stamps/$(1)-*.stamp
	@rm -rf "$(BUILD_DIR)"/*/$(1)
rebuild-$(1): clean-$(1)
	@$$(MAKE) $(1)
endef

define PKG_TEMPLATE
$(call stamp,$(1),$(2)): $(call archive,$(1)) $(foreach d,$(filter-out $(TOOLS),$(call pv,$(1),DEPS)),$(call stamp,$(d),$(2))) | $(TOOLCHAIN_STAMPS)
	+$$(call build_pkg,$(1),$(2))
.PHONY: $(1)-$(2)
$(1)-$(2): $(call stamp,$(1),$(2))
endef

$(foreach p,$(DL_LIST),$(eval $(call DL_TEMPLATE,$(p))))
$(foreach t,$(TOOLS),$(eval $(call TOOL_TEMPLATE,$(t))))
$(foreach p,$(ALL_PKGS),$(eval $(call PKG_PHONY,$(p))))
$(foreach p,$(ALL_PKGS),$(foreach a,$(ARCHS),$(eval $(call PKG_TEMPLATE,$(p),$(a)))))

# -----------------------------------------------------------------------------
# 7. Main targets
# -----------------------------------------------------------------------------
.PHONY: all check-system download checksums toolchain deps dist licenses package verify \
	info versions graph help clean distclean purge

all: check-system dist licenses
	@echo ""
	@echo "Build finished: $(DIST_MAIN)/bin/magick and $(DIST_MAIN)/bin/gs   (run 'make verify' to check them)"

check-system:
	@set -e; ok=1; \
	echo "Checking build prerequisites..."; \
	for t in clang clang++ make tar curl perl xcrun lipo otool strip shasum sed awk ar ranlib nm install; do \
	  if command -v $$t >/dev/null 2>&1; then echo "  [ok]      $$t"; else echo "  [MISSING] $$t"; ok=0; fi; \
	done; \
	if [ ! -x /usr/bin/libtool ]; then echo "  [MISSING] /usr/bin/libtool (Apple's, part of the Command Line Tools)"; ok=0; else echo "  [ok]      /usr/bin/libtool"; fi; \
	if command -v $(CMAKE) >/dev/null 2>&1; then echo "  [ok]      cmake ($$($(CMAKE) --version | head -n 1))"; \
	else echo "  [MISSING] cmake - see README.md"; ok=0; fi; \
	if xcode-select -p >/dev/null 2>&1; then echo "  [ok]      Command Line Tools ($$(xcode-select -p))"; \
	else echo "  [MISSING] Command Line Tools - run: xcode-select --install"; ok=0; fi; \
	if [ -z "$(MACOS_SDK)" ]; then echo "  [MISSING] macOS SDK (xcrun --show-sdk-path failed)"; ok=0; fi; \
	[ $$ok = 1 ] || { echo "Prerequisites missing - see README.md"; exit 1; }

download: $(foreach p,$(DL_LIST),$(call archive,$(p)))
	@echo "All source archives are in $(DOWNLOAD_DIR)"

# Print the SHA-256 of every downloaded archive, ready to paste into config.mk
checksums: download
	@$(foreach p,$(DL_LIST),echo "$(call uc,$(p))_SHA256 = $$(shasum -a 256 "$(call archive,$(p))" | cut -d' ' -f1)";)

toolchain: $(TOOLS)
deps: $(PACKAGES)

# $(1) = output folder name (an arch, or 'universal'), $(2) = archs merged into.
# it. One arch -> the build copies the files; several -> it merges them with
# lipo.
dist_assemble = out="$(OUTPUT_DIR)/$(1)$(DIST_PREFIX)"; first="$(DEPS_DIR)/$(firstword $(2))"; \
	echo ">>> dist: $(1) [$(2)] -> $$out"; \
	rm -rf "$(OUTPUT_DIR)/$(1)"; mkdir -p "$$out/bin" "$$out/lib" "$$out/include"; \
	for n in $(DIST_BINARIES); do \
	  f="$$first/bin/$$n"; o="$$out/bin/$$n"; \
	  if [ ! -e "$$f" ]; then echo "    note: $$f not found"; continue; fi; \
	  if [ "$(words $(2))" = "1" ]; then cp "$$f" "$$o"; \
	  else lipo -create $(foreach a,$(2),"$(DEPS_DIR)/$(a)/bin/$$n") -output "$$o"; fi; \
	  if [ "$(STRIP_BINARIES)" = "yes" ]; then strip -x "$$o"; fi; \
	done; \
	for n in $(DIST_IM_LINKS); do ln -s magick "$$out/bin/$$n"; done; \
	for n in $(DIST_GS_SCRIPTS); do \
	  if [ -f "$$first/bin/$$n" ]; then cp "$$first/bin/$$n" "$$out/bin/$$n"; fi; \
	done; \
	if [ -f "$$first/lib/libgs.a" ]; then \
	  if [ "$(words $(2))" = "1" ]; then cp "$$first/lib/libgs.a" "$$out/lib/libgs.a"; \
	  else lipo -create $(foreach a,$(2),"$(DEPS_DIR)/$(a)/lib/libgs.a") -output "$$out/lib/libgs.a"; fi; \
	  mkdir -p "$$out/include/ghostscript"; cp "$$first"/include/ghostscript/*.h "$$out/include/ghostscript/"; \
	fi; \
	gsd=""; \
	for c in "$$first/share/ghostscript" "$$first"/share/ghostscript/*; do \
	  if [ -d "$$c/lib" ]; then gsd="$$c/"; break; fi; \
	done; \
	if [ -n "$$gsd" ]; then \
	  mkdir -p "$$out/$(DIST_GS_SHARE_DIR)"; \
	  for i in $(DIST_GS_SHARE_ITEMS); do \
	    if [ -d "$$gsd$$i" ]; then cp -R "$$gsd$$i" "$$out/$(DIST_GS_SHARE_DIR)/"; \
	    else echo "    note: Ghostscript '$$i' was not installed"; fi; \
	  done; \
	else echo "    note: no Ghostscript shared data found in $$first/share/ghostscript"; fi; \
	for m in $(DIST_MAN); do \
	  if [ -f "$$first/share/man/$$m" ]; then \
	    mkdir -p "$$out/share/man/$$(dirname $$m)"; cp "$$first/share/man/$$m" "$$out/share/man/$$m"; \
	  fi; \
	done; \
	if [ -d "$$first/$(DIST_FONT_DIR)" ]; then mkdir -p "$$out/$(DIST_FONT_DIR)"; cp -R "$$first/$(DIST_FONT_DIR)/." "$$out/$(DIST_FONT_DIR)/"; fi; \
	echo "    magick: $$(lipo -info "$$out/bin/magick")"; \
	echo "    gs    : $$(lipo -info "$$out/bin/gs")";

dist: $(foreach a,$(ARCHS),$(call stamp,imagemagick,$(a)))
	@set -e; \
	$(foreach a,$(ARCHS),$(call dist_assemble,$(a),$(a))) \
	$(if $(word 2,$(ARCHS)),$(call dist_assemble,universal,$(ARCHS)),rm -rf "$(OUTPUT_DIR)/universal";) \
	true

# ---- licences ---------------------------------------------------------------
# The build collects licences from the ORIGINAL source archives (so 'make clean'
# does not matter):
#   ImageMagick     -> <tree><prefix>/<DIST_LICENSES_DIR>/
#   each other pkg  -> <tree><prefix>/<DIST_LICENSES_DIR>/vendors/<software_name>/
#  It copies root-level files named COPYING*, LICEN[CS]E*, COPYRIGHT*, NOTICE*,
#  LGPL*, GPL* (and <PKG>_LICENSE_FILES).
lic_collect = tmp="$(BUILD_DIR)/licenses-src/$(1)"; rm -rf "$$tmp"; mkdir -p "$$tmp"; \
	tar -xf "$(call archive,$(1))" -C "$$tmp" --strip-components=1; \
	dest="$$stage/$(if $(filter imagemagick,$(1)),,vendors/$(1))"; mkdir -p "$$dest"; n=0; \
	for f in $$(find "$$tmp" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICEN[CS]E*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname 'LGPL*' -o -iname 'GPL*' -o -iname 'PATENTS*' \)); do \
	  cp "$$f" "$$dest/"; n=$$((n+1)); \
	done; \
	for x in $(call pv,$(1),LICENSE_FILES); do \
	  if [ -f "$$tmp/$$x" ]; then cp "$$tmp/$$x" "$$dest/$$(basename $$x)"; n=$$((n+1)); fi; \
	done; \
	if [ $$n -eq 0 ]; then echo "    WARNING: no licence file found in $(1)"; else echo "    $(1): $$n file(s)"; fi; \
	rm -rf "$$tmp";

licenses: dist $(foreach p,$(ALL_PKGS),$(call archive,$(p)))
	@set -e; stage="$(BUILD_DIR)/licenses"; \
	rm -rf "$$stage" "$(BUILD_DIR)/licenses-src"; mkdir -p "$$stage"; \
	echo ">>> licenses: collecting from source archives"; \
	$(foreach p,$(ALL_PKGS),$(call lic_collect,$(p))) \
	for t in $(ARCHS) $(if $(word 2,$(ARCHS)),universal); do \
	  d="$(OUTPUT_DIR)/$$t$(DIST_PREFIX)/$(DIST_LICENSES_DIR)"; \
	  rm -rf "$$d"; mkdir -p "$$d"; cp -R "$$stage/." "$$d/"; \
	  echo "    -> $$d"; \
	done; \
	rm -rf "$$stage" "$(BUILD_DIR)/licenses-src"

# Build one .pkg per arch you built (and one for 'universal' when you built
# several) from the matching $(OUTPUT_DIR)/<arch> tree. The trees already
# contain the install prefix (e.g. usr/local/...), so the build installs the
# payload root at '/'. $(1) = dist sub-folder / name suffix: an arch or
# 'universal'.
pkg_build = out="$(PACKAGE_DIR)/imagemagick-$(IMAGEMAGICK_VERSION)-darwin-$(1).pkg"; \
	if [ ! -d "$(OUTPUT_DIR)/$(1)" ]; then echo "Missing $(OUTPUT_DIR)/$(1) - run 'make dist' first"; exit 1; fi; \
	rm -f "$$out"; \
	echo ">>> package: $$out"; \
	pkgbuild --root "$(OUTPUT_DIR)/$(1)" --identifier "$(PKG_IDENTIFIER)" --version "$(PKG_VERSION)" \
	  --install-location / --ownership recommended --filter '/\.DS_Store$$' "$$out" >/dev/null; \
	echo "    $$(ls -lh "$$out" | awk '{print $$5}')  $$out";

package: licenses
	@set -e; \
	command -v pkgbuild >/dev/null 2>&1 || { echo "pkgbuild not found (it is part of macOS)"; exit 1; }; \
	mkdir -p "$(PACKAGE_DIR)"; \
	$(foreach a,$(ARCHS),$(call pkg_build,$(a))) \
	$(if $(word 2,$(ARCHS)),$(call pkg_build,universal)) \
	true

verify:
	@set -e; magick="$(DIST_MAIN)/bin/magick"; gs="$(DIST_MAIN)/bin/gs"; \
	for b in "$$magick" "$$gs"; do \
	  [ -x "$$b" ] || { echo "Missing $$b - run 'make' first"; exit 1; }; \
	  echo "== $$b"; \
	  echo "Architectures : $$(lipo -archs "$$b")"; \
	  echo "Linked against:"; \
	  otool -L "$$b" | grep -E '^[[:space:]]' | sed 's/^[[:space:]]*/    /'; \
	  bad=$$(otool -L "$$b" | grep -E '^[[:space:]]' | awk '{print $$1}' | grep -Ev '^(/usr/lib/|/System/Library/)' || true); \
	  if [ -n "$$bad" ]; then echo "ERROR: non-system dynamic libraries found:"; echo "$$bad"; exit 1; fi; \
	done; \
	echo "== magick -version"; ver=$$("$$magick" -version); echo "$$ver"; \
	dels=$$(echo "$$ver" | grep '^Delegates'); missing=""; \
	for d in $(REQUIRED_DELEGATES); do echo "$$dels" | grep -qw -- "$$d" || missing="$$missing $$d"; done; \
	if [ -n "$$missing" ]; then \
	  echo "ERROR: delegates missing from magick:$$missing"; \
	  echo "       check $(BUILD_DIR)/<arch>/imagemagick/config.log"; exit 1; \
	fi; \
	fmts=$$("$$magick" -list format); missing=""; \
	for f in $(REQUIRED_FORMATS); do echo "$$fmts" | grep -Eq "^[[:space:]]+$$f\*?[[:space:]]" || missing="$$missing $$f"; done; \
	if [ -n "$$missing" ]; then echo "ERROR: formats missing from magick:$$missing"; exit 1; fi; \
	echo "== gs --version: $$("$$gs" --version)"; \
	t=$$(mktemp -d); trap 'rm -rf "$$t"' EXIT; \
	printf '%s\n' '%!PS' '/Helvetica findfont 36 scalefont setfont 20 40 moveto (Hello) show showpage' > "$$t/t.ps"; \
	"$$gs" -q -dBATCH -dNOPAUSE -dSAFER -sDEVICE=pdfwrite -sOutputFile="$$t/t.pdf" "$$t/t.ps"; \
	[ -s "$$t/t.pdf" ] || { echo "ERROR: gs could not create a PDF"; exit 1; }; \
	"$$magick" -density 72 "$$t/t.pdf" "$$t/pdf.png"; \
	[ -s "$$t/pdf.png" ] || { echo "ERROR: magick could not render a PDF (libgs)"; exit 1; }; \
	"$$magick" rose: "$$t/rose.png"; \
	for e in $(VERIFY_ROUNDTRIP); do \
	  "$$magick" rose: "$$t/rt.$$e" && "$$magick" "$$t/rt.$$e" "$$t/back-$$e.png" \
	    || { echo "ERROR: encode/decode of .$$e failed"; exit 1; }; \
	  echo "    round trip ok: .$$e"; \
	done; \
	echo "OK: only system libraries are linked, all required delegates/formats are present and the tests passed."

# -----------------------------------------------------------------------------
# 8. Information / housekeeping
# -----------------------------------------------------------------------------
info:
	@echo "Architectures          : $(ARCHS)   (host: $(NATIVE_ARCH))"
	@echo "Deployment target      : macOS $(MACOSX_DEPLOYMENT_TARGET)"
	@echo "SDK                    : $(MACOS_SDK)"
	@echo "CMake                  : $(CMAKE)"
	@echo "Parallel jobs          : $(JOBS)"
	@echo "ImageMagick flavour    : Q$(IM_QUANTUM_DEPTH)$(if $(filter yes,$(IM_HDRI)),-HDRI)"
	@echo "Ghostscript Tesseract  : $(GS_TESSERACT)"
	@echo "Downloads              : $(DOWNLOAD_DIR)"
	@echo "Toolchain              : $(TOOLCHAIN_DIR)"
	@echo "Build trees            : $(BUILD_DIR)"
	@echo "Static libs (per arch) : $(DEPS_DIR)/<arch>"
	@echo "Output                 : $(OUTPUT_DIR)/<arch|universal>$(DIST_PREFIX)"
	@echo "Packages               : $(PACKAGE_DIR)/imagemagick-$(IMAGEMAGICK_VERSION)-darwin-<arch|universal>.pkg ($(PKG_IDENTIFIER))"
	@echo "Dependency map         : $(DEPENDENCIES_FILE)"

versions:
	@$(foreach p,$(TOOLS) $(ALL_PKGS),echo "  $(p) $(call pv,$(p),VERSION)";)

graph:
	@$(foreach p,$(TOOLS) $(ALL_PKGS),echo "  $(p): $(call pv,$(p),DEPS)";)

help:
	@echo "ImageMagick and Ghostscript static universal build for macOS"
	@echo ""
	@echo "  make                    build the toolchain, all libraries, Ghostscript and ImageMagick"
	@echo "  make dist               (re)assemble $(OUTPUT_DIR)/<arch>$(DIST_PREFIX) (and universal) from the per-arch builds"
	@echo "  make licenses           collect licence files into $(OUTPUT_DIR)/<tree>$(DIST_PREFIX)/$(DIST_LICENSES_DIR)"
	@echo "  make package            build .pkg installers (one per arch plus universal) into $(PACKAGE_DIR)"
	@echo "  make verify             check architectures, linkage, delegates, formats and run tests"
	@echo "  make check-system       check prerequisites"
	@echo "  make download           download all source archives only"
	@echo "  make checksums          print the SHA-256 of every downloaded archive"
	@echo "  make toolchain          build only the native toolchain"
	@echo "  make deps               build only the libraries (all architectures)"
	@echo "  make <name>             build one package (all architectures), e.g. make libheif"
	@echo "  make <name>-<arch>      build one package for one arch, e.g. make libheif-arm64"
	@echo "  make rebuild-<name>     force a rebuild of one package (then run 'make')"
	@echo "  make clean-<name>       forget one package (stamp plus build tree)"
	@echo "  make info | versions | graph"
	@echo "  make clean              remove build trees"
	@echo "  make distclean          also remove toolchain, libraries and output"
	@echo "  make purge              distclean and remove downloaded sources"
	@echo ""
	@echo "Toolchain : $(TOOLS) (plus CMake from the system)"
	@echo "Libraries : $(PACKAGES)"
	@echo "Target    : imagemagick"
	@echo "Override variables on the command line or in config.mk (see README.md)."

clean:
	rm -rf "$(BUILD_DIR)"

distclean: clean
	@for d in "$(DEPS_DIR)" "$(TOOLCHAIN_DIR)" "$(OUTPUT_DIR)" "$(PACKAGE_DIR)"; do \
	  if [ "$$d" = "/" ] || [ "$$d" = "$$HOME" ] || [ "$$d" = "/usr" ] || [ "$$d" = "/usr/local" ]; then \
	    echo "Refusing to delete $$d"; exit 1; fi; \
	done
	rm -rf "$(DEPS_DIR)" "$(TOOLCHAIN_DIR)" "$(OUTPUT_DIR)" "$(PACKAGE_DIR)"

purge: distclean
	rm -rf "$(DOWNLOAD_DIR)"
