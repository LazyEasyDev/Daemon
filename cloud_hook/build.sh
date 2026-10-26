#!/bin/sh

set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
mkdir -p "$script_dir/build"
cd "$script_dir"

for os in linux windows; do
	extension=""
	if [ "$os" = windows ]; then
		extension=".exe"
	fi
	for arch in amd64 arm64; do
		for app in aws_hook azure_hook; do
			printf 'Compiling %s for %s/%s\n' "$app" "$os" "$arch"
			CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" \
				go build -trimpath -o "$script_dir/build/$app-$os-$arch$extension" "./$app"
		done
	done
done
