# Chili, an unofficial SPICE client for macOS — see README.md
#   make            build everything and produce dist/Chili-<version>-<arch>.dmg
#   make stack      build only the libraries + remote-viewer (slow, cached)
#   make app        assemble dist/<arch>/Chili.app
#   make run        assemble and open the app
#   make test       smoke-test the assembled app
#   make clean      remove the app/DMG (keeps the compiled stack)
#   make distclean  remove everything, including downloads

ARCH ?= $(shell uname -m)
export ARCH

.PHONY: all stack app dmg run test icon clean distclean

all: dmg

stack:
	scripts/build-stack.sh

app: stack
	scripts/bundle-app.sh

test: app
	scripts/smoke-test.sh

dmg: test
	scripts/make-dmg.sh

run: app
	open "dist/$(ARCH)/Chili.app"

icon:
	scripts/make-icon.sh

clean:
	rm -rf dist

distclean: clean
	rm -rf build
