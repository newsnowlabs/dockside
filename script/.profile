#!/bin/sh

export BUNDLE_PATH=/home/dockside/.gems

cat <<_EOE_
WELCOME TO THE DOCKSIDE.IO JEKYLL IMAGE

To re-launch jekyll within the terminal, enter the following at the
prompt:
$ pkill jekyll
$ ./script/server --incremental

_EOE_
