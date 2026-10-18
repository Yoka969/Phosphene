#!/bin/sh
set -eu

data_dir="${PHOSPHENE_DATA_DIR:-/data}"
case "$data_dir" in
  /*) ;;
  *)
    echo "PHOSPHENE_DATA_DIR must be an absolute path" >&2
    exit 1
    ;;
esac

if ! mkdir -p "$data_dir"; then
  echo "Phosphene could not create $data_dir. Check the persistent volume mount and permissions." >&2
  exit 1
fi

# 内存上限自适应：从 cgroup 读取容器限制，按 50% 推导 V8 老生代上限。
# 硬编码过大会触发容器级 OOM（exit 137），过小会触发 V8 堆溢出，两者都会重启服务。
detect_memory_limit_mb() {
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null || true)
    case "$v" in
      ""|max|*[!0-9]*) continue ;;
    esac
    # 超过 1 PiB 视为未设置上限
    if [ "$v" -gt 1125899906842624 ]; then continue; fi
    echo $((v / 1048576))
    return 0
  done
  return 1
}

limit_mb="$(detect_memory_limit_mb || true)"
heap_mb="${PHOSPHENE_NODE_HEAP_MB:-}"
if [ -n "$heap_mb" ]; then
  heap_source="PHOSPHENE_NODE_HEAP_MB"
elif [ -n "${limit_mb:-}" ] && [ "$limit_mb" -ge 256 ]; then
  heap_mb=$((limit_mb / 2))
  heap_source="cgroup_limit"
else
  heap_mb=256
  heap_source="conservative_default"
fi
[ "$heap_mb" -lt 128 ] && heap_mb=128
[ "$heap_mb" -gt 512 ] && heap_mb=512
semi_mb=$((heap_mb / 32))
[ "$semi_mb" -lt 4 ] && semi_mb=4
[ "$semi_mb" -gt 16 ] && semi_mb=16

echo "Phosphene memory profile: source=${heap_source} cgroup_limit_mb=${limit_mb:-unknown} node_heap_cap_mb=${heap_mb} semi_space_mb=${semi_mb}"

if [ "${1:-}" = "node" ]; then
  shift
  set -- node "--max-old-space-size=${heap_mb}" "--max-semi-space-size=${semi_mb}" "$@"
fi

if [ "$(id -u)" = "0" ]; then
  if ! chown node:node "$data_dir" 2>/dev/null; then
    echo "Warning: could not change ownership of $data_dir; checking existing volume permissions." >&2
  fi
  if ! gosu node test -w "$data_dir"; then
    echo "Phosphene cannot write to $data_dir as the node user. Check the persistent volume permissions." >&2
    exit 1
  fi
  exec gosu node "$@"
fi

if [ ! -w "$data_dir" ]; then
  echo "Phosphene cannot write to $data_dir as uid $(id -u). Check the persistent volume permissions." >&2
  exit 1
fi

exec "$@"
