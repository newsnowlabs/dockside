#!/bin/sh -e

PLUGIN_DIR=~/theia-plugins

mkdir -p $PLUGIN_DIR

# for vsix in \
#   https://github.com/vuejs/vetur/releases/download/v0.24.0/vetur-0.24.0.vsix
# do
#   file=$(basename $vsix)
#   echo "Downloading vsix plugin $vsix to $file ..." >&2
#   curl --fail --silent --location --retry 3 --max-time 20 -o $PLUGIN_DIR/$file $vsix
# done

# RICHTERGER="2.5.0"
# echo "Downloading vsix plugin richterger.perl-$RICHTERGER.vsix ..." >&2
# curl --fail --silent --location --retry 2 --max-time 20 -o $PLUGIN_DIR/richterger.perl-$RICHTERGER.vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/richterger/vsextensions/perl/$RICHTERGER/vspackage --compressed || \
# curl --fail --silent --location --retry 3 --max-time 20 -o $PLUGIN_DIR/richterger.perl-$RICHTERGER.vsix https://storage.googleapis.com/dockside/vsix/richterger.perl-$RICHTERGER.vsix || \
# curl --fail --silent --location --retry 3 --max-time 20 -o $PLUGIN_DIR/richterger.perl-2.2.0.vsix https://storage.googleapis.com/dockside/vsix/richterger.perl-2.2.0.vsix