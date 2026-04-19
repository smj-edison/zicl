ZIG_OUT := ../zig-out

run: hello
	./hello

hello: hello.c $(ZIG_OUT)/lib/libzicl.a
	cc hello.c -I$(ZIG_OUT)/include -L$(ZIG_OUT)/lib -lzicl -lm -o hello

$(ZIG_OUT)/lib/libzicl.a: ../include/libzicl.h ../src/libzicl.zig
	cd .. && zig build

clean:
	rm hello

.PHONY: run clean
