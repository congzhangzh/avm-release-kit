# shellcheck shell=bash
# Shared by build.sh, build-windows.sh, build-macos.sh and test.sh: where
# things live, the pinned source, the container helpers, and the packaging
# every target shares. Sourced after KIT is set. Kept to what bash 3.2 can
# run (macOS's /bin/bash): no associative arrays, no mapfile.
#
# WORK      work trees, sources and caches (default ~/.cache/avm-release-kit)
# DIST      where targets land (default <kit>/dist)
# ENGINE    docker or podman (default: whichever is installed, docker first)
# ENGINE_RUN_OPTS   extra options for every container run, word-split, e.g.
#           ENGINE_RUN_OPTS=--cpuset-cpus=4-7 to keep builds off some cores
# CMAKE_BUILD_PARALLEL_LEVEL   passed on to the container builds as well

WORK=${WORK:-$HOME/.cache/avm-release-kit}
DIST=${DIST:-$KIT/dist}
ENGINE=${ENGINE:-$(command -v docker || command -v podman || true)}
ENGINE_RUN_OPTS=${ENGINE_RUN_OPTS:-}

lock() {  # lock <name> <field 2..4>
    awk -v n="$1" -v f="$2" '$1 == n && $0 !~ /^#/ { print $f; exit }' "$KIT/sources.lock"
}

# sha256sum on Linux, shasum on macOS; the same output format
if command -v sha256sum > /dev/null; then SHA256=(sha256sum); else SHA256=(shasum -a 256); fi

# The source tree to build: WORK/src/<id>, where <id> is the commit, or
# local-<commit>[-dirty] for SRC_avm. Sets SRC_DIR, SRC_ID, SRC_DESC, VERSION
# and LOCAL.
fetch_source() {
    if [ -n "${SRC_avm:-}" ] && ! git -C "$SRC_avm" rev-parse --git-dir > /dev/null 2>&1; then
        # a plain tree (git archive of a commit), named by its SOURCE_COMMIT
        local head
        head=$(cat "$SRC_avm/SOURCE_COMMIT" 2> /dev/null) || {
            echo "SRC_avm=$SRC_avm: neither a git checkout nor a tree with SOURCE_COMMIT" >&2
            exit 2; }
        SRC_ID=local-${head:0:12}-tree
        SRC_DESC="local tree $(basename "$SRC_avm") @ $head"
        SRC_DIR=$WORK/src/$SRC_ID
        if [ "$(cd "$SRC_avm" && pwd)" != "$SRC_DIR" ]; then
            rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
            (cd "$SRC_avm" && tar -cf - .) | tar -C "$SRC_DIR" -xf -
        fi
        LOCAL=-local
    elif [ -n "${SRC_avm:-}" ]; then
        local head dirty=""
        head=$(git -C "$SRC_avm" rev-parse HEAD)
        [ -z "$(git -C "$SRC_avm" status --porcelain)" ] || dirty=-dirty
        SRC_ID=local-${head:0:12}$dirty
        # the folder name only: a MANIFEST must not carry local paths
        SRC_DESC="local checkout $(basename "$SRC_avm") @ $head${dirty:+ (with uncommitted edits)}"
        SRC_DIR=$WORK/src/$SRC_ID
        rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
        # the files git knows, tracked or new, as they are on disk
        git -C "$SRC_avm" ls-files -z --cached --others --exclude-standard |
            (cd "$SRC_avm" && tar --null -T - -cf -) | tar -C "$SRC_DIR" -xf -
        echo "$head$dirty" > "$SRC_DIR/SOURCE_COMMIT"
        LOCAL=-local
    else
        local url commit
        url=$(lock avm 3); url=${url#git+}
        commit=$(lock avm 4)
        SRC_ID=$commit
        SRC_DESC="$url @ $commit"
        SRC_DIR=$WORK/src/$commit
        LOCAL=
        if [ ! -f "$SRC_DIR/SOURCE_COMMIT" ]; then
            local mirror=$WORK/mirror/avm.git
            [ -d "$mirror" ] || git clone -q --bare "$url" "$mirror"
            git -C "$mirror" cat-file -e "$commit^{commit}" 2>/dev/null ||
                git -C "$mirror" fetch -q "$url" "$commit"
            rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
            git -C "$mirror" archive "$commit" | tar -C "$SRC_DIR" -xf -
            echo "$commit" > "$SRC_DIR/SOURCE_COMMIT"
        fi
    fi
    VERSION=$(lock avm 2)$LOCAL
}

# Options every target shares: the library and the two apps, no TFLite (its
# C++ dependencies serve only encoder ML pruning), no tests or docs.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_TOOLS=0
        -DCONFIG_ML_PART_SPLIT=0 -DCONFIG_DIP_EXT_PRUNING=0)

# A path as a MANIFEST may show it: the kit, the source and WORK by name,
# never a home directory
public_paths() {
    sed -e "s|$SRC_DIR|<avm source>|g" -e "s|$KIT|<kit>|g" -e "s|$WORK|<work>|g" \
        -e "s|$HOME|<home>|g"
}

# The compiler CMake found in a build dir, also when a toolchain file set it
# (not cached then): its name and version
compiler_of() {  # compiler_of <build dir>
    local cc
    cc=$(sed -n 's/^set(CMAKE_C_COMPILER "\(.*\)")$/\1/p' \
        "$1"/CMakeFiles/*/CMakeCCompiler.cmake | head -1)
    # cc is a link to the real compiler (gcc on Debian): name that one
    local real
    real=$(readlink -f "$(command -v "$cc")" 2> /dev/null) || real=$cc
    echo "$(basename "$real") $("$cc" -dumpfullversion 2> /dev/null || "$cc" -dumpversion)"
}

# A host build: library, headers, avm.pc, avmenc and avmdec into DIST/<target>
build_native() {  # build_native <target> [cmake options]
    local target=$1; shift
    local bdir=$WORK/build/$target-$SRC_ID stage=$DIST/$target
    # no build path in the objects (__FILE__, debug info)
    local map="-ffile-prefix-map=$SRC_DIR=avm -ffile-prefix-map=$bdir=build"
    rm -rf "$stage"
    cmake -S "$SRC_DIR" -B "$bdir" "${COMMON[@]}" -DCMAKE_INSTALL_PREFIX="$stage" \
        "-DCMAKE_C_FLAGS=$map" "-DCMAKE_CXX_FLAGS=$map" "$@" \
        > "$WORK/$target.configure.log" 2>&1 ||
        { tail -20 "$WORK/$target.configure.log" >&2; return 1; }
    if ! cmake --build "$bdir" --target install > "$WORK/$target.build.log" 2>&1 ||
        ! cmake --build "$bdir" --target avmenc avmdec >> "$WORK/$target.build.log" 2>&1; then
        tail -20 "$WORK/$target.build.log" >&2
        return 1
    fi
    mkdir -p "$stage/bin"
    cp "$bdir/avmenc" "$bdir/avmdec" "$stage/bin/"
    COMPILER=$(compiler_of "$bdir")
    FLAGS="${COMMON[*]} $*"
}

# avm.pc names the install prefix; make it relative to where the file is, so
# the unpacked archive works from any directory (pkg-config's ${pcfiledir})
relocatable_pc() {  # relocatable_pc <stage>
    local pc=$1/lib/pkgconfig/avm.pc
    [ -f "$pc" ] || return 0
    # the single quotes keep ${pcfiledir} for pkg-config
    # shellcheck disable=SC2016
    sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$pc" > "$pc.new" && mv "$pc.new" "$pc"
}

package() {  # package <target>
    local target=$1 stage=$DIST/$1 name
    name=avm-$VERSION-$target
    relocatable_pc "$stage"
    {
        echo "product   libavm (AV2), avmenc, avmdec"
        echo "version   $VERSION"
        echo "target    $target"
        echo "source    $SRC_DESC"
        echo "kit       $(git -C "$KIT" rev-parse --short=12 HEAD 2>/dev/null || echo uncommitted)"
        echo "compiler  $COMPILER"
        echo "options   $(public_paths <<< "$FLAGS")"
        echo "built     $(date -u +%Y-%m-%dT%H:%MZ)"
        [ -z "$LOCAL" ] || echo "OVERRIDE  avm from a local checkout; not a release"
        echo
        (cd "$stage" && find . -type f ! -name MANIFEST | LC_ALL=C sort | xargs "${SHA256[@]}")
    } > "$stage/MANIFEST"
    # the archive's top folder is its name; a copy, as BSD tar (macOS) has
    # no --transform
    rm -rf "$WORK/pkg/$name"; mkdir -p "$WORK/pkg"
    cp -R "$stage" "$WORK/pkg/$name"
    tar -C "$WORK/pkg" -czf "$DIST/$name.tar.gz" "$name"
    rm -rf "${WORK:?}/pkg/$name"
    (cd "$DIST" && "${SHA256[@]}" "$name.tar.gz" > "$name.tar.gz.sha256")
    echo "$DIST/$name.tar.gz"
}

# --- containers ------------------------------------------------------------

need_engine() {
    [ -n "$ENGINE" ] || { echo "$1 needs docker or podman" >&2; exit 1; }
}

# Files a container writes belong to this user: docker runs it as this
# uid; rootless podman maps this user into it (keep-id)
engine_run() {  # engine_run <run options and image and command>
    local user
    case $ENGINE in
        *podman) user=(--userns=keep-id) ;;
        *) user=(-u "$(id -u):$(id -g)") ;;
    esac
    # shellcheck disable=SC2086 # ENGINE_RUN_OPTS is a list of options
    "$ENGINE" run --rm "${user[@]}" $ENGINE_RUN_OPTS -e HOME=/tmp \
        ${CMAKE_BUILD_PARALLEL_LEVEL:+-e CMAKE_BUILD_PARALLEL_LEVEL="$CMAKE_BUILD_PARALLEL_LEVEL"} "$@"
}

# A builder image: a base image with the build tools added by a Dockerfile in
# build/, made once and named after the Dockerfile's hash (and a tag that says
# what it is built on)
builder_image() {  # builder_image <kind> <tag> <base image>
    local kind=$1 tag=$2 base=$3 name
    name=avm-release-kit-$kind:$tag-$("${SHA256[@]}" < "$KIT/build/Dockerfile.$kind" | cut -c1-12)
    if ! "$ENGINE" image inspect "$name" > /dev/null 2>&1; then
        echo "== builder image $name (made once)" >&2
        "$ENGINE" build -q --build-arg BASE="$base" -t "$name" \
            -f "$KIT/build/Dockerfile.$kind" "$KIT/build" >&2
    fi
    echo "$name"
}

# The pinned emsdk image with Ninja, ccache and perl added
wasm_builder() {
    builder_image wasm "$(lock emsdk 2)" "emscripten/emsdk:$(lock emsdk 2)@$(lock emsdk 4)"
}

# Debian with CMake, Ninja, ccache, nasm and wine for the Windows builds; the
# compiler (llvm-mingw) is mounted, not installed (llvm_mingw below)
windows_builder() {
    builder_image windows "$(lock debian 2)" "debian:$(lock debian 2)@$(lock debian 4)"
}

# The llvm-mingw toolchain from sources.lock, unpacked once into
# WORK/llvm-mingw/<version>; downloads it if needed, checks its SHA-256.
# Prints the directory.
llvm_mingw() {
    local version url sum file dir
    version=$(lock llvm_mingw 2); url=$(lock llvm_mingw 3); sum=$(lock llvm_mingw 4)
    file=$WORK/sources/${url##*/}
    dir=$WORK/llvm-mingw/$version
    if [ ! -x "$dir/bin/clang" ]; then
        mkdir -p "$WORK/sources"
        if [ ! -f "$file" ]; then
            echo "== llvm-mingw $version (downloaded once)" >&2
            curl -fsSL -o "$file.part" "$url" || return 1
            mv "$file.part" "$file"
        fi
        if [ "$("${SHA256[@]}" < "$file" | cut -d' ' -f1)" != "$sum" ]; then
            echo "llvm-mingw: $file does not match the SHA-256 in sources.lock" >&2
            return 1
        fi
        rm -rf "$dir.part"; mkdir -p "$dir.part"
        tar -C "$dir.part" --strip-components=1 -xJf "$file"
        rm -rf "$dir"; mv "$dir.part" "$dir"
    fi
    echo "$dir"
}
