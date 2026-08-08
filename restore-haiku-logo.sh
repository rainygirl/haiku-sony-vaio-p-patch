#!/bin/sh
# Puts the Haiku logo back on an installed system. Run this ON HAIKU.
#
# An image built with the default --distro-compatibility ships no
# data/artwork/, because that level drops every trademarked file. The stock
# desktop background setting still points into that directory, so the desktop
# comes up blank and Backgrounds preferences shows a path that does not
# resolve. Rebuilding the ISO with DISTRO_COMPATIBILITY=compatible fixes it
# for the next install; this fixes the one already on disk.
#
# Two things get repaired:
#   - the artwork itself, dropped into non-packaged so packagefs merges it
#   - the Desktop's be:bgndimginfo attribute, which on a stock install also
#     carries a second entry pinned to workspace 1 with an empty path. That
#     entry reads as "no background here" and wins over the real one, so the
#     logo would stay invisible on workspace 1 even once the file exists.
#
# Usage:
#   ./restore-haiku-logo.sh [path to "HAIKU logo - white on blue - big.png"]
#
# With no argument it downloads the logo from haiku.git.

set -e

ARTWORK_DIR=/boot/system/non-packaged/data/artwork
LOGO_NAME="HAIKU logo - white on blue - big.png"
LOGO_URL="https://raw.githubusercontent.com/haiku/haiku/master/data/artwork/HAIKU%20logo%20-%20white%20on%20blue%20-%20big.png"

# Where the stock install puts the logo, horizontally in from the left and
# down towards the bottom. It fits any screen at least 863x698.
OFFSET_X=258
OFFSET_Y=519

mkdir -p "$ARTWORK_DIR"

if [ -n "$1" ]; then
	cp "$1" "$ARTWORK_DIR/$LOGO_NAME"
elif [ ! -f "$ARTWORK_DIR/$LOGO_NAME" ]; then
	echo "Downloading the logo from haiku.git..."
	wget -q -O "$ARTWORK_DIR/$LOGO_NAME" "$LOGO_URL" \
		|| { echo "Download failed. Pass a local copy as the first argument."; exit 1; }
fi

[ -s "$ARTWORK_DIR/$LOGO_NAME" ] || { echo "$ARTWORK_DIR/$LOGO_NAME is empty"; exit 1; }

TMP=/tmp/restore-haiku-logo.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/setbg.cpp" <<'CPP'
// Rewrites the Desktop's background setting: one entry, every workspace.
//
// The setting is a flattened BMessage of parallel arrays, normally edited
// through Backgrounds preferences. Writing a single entry is what clears any
// per-workspace override sitting on top of it.
#include <Entry.h>
#include <Message.h>
#include <Node.h>
#include <Point.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// From headers/os/be_apps/Tracker/Background.h, spelled out so this builds
// without the Tracker headers on the include path.
static const char* kInfo = "be:bgndimginfo";
static const char* kPath = "be:bgndimginfopath";
static const char* kMode = "be:bgndimginfomode";
static const char* kOffset = "be:bgndimginfooffset";
static const char* kTextOutline = "be:bgndimginfoerasetext";
static const char* kWorkspaces = "be:bgndimginfoworkspaces";

int
main(int argc, char** argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s <image path> <x> <y>\n", argv[0]);
		return 1;
	}

	BEntry image(argv[1]);
	if (!image.Exists()) {
		fprintf(stderr, "%s: no such file\n", argv[1]);
		return 1;
	}

	BNode desktop("/boot/home/Desktop");
	if (desktop.InitCheck() != B_OK) {
		fprintf(stderr, "cannot open the Desktop\n");
		return 1;
	}

	BMessage settings;
	settings.AddString(kPath, argv[1]);
	settings.AddInt32(kWorkspaces, (int32)0xffffffff);
	settings.AddInt32(kMode, 0);				// placed at the offset below
	settings.AddPoint(kOffset, BPoint(atof(argv[2]), atof(argv[3])));
	settings.AddBool(kTextOutline, true);

	ssize_t size = settings.FlattenedSize();
	char* buffer = (char*)malloc(size);
	if (buffer == NULL || settings.Flatten(buffer, size) != B_OK) {
		fprintf(stderr, "cannot flatten the settings\n");
		return 1;
	}

	// Removed first, because a shorter message written over a longer one
	// would leave the tail of the old flattened data in place.
	desktop.RemoveAttr(kInfo);
	ssize_t written = desktop.WriteAttr(kInfo, B_MESSAGE_TYPE, 0, buffer, size);
	free(buffer);

	if (written != size) {
		fprintf(stderr, "cannot write the attribute\n");
		return 1;
	}

	printf("Desktop background set to %s\n", argv[1]);
	return 0;
}
CPP

g++ -o "$TMP/setbg" "$TMP/setbg.cpp" -lbe
"$TMP/setbg" "$ARTWORK_DIR/$LOGO_NAME" "$OFFSET_X" "$OFFSET_Y"

# Tracker draws the desktop and only reads the attribute at startup.
hey Tracker quit > /dev/null 2>&1 || true
sleep 3
/boot/system/Tracker > /dev/null 2>&1 &
sync

echo "Done. The logo is on the desktop; move any window covering it to see it."
