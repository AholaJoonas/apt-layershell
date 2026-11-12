# apt-layer
#   make                    build the preload library (lib/libqs-webengine-shim.so)
#   make install            install to PREFIX (default ~/.local) - optional, the tree also runs in place
#   make uninstall          remove exactly what install put there
#   make dist               portable tarball build/apt-layer-VERSION.tar.gz (prebuilt library included)
PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/apt-layer
APPSDIR ?= $(PREFIX)/share/applications
CXX     ?= c++

VERSION := $(shell cat VERSION 2>/dev/null || echo 0)
DIST    := apt-layer-$(VERSION)
SHIM    := lib/libqs-webengine-shim.so
BINS    := apt-layer apt-layerctl apt-layer-launch
D       := $(DESTDIR)$(DATADIR)

# Every installed file, relative to $(DATADIR) (uninstall removes exactly these).
VENDOR  := $(shell find lib/vendor -type f -not -path '*/__pycache__/*' 2>/dev/null | sort)
FILES   := $(addprefix bin/,$(BINS)) lib/common.sh lib/checks.py lib/x-watch.py lib/niri-query.py lib/ctl.py $(SHIM) \
	lib/xdg-open-shim/xdg-open quickshell/shell.qml quickshell/adapter/adapter.js \
	quickshell/adapter/adapter-css.js quickshell-ui/shell.qml share/config.example \
	share/apt-layer.desktop.in share/apt-layer-launch.desktop.in share/apt-layer.svg share/apt-layer-ui.svg \
	dev/test-page/index.html VERSION $(VENDOR)
EXEC    := $(addprefix bin/,$(BINS)) lib/x-watch.py lib/niri-query.py lib/ctl.py lib/xdg-open-shim/xdg-open $(SHIM)
DESKTOP := apt-layer apt-layer-launch

all: shim
shim: $(SHIM)

# Portable build: no Qt version tag (any Qt 6 at runtime), no C++ exceptions/RTTI, plain C strings.
$(SHIM): lib/qs-webengine-shim.cpp
	$(CXX) -std=c++17 -O2 -fPIC -shared -Wall -Wextra -fno-exceptions -fno-rtti -DQT_NO_VERSION_TAGGING \
		$$(pkg-config --cflags Qt6Core) -o $@ $< $$(pkg-config --libs Qt6Core) -ldl -Wl,--as-needed

# The installed tree mirrors the repo layout ($(DATADIR)/{bin,lib,quickshell,share,dev}),
# so the scripts find everything relative to themselves; $(BINDIR) gets symlinks.
install: $(SHIM)
	@test -n "$(DATADIR)" -a "$(DATADIR)" != "/" || { echo "bad DATADIR"; exit 1; }
	for f in $(FILES); do install -D -m 644 "$$f" "$(D)/$$f"; done
	for f in $(EXEC); do chmod 755 "$(D)/$$f"; done
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(APPSDIR)"
	for b in $(BINS); do ln -sfn "$(DATADIR)/bin/$$b" "$(DESTDIR)$(BINDIR)/$$b"; done
	for d in $(DESKTOP); do sed -e 's|@BINDIR@|$(BINDIR)|g' -e 's|@SHAREDIR@|$(DATADIR)/share|g' \
		share/$$d.desktop.in > "$(DESTDIR)$(APPSDIR)/$$d.desktop"; done
	@echo "Installed to $(DATADIR). Menu: \"APT Layer UI\" (control window) and \"APT Layer\" (starts APT + overlay)."
	@echo "Check the setup with: $(BINDIR)/apt-layer doctor"

uninstall:
	for f in $(FILES); do rm -f "$(D)/$$f"; done
	-find "$(D)" -name '*.pyc' -path '*/__pycache__/*' -delete 2>/dev/null
	-find "$(D)" -depth -type d -empty -delete 2>/dev/null
	for b in $(BINS); do rm -f "$(DESTDIR)$(BINDIR)/$$b"; done
	for d in $(DESKTOP); do rm -f "$(DESTDIR)$(APPSDIR)/$$d.desktop"; done

# Release tarball: tracked + new (not ignored) files and the prebuilt library.
dist: $(SHIM)
	@mkdir -p build
	{ git ls-files -co --exclude-standard; echo $(SHIM); } | sort -u | \
		grep -vE '^build/' | \
		tar -czf build/$(DIST).tar.gz --transform 's,^,$(DIST)/,' -T -
	@echo "build/$(DIST).tar.gz"

clean:
	rm -f $(SHIM) build/$(DIST).tar.gz

.PHONY: all shim install uninstall dist clean
