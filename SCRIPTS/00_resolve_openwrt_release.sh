#!/bin/bash

set -Eeuo pipefail

resolve_openwrt_release() {
  local openwrt_repo="https://github.com/openwrt/openwrt.git"
  local remote_tags release requested_release

  if [[ -n "${OPENWRT_RELEASE:-}" ]]; then
    requested_release="$OPENWRT_RELEASE"
    if [[ ! "$requested_release" =~ ^v25\.12\.[0-9]+$ ]]; then
      echo "invalid OPENWRT_RELEASE: $requested_release" >&2
      return 1
    fi
  fi

  remote_tags="$(git ls-remote --tags --refs "$openwrt_repo" 'refs/tags/v25.12.*')" || {
    echo "failed to list OpenWrt v25.12.x tags" >&2
    return 1
  }

  if [[ -n "${requested_release:-}" ]]; then
    if ! printf '%s\n' "$remote_tags" | awk '{print $2}' | grep -Fxq "refs/tags/$requested_release"; then
      echo "OpenWrt release tag not found: $requested_release" >&2
      return 1
    fi
    printf '%s\n' "$requested_release"
    return 0
  fi

  release="$(printf '%s\n' "$remote_tags" | awk '$2 ~ /^refs\/tags\/v25\.12\.[0-9]+$/ {sub("refs/tags/", "", $2); print $2}' | sort -V | tail -n 1)"
  if [[ -z "$release" ]]; then
    echo "no stable OpenWrt v25.12.x release tags found" >&2
    return 1
  fi
  printf '%s\n' "$release"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resolve_openwrt_release
fi
