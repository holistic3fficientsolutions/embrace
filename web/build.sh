#!/bin/bash
# Embrace's web build: crymble-ui's bin/crymble-web, behind Embrace's release gate. Run from the repository root.
#
#   web/build.sh          a build to publish: bin/web/embrace/
#   web/build.sh --local  a build to try out - the page says "local build - not for publication"
#
# The gate is the AGPL's source offer: the page links the public release tags this build is made of, so a build
# to publish is only made from exactly those - HEAD is the release tag v<version> and that tag is public, crymble-ui
# (lib/crymble-ui) sits on its own public release tag, and neither tree has changes.
# Both are release builds (crymble-web --release: the release flag, e.g. no CPU monitor), so a trial page is the
# page that would be published. Needs the toolchain once: lib/crymble-ui/bin/crymble-web setup.
set -euo pipefail

die() { echo "web/build.sh: $*" >&2; exit 1; }
[ -f shard.yml ] && [ -d web ] || die "run me from Embrace's repository root"
CUI=lib/crymble-ui
[ -x "$CUI/bin/crymble-web" ] || die "no $CUI/bin/crymble-web - 'shards install' first"

version=$(awk '$1 == "version:" {print $2; exit}' shard.yml)
repository=$(awk '$1 == "repository:" {print $2; exit}' shard.yml)
local_build=0
flags=(--release)
case "${1:-}" in
  --local) local_build=1; flags+=(--local) ;;
  "") ;;
  *) die "unknown argument $1 (--local, or nothing)" ;;
esac

# released_tree DIR VERSION URL: DIR's HEAD is the tag vVERSION, the tree has no changes, and the tag is public
released_tree() {
  local dir=$1 tag=v$2 url=$3
  # its own repository - a shards checkout has none, and git would answer for the enclosing one
  [ "$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null)" = "$(cd "$dir" && pwd -P)" ] ||
    die "$dir is not a git checkout of its own (a build to publish needs the released repositories)"
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir has changes or untracked files"
  [ "$(git -C "$dir" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)" = "$(git -C "$dir" rev-parse HEAD)" ] ||
    die "$dir: HEAD is not the release tag $tag"
  git ls-remote --exit-code --tags "$url" "refs/tags/$tag" > /dev/null ||
    die "$dir: the tag $tag is not on $url - publish the release first"
}
if [ "$local_build" = 0 ]; then
  released_tree . "$version" "$repository"
  cui_version=$(awk '$1 == "version:" {print $2; exit}' "$CUI/shard.yml")
  released_tree "$CUI" "$cui_version" "$(awk '$1 == "repository:" {print $2; exit}' "$CUI/shard.yml")"
fi

"$CUI/bin/crymble-web" build embrace ${flags[@]+"${flags[@]}"}

# Embrace's own line: what it is, and where its source is
notices=bin/web/embrace/NOTICES
{
  cat "$notices"
  echo
  echo "H3O Embrace® $version - GNU Affero General Public License v3.0 only."
  if [ "$local_build" = 1 ]; then
    echo "  A local build of $(git rev-parse --short HEAD)$([ -n "$(git status --porcelain)" ] && echo " with changes") - not a release, not for publication."
  else
    echo "  Its complete source: $repository/tree/v$version"
  fi
} > "$notices.new"
mv "$notices.new" "$notices"
echo "web/build.sh: bin/web/embrace/ - try it: $CUI/bin/crymble-web serve embrace"
