#!/usr/bin/env sh
rsync -avm --include='*.lua' -f 'hide,! */' results/ffi ..
