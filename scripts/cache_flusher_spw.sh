#!/usr/bin/env bash
# cache_flusher adapted for password-file sudo. Keeps GB10 page cache small during
# model load so NVRM can allocate the KV slab. 25 min max, flush when Cached > 40 GiB.
end=$((SECONDS+1500))
while [ $SECONDS -lt $end ]; do
  c=$(awk '/^Cached:/{print int($2/1048576)}' /proc/meminfo)
  if [ "${c:-0}" -gt 40 ]; then
    sync
    cat /tmp/.spw | sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
  fi
  sleep 5
done
