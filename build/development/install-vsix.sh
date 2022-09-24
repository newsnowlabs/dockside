#!/bin/bash -e

PLUGIN_DIR=~/theia-plugins

mkdir -p $PLUGIN_DIR

for vsix in \
  https://github.com/vuejs/vetur/releases/download/v0.24.0/vetur-0.24.0.vsix \
  https://github.com/eclipse-theia/vscode-builtin-extensions/releases/download/v1.39.1-prel/javascript-1.39.1-prel.vsix \
  https://open-vsx.org/api/vscode/css/1.54.1/file/vscode.css-1.54.1.vsix \
  https://open-vsx.org/api/dbaeumer/vscode-eslint/2.1.8/file/dbaeumer.vscode-eslint-2.1.8.vsix \
  https://open-vsx.org/api/vscode/docker/1.54.1/file/vscode.docker-1.54.1.vsix \
  https://open-vsx.org/api/vscode/html/1.54.1/file/vscode.html-1.54.1.vsix \
  https://open-vsx.org/api/vscode/ini/1.54.1/file/vscode.ini-1.54.1.vsix \
  https://open-vsx.org/api/vscode/json/1.54.1/file/vscode.json-1.54.1.vsix \
  https://open-vsx.org/api/vscode/less/1.54.1/file/vscode.less-1.54.1.vsix \
  https://open-vsx.org/api/vscode/merge-conflict/1.54.1/file/vscode.merge-conflict-1.54.1.vsix \
  https://open-vsx.org/api/vscode/perl/1.54.1/file/vscode.perl-1.54.1.vsix \
  https://open-vsx.org/api/vscode/scss/1.54.1/file/vscode.scss-1.54.1.vsix \
  https://open-vsx.org/api/vscode/shellscript/1.54.1/file/vscode.shellscript-1.54.1.vsix \
  https://open-vsx.org/api/wayou/vscode-todo-highlight/1.0.4/file/wayou.vscode-todo-highlight-1.0.4.vsix
do
  file=$(basename $vsix)
  echo "Downloading vsix plugin $vsix to $file ..." >&2
  curl --fail --silent --location -o $PLUGIN_DIR/$file $vsix
done

echo "Downloading vsix plugin richterger.perl-2.2.0.vsix ..." >&2
curl --fail --silent --location -o $PLUGIN_DIR/richterger.perl-2.2.0.vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/richterger/vsextensions/perl/2.2.0/vspackage --compressed || \
curl --fail --silent --location -o $PLUGIN_DIR/richterger.perl-2.2.0.vsix https://storage.googleapis.com/dockside/vsix/richterger.perl-2.2.0.vsix
