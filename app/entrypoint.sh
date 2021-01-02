#!/usr/bin/env bash
set -euo pipefail


case ${1:-hang} in
  hang)
    while true; do
      echo "$(date) hang"
      sleep 1
    done
  ;;
  *)
    echo exec k8s-node-descale $@
    exec k8s-node-descale $@
  ;;
esac
