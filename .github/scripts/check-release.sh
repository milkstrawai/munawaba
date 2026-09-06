#!/bin/sh
set -eu

case "$GITHUB_REF" in
  refs/tags/*) current_tag=${GITHUB_REF#refs/tags/} ;;
  *) echo "Error: releases require a Git tag." >&2; exit 1 ;;
esac

current_tag=${current_tag#v}
file_tag=$(ruby -r ./lib/munawaba/version -e 'puts Munawaba::VERSION')

if [ "$current_tag" != "$file_tag" ]; then
  echo "Error: release tag $current_tag does not match gem version $file_tag." >&2
  exit 1
fi

echo 'OK'
