#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/render-homebrew-formula.sh --version <version> --sha256 <sha256> [--output <path>]

Renders a release-ready Homebrew formula for the binary pomme tarball asset.
USAGE
}

repo="${GITHUB_REPOSITORY:-weswhet/pomme}"
version=""
sha256=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      version="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      sha256="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      output="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$version" || -z "$sha256" ]]; then
  usage >&2
  exit 64
fi

case "$version" in
  *[!A-Za-z0-9._-]*|"")
    echo "Invalid release version: $version" >&2
    exit 64
    ;;
esac

if [[ ! "$sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Invalid sha256: $sha256" >&2
  exit 64
fi

render() {
  cat <<RUBY
class Pomme < Formula
  desc "Headless macOS VM CLI built with Virtualization.framework"
  homepage "https://github.com/$repo"
  url "https://github.com/$repo/releases/download/v$version/pomme-$version-arm64.tar.gz"
  sha256 "$sha256"
  license "NOASSERTION"

  depends_on arch: :arm64

  def install
    bin.install "pomme"
  end

  test do
    assert_match "pomme CLI", shell_output("#{bin}/pomme --help")
  end
end
RUBY
}

if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  render > "$output"
else
  render
fi
