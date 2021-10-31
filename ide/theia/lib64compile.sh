#!/bin/bash

LIBS='libc6 libgcc1 libstdc++6'

# Needed by setpriv
LIBS+=' libcap-ng0'

for f in $(for a in $LIBS; do dpkg -L $a:amd64; done | egrep -v '(/gconv/|/audit/|\.conf$|^/lib64/)' | egrep '(\.so$|\.so\.)'); do [ -f "$f" ] && cp -a $f /home/newsnow/lib64; done
