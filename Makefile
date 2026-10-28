# Thin wrapper: all logic lives in build.sh, this only forwards.
.PHONY: all clean

all:
	./build.sh

clean:
	./build.sh clean
