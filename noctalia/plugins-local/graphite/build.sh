#!/bin/sh
# Build bin/graphite and bin/graphite-events from src/ when missing or older than the
# source. The service runs this at start, so a fresh clone builds itself. Needs Go.
cd "$(dirname "$0")" || exit 1
if [ -x bin/graphite ] && [ -x bin/graphite-events ] && [ -z "$(find src -type f -newer bin/graphite -o -type f -newer bin/graphite-events | head -1)" ]; then
	exit 0
fi
mkdir -p bin
cd src || exit 1
go build -trimpath -ldflags "-s -w" -o ../bin/graphite . &&
	exec go build -trimpath -ldflags "-s -w" -o ../bin/graphite-events ./events
