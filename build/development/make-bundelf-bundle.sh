#!/bin/sh

# BundELF - ELF binary and dynamic library patcher/bundler for making portable/relocatable executables
# ----------------------------------------------------------------------------------------------------
#
# Licence: Apache 2.0
# Authors: Struan Bartlett, NewsNow Labs, NewsNow Publishing Ltd
# Version: 1.0.0
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
LD_BIN=$(basename $LD_PATH)

TMP=/tmp/bundelf.$$

append() {
  while read line; do echo "${line}${1}"; done
}

# Check that all dynamic library dependencies are correctly being resolved to versions stored within BUNDELF_CODE_PATH.
# Prints any 
_verify() {
  local status=0

  # Deduce BUNDELF_CODE_PATH from elf-patcher.sh execution path, if none provided (useful when called with --verify within an alternative environment).
  [ -z $BUNDELF_CODE_PATH ] && BUNDELF_CODE_PATH=$(realpath $(dirname $0)/..)

  # Now check the ELF files
  for lib in $(cat $BUNDELF_CODE_PATH/.binelfs $BUNDELF_CODE_PATH/.libelfs)
  do
    echo -n "Checking: $lib ... " >&2
    $BUNDELF_CODE_PATH$LD_PATH --list $lib 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/- \2 \1/;/^.+$/p;' | egrep -v "^- ($BUNDELF_CODE_PATH/|$BUNDELF_EXEC_PATH/.*/$LD_BIN)"
  
    # If any libraries do not match the expected pattern, grep returns true
    if [ $? -eq 0 ]; then
      status=1
      echo "BAD"
    else
      echo "GOOD"
    fi

    sleep 0.01
  done
  
  return $status
}

verify() {
  _verify
  exit $?
}

copy_binaries() {
  # Copy any binaries we require to the install location.
  # Write their paths to cmd-elf-bin.

  if [ -n "$BUNDELF_MERGE_BINDIRS" ]; then
    mkdir -p $BUNDELF_CODE_PATH/bin
  else
    mkdir -p $BUNDELF_CODE_PATH
  fi

  for bin in "$@"
  do
    local file=$(which $bin)

    if [ -n "$file" ]; then
      if [ -z "$BUNDELF_MERGE_BINDIRS" ]; then
        tar cv $file 2>/dev/null | tar x -C $BUNDELF_CODE_PATH/
        echo "$BUNDELF_CODE_PATH$file"
      else
        cp -p $file $BUNDELF_CODE_PATH/bin/
        echo "$BUNDELF_CODE_PATH/bin/$bin"
      fi
    fi
  done
}

scan_extra_libs() {
  for p in "$@"
  do
    find "$p" ! -type d | while read lib
      do
        local f=$(basename $lib)
        echo "$f $lib"
      done
  done
}

# Using ldd, generate list of resolved library filepaths for each ELF binary and library,
# logging first argument (to be used as $lib) and second argument (to be used as $dest).
# e.g.
# libaio.so.1  /usr/lib/libaio.so.1
# libblkid.so.1  /lib/libblkid.so.1
find_lib_deps() {
  cat "$@" | sort -u | xargs -P $(nproc) -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(.*?)\s.*$/\1 \2/p' | sort -u
}

copy_libs() {
  mkdir -p $BUNDELF_CODE_PATH

  # For each resolved library filepath:
  # - Copy $dest to the install location.
  # - If $dest is a symlink, copy the symlink to the install location too.
  # - If needed, add a symlink from $lib to $dest.
  #
  # N.B. These steps are all needed to ensure the Alpine dynamic linker can resolve library filepaths as required.
  #      For more, see https://www.musl-libc.org/doc/1.0.0/manual.html
  #
  sort -u "$@" | while read lib dest
  do
    # Copy $dest; and if $dest is a symlink, copy its target.
    # This could conceivably result in duplicates if multiple symlinks point to the same target,
    # but is much simpler than trying to copy symlinks and targets separately.
    cp -a --parents -L $dest $BUNDELF_CODE_PATH

    # If needed, add a symlink from $lib to $(basename $dest)
    if [ "$(basename $dest)" != "$lib" ]; then
      if cd $BUNDELF_CODE_PATH/$(dirname $dest); then
        ln -s $(basename $dest) $lib
        cd - >/dev/null
      fi
    fi

    if [ "$dest" != "$LD_PATH" ]; then
        echo "$BUNDELF_CODE_PATH$dest"
    fi
  done
}

patch_binary() {
  local bin="$1"

  if patchelf --set-interpreter $BUNDELF_EXEC_PATH$LD_PATH $bin 2>/dev/null; then
    echo patchelf --set-interpreter $BUNDELF_EXEC_PATH$LD_PATH $bin >>$TMP/patchelf.log
    return 0
  fi

  return 1
}

# Function to replace a hard-linked file with a non-hard-linked copy
replace_hard_link() {
    local file="$1"
    
    # Check if the file exists
    if [ ! -e "$file" ]; then
        echo "replace_hard_link: file '$file' does not exist."
        exit 1
    fi

    # Get the number of hard links to the file
    local link_count=$(stat -c %h "$file")

    # If the link count is greater than 1, the file is a hard link
    if [ "$link_count" -gt 1 ]; then
        # Create a temporary copy of the file, and overwrite the original file with the non-hard-linked copy
        local tmp_file=$(mktemp)
        cp -dp "$file" "$tmp_file" && mv "$tmp_file" "$file"
    fi

    return 0
}

patch_binaries_interpreter() {
  # For all ELF binaries, set the interpreter to our own.
  for bin in $(sort -u "$@")
  do
    patch_binary "$bin" || exit 1
  done
}

generate_extra_system_lib_paths() {
  for p in "$@"
  do
    echo $p
  done 
}

generate_system_lib_paths() {
  # Generate a list of system library paths
  # - This will be used to set the RPATH for all binaries and libraries to an absolute or relative path.

  # This list is generated by:
  # - Running the dynamic linker with --list-diagnostics
  # - Extracting the system_dirs path from the output
  # - Removing any trailing slashes
  # $BUNDELF_CODE_PATH$LD_PATH --list-diagnostics | grep ^path.system_dirs | sed -r 's|^.*="([^"]+)/?"$|\1|; s|/$||' | sort -u

  # This list is generated by:
  # - Extracting the path to each library, relative to $BUNDELF_CODE_PATH; add leading '/' if missing.
  cat "$@" | \
    grep -E '\.so(\.[0-9]+)*$' | \
    sed -r "s|^$BUNDELF_CODE_PATH||; s|/[^/]+$||; s|^[^/]|/|;" | \
    grep -E '^(/usr|/lib)(/|$)' | \
    sort -u
}

generate_unique_rpath() {
  local prefix="$1"; shift

  local abs_syspaths  
  for s in $(sort -u "$@")
  do
    abs_syspaths="$abs_syspaths$(echo "$prefix${s}:")"
  done

  # Remove trailing colon
  echo $abs_syspaths | sed 's/:$//'
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

  for lib in $(sort -u "$@")
  do

    if [ "$BUNDELF_LIBPATH_TYPE" = "absolute" ]; then
      rpath="$rpath_template"

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in verify()
      if [ -n "$BUNDELF_NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        echo patchelf --add-needed "$BUNDELF_CODE_PATH$BUNDELF_NODE_PATH" $lib >>$TMP/patchelf.log
        patchelf --add-needed "$BUNDELF_CODE_PATH$BUNDELF_NODE_PATH" $lib >>$TMP/patchelf.log 2>&1 || exit 1
      fi

    else
      # If $lib is hardlinked in different parts of the file hierarchy, then setting a relative RPATH on one file would break the correct RPATH set on another.
      # To prevent this, we un-hardlink any hardlinked files before we patch them.
      replace_hard_link "$lib"

      p=$(dirname "$lib" | sed -r "s|^$BUNDELF_CODE_PATH[/]+||; s|[^/]+|..|g")
      # rpath="\$ORIGIN/$p/lib:\$ORIGIN/$p/usr/lib:\$ORIGIN/$p/usr/lib/xtables"
      rpath="$(echo "$rpath_template" | sed "s|\$ORIGIN|\$ORIGIN/$p|g")"

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in verify()
      if [ -n "$BUNDELF_NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        local NODE_DIR=$(dirname $BUNDELF_NODE_PATH)
        local NODE_BASENAME=$(basename $BUNDELF_NODE_PATH)

        # Augment rpath with relative path to the NODE_DIR
        rpath="$rpath:\$ORIGIN/$p$NODE_DIR"

        # Add a needed dynamic library dependency for NODE_BASENAME (will be searched for within the augmented rpath)
        echo patchelf --add-needed "$NODE_BASENAME" "$lib" >>$TMP/patchelf.log
        patchelf --add-needed "$NODE_BASENAME" "$lib" >>$TMP/patchelf.log 2>&1 || exit 1
      fi
    fi

    echo patchelf --force-rpath --set-rpath "$rpath" "$lib" >>$TMP/patchelf.log
    patchelf --force-rpath --set-rpath \
      "$rpath" \
      "$lib" >>$TMP/patchelf.log 2>&1 || exit 1

    # Fail silently if patchelf fails to set the interpreter: this is a catch-all for add libraries like /usr/lib/libcap.so.2
    # which strangely have an interpreter set.
    patch_binary "$lib"

  done
}

copy_and_scan_for_dynamics() {
  # Find all ELF files that are dynamically linked.
  # - This should includes all Theia .node files and spawn-helper, but not statically-linked binaries like 'rg'
  # - The only way to tell if a file is an ELF binary (or library) is to check the first 4 bytes for the magic byte sequence.

  mkdir -p $BUNDELF_CODE_PATH

  for q in "$@"
  do
    tar cv "$q" 2>/dev/null | tar x -C $BUNDELF_CODE_PATH/

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
  sort -u $TMP/cmd-elf-bin >$BUNDELF_CODE_PATH/.binelfs
  sort -u $TMP/cmd-elf-lib >$BUNDELF_CODE_PATH/.libelfs
}

init() {
  for dep in file hexdump xargs patchelf
  do
    if ! [ -x "$(which $dep)" ]; then
      depsmissing=1
      echo "ERROR: Command '$dep' not found in PATH '$PATH'" >&2
    fi
  done

  [ -n "$depsmissing" ] && return 1

  # Initialise
  mkdir -p "$TMP"
  >$TMP/cmd-elf-bin
  >$TMP/cmd-elf-lib
  >$TMP/libs-tuples
  >$TMP/libs-extra-tuples
  >$TMP/scanned-dynamics
  >$TMP/system-lib-paths
}

all() {
  # Copy elf binaries to BUNDELF_CODE_PATH and generate 'cmd-elf-bin' list of ELF binaries
  copy_binaries $BUNDELF_BINARIES >>$TMP/cmd-elf-bin

  # Scan for additional dynamic binaries and libs
  copy_and_scan_for_dynamics $BUNDELF_DYNAMIC_PATHS >>$TMP/scanned-dynamics

  # Add the intepretable dynamics to 'cmd-elf-bin'
  get_dynamics_interpretable $TMP/scanned-dynamics >>$TMP/cmd-elf-bin

  # Add the non-intepretable dynamics to 'libs'
  get_dynamics_noninterpretable $TMP/scanned-dynamics >>$TMP/cmd-elf-lib

  # Find library dependencies of these dynamic binaries and libs; write tuples to 'libs'
  find_lib_deps $TMP/cmd-elf-bin $TMP/cmd-elf-lib >>$TMP/libs-tuples

  # Scan for extra libraries not formally declared as dependencies, and append tuples to 'libs'
  scan_extra_libs $BUNDELF_EXTRA_LIBS >>$TMP/libs-extra-tuples

  # Copy the library tuples from 'libs' to BUNDELF_CODE_PATH and append to 'cmd-elf-lib'
  copy_libs $TMP/libs-tuples $TMP/libs-extra-tuples >>$TMP/cmd-elf-lib

  # Patch interpreter on all ELF binaries in 'cmd-elf-bin'
  patch_binaries_interpreter $TMP/cmd-elf-bin

  # Generate non-unique list of system library paths:
  generate_system_lib_paths $TMP/cmd-elf-lib >>$TMP/system-lib-paths
  generate_extra_system_lib_paths $BUNDELF_EXTRA_SYSTEM_LIB_PATHS >>$TMP/system-lib-paths

  # Patch RPATH on all binaries in 'cmd-elf-bin' and libs in 'cmd-elf-lib'
  # TODO: This duplicates running patch_binaries_interpreter on all 'cmd-elf-bin' files, in order that it can be run in relaxed mode on 'cmd-elf-lib'
  patch_binaries_and_libs_rpath $TMP/cmd-elf-bin $TMP/cmd-elf-lib

  # Write a summary of binaries and libraries to BUNDELF_CODE_PATH
  write_digest

  # Copy LD and and create copnvenience symlink it to ld
  cp --parents $LD_PATH $BUNDELF_CODE_PATH
  ln -s $(echo $LD_PATH | sed -r 's|^/lib/|./|') $BUNDELF_CODE_PATH/lib/ld
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
