#!/bin/bash

# BundELF - ELF binary and dynamic library patcher/bundler for making portable/relocatable executables
# ----------------------------------------------------------------------------------------------------
#
# Licence: Apache 2.0
# Authors: Struan Bartlett, NewsNow Labs, NewsNow Publishing Ltd
# Copyright: (c) authors 2025-2026
# Version: 1.1.9
# Git: https://github.com/newsnowlabs/bundelf

# make-bundelf-bundle.sh is used to prepare and package ELF binaries and their
# dynamic library dependencies for relocation to (and execution from) a new
# location, making them completely portable and independent of the original
# distribution.
#
# It can be used to package Linux binaries sourced from one distribution,
# so that they run within, but completely independently of, any other
# distribution.
#
# Example BundELF use cases:
# - Bundling Alpine binaries for running within, but completely independently
#   of, any arbitrary distribution (including GLIBC-based distributions)
# - Bundling GLIBC-based applications for running within Alpine (or indeed any
#   other distribution)
#
# BundELF is a core technology component of:
# - https://github.com/newsnowlabs/dockside
#   - to allow running complex Node-based IDE applications and container-setup
#     processes inside containers running an unknown arbitrary Linux
#     distribution
# - https://github.com/newsnowlabs/runcvm
#   - to allow running QEMU, virtiofsd, dnsmasq and other tools inside a
#     container (and indeed a VM) running an unknown arbitrary Linux
#     distribution
#
# Environment variable inputs:
# - BUNDELF_BINARIES - list required binaries to be scanned and copied
# - BUNDELF_DYNAMIC_PATHS - list optional paths to be scanned and copied
# - BUNDELF_EXTRA_LIBS - list extra libraries to be scanned and copied
# - BUNDELF_CODE_PATH - path where binaries and libraries will be copied to
# - BUNDELF_EXEC_PATH - path where binaries and libraries will be executed from
# = BUNDELF_MERGE_BINDIRS - non-empty if all specified binaries should be copied to $BUNDELF_CODE_PATH/bin
# - BUNDELF_LIBPATH_TYPE - whether to use absolute or relative paths (the default) for RPATH
# - BUNDELF_NODE_PATH - [optional] path to the node binary, if required to ensure ldd can resolve all library paths in .node files
# - BUNDELF_EXTRA_SYSTEM_LIB_PATHS - [optional] list of extra system library paths to be added to the RPATH
#
# See README.md for full details.

# BUNDELF_EXEC_PATH defaults to BUNDELF_CODE_PATH
BUNDELF_EXEC_PATH="${BUNDELF_EXEC_PATH:-$BUNDELF_CODE_PATH}"

# Whether to use absolute or relative paths for RPATH
BUNDELF_LIBPATH_TYPE="${BUNDELF_LIBPATH_TYPE:-relative}"

# Determine LD filepath, which is architecture-dependent:
# e.g. ld-musl-aarch64.so.1 (linux/arm64), ld-musl-armhf.so.1 (linux/arm/v7), ld-musl-x86_64.so.1 (linux/amd64)
#   or ld-linux-aarch64.so.1 (linux/arm64), ld-linux-armhf.so.3 (linux/arm/v7), ld-linux-x86-64.so.2 (linux/amd64)
LD_PATH=$(ls -1 /lib/ld-musl-* /lib/*-linux-*/ld-linux-*.so.* 2>/dev/null | head -n 1)
if [ -z "$LD_PATH" ]; then
  echo "ERROR: No dynamic linker found in /lib (ld-musl-* or ld-linux-*.so.*)" >&2
  exit 1
fi
LD_BIN=$(basename "$LD_PATH")

TMP=/tmp/bundelf.$$

append() {
  while read line; do echo "${line}${1}"; done
}

_verify_interpreter_paths() {
  # Verify interpreter path is correctly set in all ELF binaries
  # Returns 0 if all OK, 1 if any problems found
  local status=0
  echo "Verifying interpreter paths..." >&2

  while IFS= read -r bin; do
    echo -n "- interp: $bin ... " >&2
    local interpreter=$(patchelf --print-interpreter "$bin" 2>/dev/null)
    if [ "$interpreter" != "$BUNDELF_EXEC_PATH$LD_PATH" ]; then
      echo "BAD (interpreter: $interpreter)" >&2
      status=1
    else
      echo "GOOD" >&2
    fi
  done < "$BUNDELF_CODE_PATH/.binelfs"
  return $status
}

_verify_rpath_settings() {
  # Verify RPATH settings match expected patterns for relative/absolute mode
  # Returns 0 if all OK, 1 if any problems found

  local BUNDELF_CODE_PATH_REGEX=$(escape_regex "$BUNDELF_CODE_PATH")

  local status=0
  echo "Verifying RPATH settings..." >&2

  while IFS= read -r file; do
    echo -n "- RPATH: $file ... " >&2
    local rpath=$(patchelf --print-rpath "$file" 2>/dev/null)

    if [ "$BUNDELF_LIBPATH_TYPE" = "absolute" ]; then
      # For absolute mode, all RPATHs should start with BUNDELF_CODE_PATH (or be empty, should no dynamic libraries be referenced by any bundled binaries)
      if ! echo "$rpath" | grep -qE "^($BUNDELF_CODE_PATH_REGEX|$)"; then
        echo "BAD (expected absolute path)" >&2
        status=1
      else
        echo "GOOD" >&2
      fi
    else
      # For relative mode, all RPATHs should use $ORIGIN (or be empty, should no dynamic libraries be referenced by any bundled binaries)
      if ! echo "$rpath" | grep -qE '^(\$ORIGIN|$)'; then
        echo "BAD (expected \$ORIGIN)" >&2
        status=1
      else
        echo "GOOD" >&2
      fi
    fi
  done < <(cat "$BUNDELF_CODE_PATH/.binelfs" "$BUNDELF_CODE_PATH/.libelfs")
  return $status
}

_verify_symlinks() {
  # Check for broken symlinks within the bundle
  # Returns 0 if all OK, 1 if any problems found
  local status=0
  echo "Verifying symlinks..." >&2

  while IFS= read -r link; do
    echo -n "- symlink: $link ... " >&2
    if ! [ -e "$link" ]; then
      echo "BAD (broken link)" >&2
      status=1
    else
      echo "GOOD" >&2
    fi
  done < <(find "$BUNDELF_CODE_PATH" -type l)

  return $status
}

_verify_library_resolution() {
  # Check that all dynamic library dependencies are correctly being resolved to versions stored within BUNDELF_CODE_PATH.
  # Returns 0 if all OK, 1 if any problems found
  local status=0
  echo "Verifying library resolution..." >&2

  local BUNDELF_CODE_PATH_REGEX=$(escape_regex "$BUNDELF_CODE_PATH")
  local BUNDELF_EXEC_PATH_REGEX=$(escape_regex "$BUNDELF_EXEC_PATH")
  local LD_BIN_REGEX=$(escape_regex "$LD_BIN")

  while IFS= read -r lib; do
    echo -n "- lib: $lib ... " >&2
    "$BUNDELF_CODE_PATH$LD_PATH" --list "$lib" 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/- \2 \1/;/^.+$/p;' | egrep -v -- "^- ($BUNDELF_CODE_PATH_REGEX/|$BUNDELF_EXEC_PATH_REGEX/.*/$LD_BIN_REGEX)"

    if [ $? -eq 0 ]; then
      status=1
      echo "BAD" >&2
    else
      echo "GOOD" >&2
    fi
    sleep 0.01
  done < <(cat "$BUNDELF_CODE_PATH/.binelfs" "$BUNDELF_CODE_PATH/.libelfs")
  return $status
}

verify() {
  local final_status=0

  # Deduce BUNDELF_CODE_PATH from this script's execution path, when needed (useful when called with --verify within an alternative environment).
  [ -z "$BUNDELF_CODE_PATH" ] && BUNDELF_CODE_PATH=$(realpath $(dirname $0)/..)

  # Fast verifications
  _verify_interpreter_paths || final_status=1
  _verify_symlinks || final_status=1
  _verify_rpath_settings || final_status=1
  _verify_library_resolution || final_status=1

  if [ $final_status -eq 0 ]; then
    echo "All verifications passed successfully." >&2
  fi
  exit $final_status
}

copy_binaries() {
  # Copy any binaries we require to the install location, outputing their new paths.

  if [ -n "$BUNDELF_MERGE_BINDIRS" ]; then
    mkdir -p "$BUNDELF_CODE_PATH/bin"
  else
    mkdir -p "$BUNDELF_CODE_PATH"
  fi

  for bin in "$@"
  do
    local file="$(which "$bin")"
    local basename="$(basename "$file")"

    if [ -n "$file" ]; then
      if [ -z "$BUNDELF_MERGE_BINDIRS" ]; then
        mkdir -p "$BUNDELF_CODE_PATH$(dirname "$file")"
        cp -a --dereference "$file" "$BUNDELF_CODE_PATH$(dirname "$file")/"
        echo "$BUNDELF_CODE_PATH$file"
      else
        cp -p --dereference "$file" "$BUNDELF_CODE_PATH/bin/"
        echo "$BUNDELF_CODE_PATH/bin/$basename"
      fi
    fi
  done
}

scan_extra_libs() {
  for p in "$@"
  do
    find "$p" ! -type d
  done
}

# Using ldd, generate list of resolved library filepaths for each ELF binary and library, e.g.
# /usr/lib/libaio.so.1
# /lib/libblkid.so.1
find_lib_deps() {
  # Use ldd to find library dependencies. The sed regex requires the resolved path to start with '/'
  # to exclude ldd's "not found" output (e.g. "libfoo.so => not found") which would otherwise
  # cause the word "not" to be captured as a path by the non-greedy match.
  cat "$@" | sort -u | xargs -P $(nproc) -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(\/[^ ]*)\s.*$/\2/p' | sort -u
}

copy_libs() {
  mkdir -p "$BUNDELF_CODE_PATH"

  local BUNDELF_CODE_PATH_REGEX=$(escape_regex "$BUNDELF_CODE_PATH")

  # For each resolved library filepath, copy $file to the install location.
  #
  # N.B. These steps are all needed to ensure the Alpine dynamic linker can resolve library filepaths as required.
  #      For more, see https://www.musl-libc.org/doc/1.0.0/manual.html
  #
  grep -v "^$BUNDELF_CODE_PATH_REGEX" "$@" | sort -u | while IFS= read -r file
  do
    # Copy $file; and if $file is a symlink, also copy its target.
    # This could  result in duplicate copy operations if multiple symlinks point to the same target,
    # but has the advantage of simplicity.
    # N.B. We use mkdir -p + cp rather than cp --parents, to avoid failures on usrmerge systems
    # where /lib is a symlink to usr/lib: cp -a --parents would copy /lib as a symlink, and
    # subsequent directory creation through it would fail.
    mkdir -p "$BUNDELF_CODE_PATH$(dirname "$file")"
    cp -a "$file" "$BUNDELF_CODE_PATH$(dirname "$file")/"

    # If $file is a symlink, then copy its target too, as the target might not otherwise be copied.
    if [ -L "$file" ]; then
      # local target=$(realpath -m "$(dirname "$file")/$(readlink "$file")")
      local target=$(dirname "$file")/$(readlink "$file")
      mkdir -p "$BUNDELF_CODE_PATH$(dirname "$target")"
      cp -a "$target" "$BUNDELF_CODE_PATH$(dirname "$target")/"
    fi

    if [ "$file" != "$LD_PATH" ]; then
      echo "$BUNDELF_CODE_PATH$file"
    fi
  done

  # Also output paths that were already in BUNDELF_CODE_PATH (e.g. .node files from
  # BUNDELF_DYNAMIC_PATHS): they were skipped by copy_libs above since they don't need
  # re-copying, but must appear in the output so callers have a complete set of destination
  # paths for RPATH patching.
  grep "^$BUNDELF_CODE_PATH_REGEX" "$@" | sort -u
}

patch_binary() {
  local bin="$1"

  if patchelf --set-interpreter "$BUNDELF_EXEC_PATH$LD_PATH" "$bin" 2>/dev/null; then
    echo patchelf --set-interpreter "$BUNDELF_EXEC_PATH$LD_PATH" "$bin" >>$TMP/patchelf.log
    return 0
  fi

  return 1
}

# Function to replace links with direct copies when using relative RPATHs.
# Only replaces links when source and target are in different directories,
# and thus need different RPATHs.
replace_link_new() {
  local file="$1"
  local tmp_file

  [ "$BUNDELF_LIBPATH_TYPE" = "relative" ] || return 0

  # Handle symlinks - only replace if target is in a different directory
  if [ -L "$file" ]; then
    local link_target=$(readlink "$file")
    local file_dir=$(dirname "$(realpath "$file")")

    if [ "${link_target#/}" = "$link_target" ]; then
        # Relative symlink: Resolve target relative to symlink location
        local target_full="$(cd "$(dirname "$file")" && realpath -m "$link_target")"
        local target_dir=$(dirname "$target_full")
    else
        # Absolute symlink: Already have full path
        local target_dir=$(dirname "$(realpath "$link_target")")
    fi

    if [ "$file_dir" != "$target_dir" ]; then
        tmp_file=$(mktemp)
        cp -L "$file" "$tmp_file" && mv "$tmp_file" "$file"
    fi
    return 0
  fi

  # Handle hard links - only replace if any hard link is in a different directory
  local link_count=$(stat -c %h "$file")
  if [ "$link_count" -gt 1 ]; then
    local file_dir=$(dirname "$file")
    local needs_replacement=0

    # Find all hard links to this inode and check their directories
    local inode=$(stat -c %i "$file")
    while IFS= read -r linked_file; do
      local linked_dir=$(dirname "$linked_file")
      if [ "$linked_dir" != "$file_dir" ]; then
        needs_replacement=1
        break
      fi
    done < <(find "$BUNDELF_CODE_PATH" -samefile "$file")

    if [ "$needs_replacement" -eq 1 ]; then
        tmp_file=$(mktemp)
        cp -dp "$file" "$tmp_file" && mv "$tmp_file" "$file"
    fi
  fi

  return 0
}

# Function to replace links with direct copies when using relative RPATHs.
# Deprecated in 1.1.5: superseded by replace_link_new, which preserves same-directory symlinks.
replace_link() {
    local file="$1"
    local tmp_file

    [ "$BUNDELF_LIBPATH_TYPE" = "relative" ] || return 0

    # Handle symlinks
    if [ -L "$file" ]; then
        tmp_file=$(mktemp)
        cp -L "$file" "$tmp_file" && mv "$tmp_file" "$file"
        return 0
    fi

    # Handle hard links
    # If the link count is greater than 1, the file is a hard link
    local link_count=$(stat -c %h "$file")
    if [ "$link_count" -gt 1 ]; then
        # Create a temporary copy of the file, and overwrite the original file with the non-hard-linked copy
        local tmp_file=$(mktemp)
        cp -dp "$file" "$tmp_file" && mv "$tmp_file" "$file"
    fi

    return 0
}

patch_binaries_interpreter() {
  # For all ELF binaries, set the interpreter to our own.
  while IFS= read -r bin
  do
    patch_binary "$bin" || exit 1
  done < <(sort -u "$@")
}

generate_extra_system_lib_paths() {
  for p in "$@"
  do
    echo "$p"
  done
}

escape_regex() {
  local s=$1 d=${2:-/}
  printf '%s' "$s" | sed -e "s/[][(){}.^\$*+?|\\\\$d]/\\\\&/g"
}

generate_system_lib_paths() {
  # Generate a list of system library paths
  # - This will be used to set the RPATH for all binaries and libraries to an absolute or relative path.
  # This list is generated by:
  # - Extracting the path to each library, relative to $BUNDELF_CODE_PATH; add leading '/' if missing.
  local BUNDELF_CODE_PATH_REGEX=$(escape_regex "$BUNDELF_CODE_PATH")

  cat "$@" | \
    grep -E '\.so(\.[0-9]+)*$' | \
    sed -r "s|^$BUNDELF_CODE_PATH_REGEX||; s|/[^/]+$||; s|^[^/]|/|;" | \
    grep -E '^(/usr|/lib)(/|$)' | \
    sort -u
}

generate_unique_rpath() {
  local prefix="$1"; shift

  local abs_syspaths
  while IFS= read -r s
  do
    # Append each system path, prefixed with $prefix, and suffixed with a colon
    abs_syspaths="$abs_syspaths$(echo "$prefix${s}:")"
  done < <(sort -u "$@")

  # Remove trailing colon
  echo "$abs_syspaths" | sed 's/:$//'
}

patch_binaries_and_libs_rpath() {
  # For all ELF libs, set the RPATH to our own, and force RPATH use.
  local p
  local rpath
  local rpath_template

  if [ "$BUNDELF_LIBPATH_TYPE" = "absolute" ]; then
    rpath_template=$(generate_unique_rpath "$BUNDELF_CODE_PATH" "$TMP/system-lib-paths")
  else
    rpath_template=$(generate_unique_rpath "\$ORIGIN" "$TMP/system-lib-paths")
  fi

  echo "BUNDELF_CODE_PATH: $BUNDELF_CODE_PATH" >>$TMP/patchelf.log
  echo "RPATH template: ${rpath_template@Q}" >>$TMP/patchelf.log

  local BUNDELF_CODE_PATH_REGEX=$(escape_regex "$BUNDELF_CODE_PATH")

  while IFS= read -r lib
  do

    if [ "$BUNDELF_LIBPATH_TYPE" = "absolute" ]; then
      rpath="$rpath_template"

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in verify()
      if [ -n "$BUNDELF_NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        echo patchelf --add-needed "$BUNDELF_CODE_PATH$BUNDELF_NODE_PATH" $lib >>$TMP/patchelf.log
        patchelf --add-needed "$BUNDELF_CODE_PATH$BUNDELF_NODE_PATH" $lib >>$TMP/patchelf.log 2>&1 || exit 1
      fi

    else
      # If $lib is linked in different parts of the file hierarchy, then setting a relative RPATH on one file would break the correct RPATH set on another.
      # To prevent this, we un-hardlink any hardlinked files before we patch them.
      replace_link_new "$lib"

      p=$(dirname "$lib" | sed -r "s|^$BUNDELF_CODE_PATH_REGEX[/]+||; s|[^/]+|..|g")
      # rpath="\$ORIGIN/$p/lib:\$ORIGIN/$p/usr/lib:\$ORIGIN/$p/usr/lib/xtables"
      rpath="$(echo "$rpath_template" | sed "s|\$ORIGIN|\$ORIGIN${p:+/$p}|g")"

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in verify()
      if [ -n "$BUNDELF_NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        local NODE_DIR=$(dirname $BUNDELF_NODE_PATH)
        local NODE_BASENAME=$(basename $BUNDELF_NODE_PATH)

        # Augment rpath with relative path to the NODE_DIR
        rpath="$rpath:\$ORIGIN/${p:+$p}$NODE_DIR"

        # Add a needed dynamic library dependency for NODE_BASENAME (will be searched for within the augmented rpath)
        echo patchelf --add-needed "$NODE_BASENAME" "$lib" >>$TMP/patchelf.log
        patchelf --add-needed "$NODE_BASENAME" "$lib" >>$TMP/patchelf.log 2>&1 || exit 1
      fi
    fi

    echo patchelf --force-rpath --set-rpath "${rpath@Q}" "$lib" >>$TMP/patchelf.log
    patchelf --force-rpath --set-rpath \
      "$rpath" \
      "$lib" >>$TMP/patchelf.log 2>&1 || exit 1

    # Fail silently if patchelf fails to set the interpreter: this is a catch-all for libraries like /usr/lib/libcap.so.2
    # which strangely have an interpreter set.
    patch_binary "$lib"

  done < <(sort -u "$@")
}

copy_and_scan_for_dynamics() {
  # Find all ELF files that are dynamically linked.
  # - This should includes all Theia .node files and spawn-helper, but not statically-linked binaries like 'rg'
  # - The only way to tell if a file is an ELF binary (or library) is to check the first 4 bytes for the magic byte sequence.

  mkdir -p "$BUNDELF_CODE_PATH"

  for q in "$@"
  do
    # Skip non-existent paths
    [ -d "$q" ] || continue

    tar cv "$q" 2>/dev/null | tar x -C "$BUNDELF_CODE_PATH/"

    find "$q" -type f ! -name '*.o' -print0 | xargs -0 -P $(nproc) -I '{}' hexdump -n 4 -e '4/1 "%2x" " {}\n"' {} | sed '/^7f454c46/!d; s/^7f454c46 //' | xargs -P $(nproc) file | grep dynamically
  done
}

get_dynamics_interpretable() {
  grep interpreter "$@" | cut -d':' -f1 | sed -r "s!^!$BUNDELF_CODE_PATH!"
}

get_dynamics_noninterpretable() {
  grep -v interpreter "$@" | cut -d':' -f1 | sed -r "s!^!$BUNDELF_CODE_PATH!"
}

write_digest() {
  # Prepare full and unique list of ELF binaries and libs for reference purposes and for checking
  sort -u $TMP/bins-copied >"$BUNDELF_CODE_PATH/.binelfs"
  sort -u $TMP/libs-copied-final >"$BUNDELF_CODE_PATH/.libelfs"
}

init() {
  for dep in file hexdump xargs patchelf ldd
  do
    if ! [ -x "$(which $dep)" ]; then
      depsmissing=1
      echo "ERROR: Command '$dep' not found in PATH '$PATH'" >&2
    fi
  done

  [ -n "$depsmissing" ] && return 1

  # Initialise
  mkdir -p "$TMP"
  >"$TMP/bins-copied"
  >"$TMP/libs-copied"
  >"$TMP/libs-copied-final"
  >"$TMP/libs"
  >"$TMP/libs-extra"
  >"$TMP/libs-deps"
  >"$TMP/libs-new"
  >"$TMP/scanned-dynamics"
  >"$TMP/system-lib-paths"
}

all() {
  # Split space-separated env vars into arrays for correct multi-value handling
  read -ra _bins              <<< "$BUNDELF_BINARIES"
  read -ra _dynpaths          <<< "$BUNDELF_DYNAMIC_PATHS"
  read -ra _extra_libs        <<< "$BUNDELF_EXTRA_LIBS"
  read -ra _extra_syslibpaths <<< "$BUNDELF_EXTRA_SYSTEM_LIB_PATHS"

  # Copy elf binaries to BUNDELF_CODE_PATH and generate 'bins-copied' list of ELF binaries
  copy_binaries "${_bins[@]}" >>"$TMP/bins-copied"

  # Scan for additional dynamic binaries and libs
  copy_and_scan_for_dynamics "${_dynpaths[@]}" >>"$TMP/scanned-dynamics"

  # Add the intepretable dynamics to 'bins-copied'
  get_dynamics_interpretable "$TMP/scanned-dynamics" >>"$TMP/bins-copied"

  # Add the non-intepretable dynamics to 'libs-copied'
  get_dynamics_noninterpretable "$TMP/scanned-dynamics" >>"$TMP/libs-copied"

  # Scan for extra libraries not formally declared as dependencies
  scan_extra_libs "${_extra_libs[@]}" >>"$TMP/libs-extra"

  # Generate unique list of dynamic binaries and libs
  sort -u "$TMP/bins-copied" "$TMP/libs-copied" "$TMP/libs-extra" >>"$TMP/libs"

  # Iteratively find all library dependencies of libraries in 'libs', until no new libraries are found
  while true
  do
    # Find library dependencies of libraries in 'libs'; write to 'libs-new'
    find_lib_deps "$TMP/libs" >>"$TMP/libs-deps"

    sort -u "$TMP/libs" "$TMP/libs-deps" >"$TMP/libs-new"

    if diff -q "$TMP/libs" "$TMP/libs-new" >/dev/null 2>&1; then
      break
    fi

    mv "$TMP/libs-new" "$TMP/libs"
  done

  # Copy system libraries from 'libs' to BUNDELF_CODE_PATH and write the complete set of destination
  # paths (newly copied + pre-existing) to 'libs-copied-final', for use by patch_binaries_and_libs_rpath.
  copy_libs "$TMP/libs" >"$TMP/libs-copied-final"

  # Patch interpreter on all ELF binaries in 'bins-copied'
  patch_binaries_interpreter "$TMP/bins-copied"

  # Generate non-unique list of system library paths:
  generate_system_lib_paths "$TMP/libs-copied-final" >>"$TMP/system-lib-paths"
  generate_extra_system_lib_paths "${_extra_syslibpaths[@]}" >>"$TMP/system-lib-paths"

  # Patch RPATH on all binaries in 'bins-copied' and libs in 'libs-copied-final'
  patch_binaries_and_libs_rpath "$TMP/bins-copied" "$TMP/libs-copied-final"

  # Write a summary of binaries and libraries to BUNDELF_CODE_PATH
  write_digest

  # Copy LD and create convenience symlink to ld
  mkdir -p "$BUNDELF_CODE_PATH$(dirname "$LD_PATH")"
  cp "$LD_PATH" "$BUNDELF_CODE_PATH$(dirname "$LD_PATH")/"
  ln -sf $(echo "$LD_PATH" | sed -r 's|^/lib/|./|') "$BUNDELF_CODE_PATH/lib/ld"
}

# Run with --verify from within any distribution, to check that all dynamic library dependencies
# are correctly being resolved to versions stored within BUNDELF_CODE_PATH.
if [ "$1" = "--verify" ]; then
  # Check the full list for any library dependencies being inadvertently resolved outside the install location.
  # Returns true if OK, false on any problems.
  init || exit 1
  verify
elif [ "$1" = "--bundle" ]; then
  init || exit 1
  all
  verify
fi
