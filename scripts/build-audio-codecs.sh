#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SOURCE="$ROOT/.build/audio-sources"
DOWNLOADS="$ROOT/.build/audio-downloads"
PRODUCT="$ROOT/.build/products/audio-codecs"
WORK="$ROOT/.build/audio-work"
ARCHITECTURES="${ARCHS:-$(uname -m)}"
FFMPEG_VERSION=8.1.3
FFMPEG_SHA=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
WAVPACK_COMMIT=4827b9889665b937b6ed71b9c6c0123152cd7a02
DSD_COMMIT=b3f443d4c42ccf52806eb57def3b3a34805714bd
STAMP="$( {
  printf '%s\n' "$ARCHITECTURES" "$FFMPEG_VERSION" "$FFMPEG_SHA" "$WAVPACK_COMMIT" "$DSD_COMMIT"
  shasum -a 256 "$0" "$ROOT/Dependencies/AudioCodecs/AudioCodecs.cpp" "$ROOT/Dependencies/AudioCodecs/CMakeLists.txt" "$ROOT/Dependencies/AudioCodecs/NOTICE.txt" "$ROOT/Dependencies/AudioCodecs/ffmpeg-dst-raw-frames.patch" "$ROOT/Dependencies/AudioCodecs/ffmpeg-dsf-duration.patch" "$ROOT/Dependencies/AudioCodecs/dsd-nexus-dst-error-codes.patch"
} | shasum -a 256 | cut -d ' ' -f1)"

if [[ "${1:-}" == --check ]]; then
  [[ -f "$PRODUCT/.stamp" && "$(cat "$PRODUCT/.stamp")" == "$STAMP" && -f "$PRODUCT/libkmg_audio.dylib" ]]
  exit
fi

mkdir -p "$SOURCE" "$DOWNLOADS" "$WORK"
if [[ ! -f "$PRODUCT/.stamp" || "$(cat "$PRODUCT/.stamp")" != "$STAMP" ]]; then
  ARCHIVE="$DOWNLOADS/ffmpeg-$FFMPEG_VERSION.tar.xz"
  if [[ ! -f "$ARCHIVE" ]]; then
    curl -fsSL --retry 2 "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$ARCHIVE"
  fi
  if [[ "$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f1)" != "$FFMPEG_SHA" ]]; then
    echo 'error: FFmpeg source checksum mismatch' >&2
    exit 1
  fi
  for ITEM in WavPack dsd-nexus; do
    if [[ "$ITEM" == WavPack ]]; then
      URL=https://github.com/dbry/WavPack.git
      REVISION="$WAVPACK_COMMIT"
    else
      URL=https://github.com/wichers/dsd-nexus.git
      REVISION="$DSD_COMMIT"
    fi
    if [[ ! -d "$SOURCE/$ITEM/.git" ]]; then git clone "$URL" "$SOURCE/$ITEM"; fi
    git -C "$SOURCE/$ITEM" checkout --detach "$REVISION"
    [[ "$(git -C "$SOURCE/$ITEM" rev-parse HEAD)" == "$REVISION" ]]
    if [[ "$ITEM" == dsd-nexus ]]; then
      git -C "$SOURCE/$ITEM" diff --quiet -- . ':!libs/libsacd/src/sacd_dst_reader.h'
    else
      git -C "$SOURCE/$ITEM" diff --quiet
    fi
  done
  if [[ ! -d "$SOURCE/ffmpeg-$FFMPEG_VERSION" ]]; then tar -xJf "$ARCHIVE" -C "$SOURCE"; fi
  for PATCH_FILE in "$ROOT/Dependencies/AudioCodecs/"*.patch; do
    PATCH_SOURCE="$SOURCE/ffmpeg-$FFMPEG_VERSION"
    if [[ "$(basename "$PATCH_FILE")" == dsd-nexus-* ]]; then PATCH_SOURCE="$SOURCE/dsd-nexus"; fi
    if patch --dry-run --silent -p1 -d "$PATCH_SOURCE" < "$PATCH_FILE" >/dev/null 2>&1; then
      patch -p1 -d "$PATCH_SOURCE" < "$PATCH_FILE"
    else
      patch --dry-run --silent --reverse -p1 -d "$PATCH_SOURCE" < "$PATCH_FILE" >/dev/null
    fi
  done

  STAGING="$WORK/product.$$"
  mkdir -p "$STAGING/Licenses"
  for ARCHITECTURE in $ARCHITECTURES; do
    case "$ARCHITECTURE" in
      arm64|x86_64) ;;
      *) echo "error: Unsupported audio codec architecture $ARCHITECTURE" >&2; exit 1 ;;
    esac
    ARCH_WORK="$WORK/$ARCHITECTURE"
    FFMPEG_BUILD="$ARCH_WORK/ffmpeg"
    PREFIX="$ARCH_WORK/ffmpeg-prefix"
    mkdir -p "$FFMPEG_BUILD"
    ASSEMBLY_OPTIONS=(--enable-asm)
    if [[ "$ARCHITECTURE" == x86_64 ]] && ! command -v nasm >/dev/null; then
      ASSEMBLY_OPTIONS+=(--disable-x86asm)
    fi
    (
      cd "$FFMPEG_BUILD"
      "$SOURCE/ffmpeg-$FFMPEG_VERSION/configure" --prefix="$PREFIX" --arch="$ARCHITECTURE" --cc=clang \
        --enable-shared --disable-static --disable-autodetect --disable-programs --disable-doc \
        --disable-network --disable-avdevice --disable-avfilter --disable-swscale --disable-everything \
        --enable-zlib --enable-bzlib --enable-iconv --enable-protocol=file \
        --enable-demuxer=ape,wv,tta,ogg,asf,wav,w64,aiff,flac,mp3,aac,mov,dsf,iff \
        --enable-parser=aac,flac,mpegaudio,vorbis,opus \
        --enable-decoder=ape,wavpack,tta,vorbis,opus,wmav1,wmav2,wmapro,wmalossless,wmavoice,flac,alac,mp3float,aac,dst,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be \
        --install-name-dir=@loader_path --extra-libs=-liconv \
        --extra-cflags="-arch $ARCHITECTURE -mmacosx-version-min=26.0" \
        --extra-ldflags="-arch $ARCHITECTURE -mmacosx-version-min=26.0" "${ASSEMBLY_OPTIONS[@]}"
      make -j "$(sysctl -n hw.ncpu)"
      make install
    )
    cmake -S "$ROOT/Dependencies/AudioCodecs" -B "$ARCH_WORK/bridge" \
      -DDSD_SOURCE="$SOURCE/dsd-nexus" -DWAVPACK_SOURCE="$SOURCE/WavPack" -DFFMPEG_PREFIX="$PREFIX" \
      -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_BUILD_TYPE=Debug
    cmake --build "$ARCH_WORK/bridge" --target kmg_audio --parallel
    ARCH_PRODUCT="$STAGING/$ARCHITECTURE"
    mkdir -p "$ARCH_PRODUCT"
    cp "$ARCH_WORK/bridge/libkmg_audio.dylib" "$ARCH_PRODUCT/"
    for LIBRARY in avformat avcodec avutil swresample; do
      for LIBFILE in "$PREFIX/lib/lib$LIBRARY".*.dylib; do
        cp -L "$LIBFILE" "$ARCH_PRODUCT/$(basename "$LIBFILE")"
      done
    done
  done
  FIRST_ARCHITECTURE="${ARCHITECTURES%% *}"
  for LIBFILE in "$STAGING/$FIRST_ARCHITECTURE/"*.dylib; do
    INPUTS=()
    for ARCHITECTURE in $ARCHITECTURES; do INPUTS+=("$STAGING/$ARCHITECTURE/$(basename "$LIBFILE")"); done
    if [[ "${#INPUTS[@]}" -eq 1 ]]; then
      cp "${INPUTS[0]}" "$STAGING/$(basename "$LIBFILE")"
    else
      lipo -create "${INPUTS[@]}" -output "$STAGING/$(basename "$LIBFILE")"
    fi
  done
  for ARCHITECTURE in $ARCHITECTURES; do rm -rf "$STAGING/$ARCHITECTURE"; done
  cp "$SOURCE/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$STAGING/Licenses/FFmpeg-LGPL-2.1.txt"
  cp "$SOURCE/WavPack/license.txt" "$STAGING/Licenses/WavPack.txt"
  cp "$SOURCE/dsd-nexus/LICENSE" "$STAGING/Licenses/DSD-Nexus.txt"
  cp "$ROOT/Dependencies/AudioCodecs/NOTICE.txt" "$STAGING/Licenses/NOTICE.txt"
  printf '%s\n' "$STAMP" > "$STAGING/.stamp"
  rm -rf "$PRODUCT"
  mv "$STAGING" "$PRODUCT"
fi

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AudioCodecs"
  mkdir -p "$DESTINATION"
  ditto "$PRODUCT" "$DESTINATION"
  for LIBFILE in "$DESTINATION/"*.dylib; do
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$LIBFILE"
  done
fi
