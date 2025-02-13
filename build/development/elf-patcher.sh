#!/bin/sh

# Patches all required binaries and dynamic libraries (ELF libs) for full path-portability.
# - Copies all required binaries and ELF libs to the install location (CODE_PATH).
# - Sets the interpreter for all binaries to the exec location (EXEC_PATH), to allow for mounting the CODE_PATH at EXEC_PATH.
# - Sets the RPATH for all binaries and ELF libs to an absolute or relative path (according to LIBPATH_TYPE).
# - Adds a link to the dynamic linker (ld-musl-*.so.1) in the install location (CODE_PATH/lib/ld).

# Environment variable inputs:
# - BINARIES - list required binaries to be scanned and copied
# - DYNAMIC_PATHS - list optional paths to be scanned and copied
# - EXTRA_LIBS - list extra libraries to be scanned and copied
# - CODE_PATH - path where binaries and libraries will be copied to
# - EXEC_PATH - path where binaries and libraries will be executed from
# = MERGE_BINDIRS - non-empty if all specified binaries should be moved to $CODE_PATH/bin
# - LIBPATH_TYPE - whether to use absolute or relative paths (the default) for RPATH

# EXEC_PATH defaults to CODE_PATH
EXEC_PATH="${EXEC_PATH:-$CODE_PATH}"

# Determine LD_MUSL filename, which is architecture-dependent
# e.g. ld-musl-aarch64.so.1 (linux/arm64), ld-musl-armhf.so.1 (linux/arm/v7), ld-musl-x86_64.so.1 (linux/amd64)
LD_MUSL_PATH=$(ls -1 /lib/ld-musl-* | head -n 1)
LD_MUSL_BIN=$(basename $LD_MUSL_PATH)

# Whether to use absolute or relative paths for RPATH
LIBPATH_TYPE="${LIBPATH_TYPE:-relative}"

append() {
  while read line; do echo "${line}${1}"; done
}

# Check that all dynamic library dependencies are correctly being resolved to versions stored within CODE_PATH.
# Prints any 
_checkelfs() {
  local status=0

  # Deduce CODE_PATH from elf-patcher.sh execution path, if none provided (useful when called with --checkelfs within an alternative environment).
  [ -z $CODE_PATH ] && CODE_PATH=$(realpath $(dirname $0)/..)

  # Now check the ELF files
  for lib in $(cat $CODE_PATH/.binelfs $CODE_PATH/.libelfs)
  do
    echo -n "Checking: $lib ... " >&2
    $CODE_PATH$LD_MUSL_PATH --list $lib 2>/dev/null | sed -nr '/=>/!d; s/^\s*(\S+)\s*=>\s*(.*?)(\s*\(0x[0-9a-f]+\))?$/- \2 \1/;/^.+$/p;' | egrep -v "^- ($CODE_PATH/|$EXEC_PATH/.*/$LD_MUSL_BIN)"
  
    # If any libraries do not match the expected pattern, grep returns true
    if [ $? -eq 0 ]; then
      status=1
      echo "BAD"
    else
      echo "GOOD"
    fi

    sleep 0.02
  done
  
  return $status
}

checkelfs() {
  _checkelfs
  exit 0
  exit $?
}

copy_binaries() {
  # Copy any binaries we require to the install location.
  # Write their paths to cmd-elf-bin.

  if [ -n "$MERGE_BINDIRS" ]; then
    mkdir -p $CODE_PATH/bin
  else
    mkdir -p $CODE_PATH
  fi

  for bin in "$@"
  do
    local file=$(which $bin)

    if [ -n "$file" ]; then
      if [ -z "$MERGE_BINDIRS" ]; then
        tar cv $file 2>/dev/null | tar x -C $CODE_PATH/
        echo "$CODE_PATH$file"
      else
        cp -p $file $CODE_PATH/bin/
        echo "$CODE_PATH/bin/$bin"
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
  cat "$@" | sort -u | xargs -n 1 -I '{}' ldd '{}' 2>/dev/null | sed -nr 's/^\s*(.*)=>\s*(.*?)\s.*$/\1 \2/p' | sort -u
}

copy_libs() {
  mkdir -p $CODE_PATH

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
    cp -a --parents -L $dest $CODE_PATH

    # If needed, add a symlink from $lib to $(basename $dest)
    if [ "$(basename $dest)" != "$lib" ]; then
      if cd $CODE_PATH/$(dirname $dest); then
        ln -s $(basename $dest) $lib
        cd - >/dev/null
      fi
    fi

    if [ "$dest" != "$LD_MUSL_PATH" ]; then
        echo "$CODE_PATH$dest"
    fi
  done
}

patch_binary() {
  local bin="$1"

  if patchelf --set-interpreter $EXEC_PATH$LD_MUSL_PATH $bin 2>/dev/null; then
    echo patchelf --set-interpreter $EXEC_PATH$LD_MUSL_PATH $bin >>/tmp/patchelf.log
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

patch_binaries_and_libs_rpath() {
  # For all ELF libs, set the RPATH to our own, and force RPATH use.
  local p
  local rpath

  for lib in $(sort -u "$@")
  do

    if [ "$LIBPATH_TYPE" = "absolute" ]; then
      echo patchelf --force-rpath --set-rpath $CODE_PATH/lib:$CODE_PATH/usr/lib:$CODE_PATH/usr/lib/xtables $lib >>/tmp/patchelf.log
      patchelf --force-rpath --set-rpath $CODE_PATH/lib:$CODE_PATH/usr/lib:$CODE_PATH/usr/lib/xtables $lib >>/tmp/patchelf.log 2>&1 || exit 1

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in checkelfs()
      if [ -n "$NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        echo patchelf --add-needed "$CODE_PATH$NODE_PATH" $lib >>/tmp/patchelf.log
        patchelf --add-needed "$CODE_PATH$NODE_PATH" $lib >>/tmp/patchelf.log 2>&1 || exit 1
      fi

    else
      # If $lib is hardlinked in different parts of the file hierarchy, then setting a relative RPATH on one file would break the correct RPATH set on another.
      # To prevent this, we un-hardlink any hardlinked files before we patch them.
      replace_hard_link "$lib"

      p=$(dirname "$lib" | sed -r "s|^$CODE_PATH[/]+||; s|[^/]+|..|g")
      rpath="\$ORIGIN/$p/lib:\$ORIGIN/$p/usr/lib:\$ORIGIN/$p/usr/lib/xtables"

      # Add node as a needed library to '.node' files, to avoid misleading ldd errors in checkelfs()
      if [ -n "$NODE_PATH" ] && echo "$lib" | grep -qE "\.node$"; then
        local NODE_DIR=$(dirname $NODE_PATH)
        local NODE_BASENAME=$(basename $NODE_PATH)

        # Augment rpath with relative path to the NODE_DIR
        rpath="$rpath:\$ORIGIN/$p$NODE_DIR"

        # Add a needed dynamic library dependency for NODE_BASENAME (will be searched for within the augmented rpath)
        echo patchelf --add-needed "$NODE_BASENAME" "$lib" >>/tmp/patchelf.log
        patchelf --add-needed "$NODE_BASENAME" "$lib" >>/tmp/patchelf.log 2>&1 || exit 1

        # patchelf --add-needed "$CODE_PATH$NODE_PATH" $lib || exit 1
      fi

      echo patchelf --force-rpath --set-rpath "$rpath" "$lib" >>/tmp/patchelf.log
      patchelf --force-rpath --set-rpath \
        "$rpath" \
        "$lib" >>/tmp/patchelf.log 2>&1 || exit 1
    fi

    # Fail silently if patchelf fails to set the interpreter: this is a catch-all for add libraries like /usr/lib/libcap.so.2
    # which strangely have an interpreter set.
    patch_binary "$lib"

  done
}

copy_and_scan_for_dynamics() {
  # Find all ELF files that are dynamically linked.
  # - This should includes all Theia .node files and spawn-helper, but not statically-linked binaries like 'rg'
  # - The only way to tell if a file is an ELF binary (or library) is to check the first 4 bytes for the magic byte sequence.

  mkdir -p $CODE_PATH

  for q in "$@"
  do
    tar cv "$q" 2>/dev/null | tar x -C $CODE_PATH/

    # find "$q" -type f ! -name '*.o' -exec hexdump -n 4 -e '4/1 "%2x" " {}\n"' {} \; | sed '/^7f454c46/!d; s/^7f454c46 //' | xargs -n 1 -P 4 file | grep dynamically

    find "$q" -type f ! -name '*.o' -print0 | xargs -0 -n $(nproc) -I '{}' hexdump -n 4 -e '4/1 "%2x" " {}\n"' {} | sed '/^7f454c46/!d; s/^7f454c46 //' | xargs -n $(nproc) -P 4 file | grep dynamically
  done
}

get_dynamics_interpretable() {
  grep interpreter "$@" | cut -d':' -f1 | sed -r "s!^!$CODE_PATH!"
}

get_dynamics_noninterpretable() {
  grep -v interpreter "$@" | cut -d':' -f1 | sed -r "s!^!$CODE_PATH!"
}

write_digest() {
  # Prepare full and unique list of ELF binaries and libs for reference purposes and for checking
  sort -u /tmp/cmd-elf-bin >$CODE_PATH/.binelfs
  sort -u /tmp/cmd-elf-lib >$CODE_PATH/.libelfs
}

init() {
# Initialise
>/tmp/cmd-elf-bin
>/tmp/cmd-elf-lib
>/tmp/libs-tuples
>/tmp/libs-extra-tuples
>/tmp/scanned-dynamics
}

all() {
  # Copy elf binaries to CODE_PATH and generate 'cmd-elf-bin' list of ELF binaries
  copy_binaries $BINARIES >>/tmp/cmd-elf-bin

  # Scan for additional dynamic binaries and libs
  copy_and_scan_for_dynamics $DYNAMIC_PATHS >>/tmp/scanned-dynamics

  # Add the intepretable dynamics to 'cmd-elf-bin'
  get_dynamics_interpretable /tmp/scanned-dynamics >>/tmp/cmd-elf-bin

  # Add the non-intepretable dynamics to 'libs'
  get_dynamics_noninterpretable /tmp/scanned-dynamics >>/tmp/cmd-elf-lib

  # Find library dependencies of these dynamic binaries and libs; write tuples to 'libs'
  find_lib_deps /tmp/cmd-elf-bin /tmp/cmd-elf-lib >>/tmp/libs-tuples

  # Scan for extra libraries not formally declared as dependencies, and append tuples to 'libs'
  scan_extra_libs $EXTRA_LIBS >>/tmp/libs-extra-tuples

  # Copy the library tuples from 'libs' to CODE_PATH and append to 'cmd-elf-lib'
  copy_libs /tmp/libs-tuples /tmp/libs-extra-tuples >>/tmp/cmd-elf-lib

  # Patch interpreter on all ELF binaries in 'cmd-elf-bin'
  patch_binaries_interpreter /tmp/cmd-elf-bin

  # Patch RPATH on all binaries in 'cmd-elf-bin' and libs in 'cmd-elf-lib'
  # TODO: This duplicates running patch_binaries_interpreter on all 'cmd-elf-bin' files, in order that it can be run in relaxed mode on 'cmd-elf-lib'
  patch_binaries_and_libs_rpath /tmp/cmd-elf-bin /tmp/cmd-elf-lib

  # Write a summary of binaries and libraries to CODE_PATH
  write_digest

  # Symlink ld-musl-*.so.1 to ld
  ln -s $LD_MUSL_BIN $CODE_PATH/lib/ld
}

init

# Run with --checkelfs from within any distribution, to check that all dynamic library dependencies
# are correctly being resolved to versions stored within CODE_PATH.
if [ "$1" = "--checkelfs" ]; then
  # Check the full list for any library dependencies being inadvertently resolved outside the install location.
  # Returns true if OK, false on any problems.
  checkelfs
elif [ "$1" = "--patchelfs" ]; then
  all
  checkelfs
fi
