ZIG_OUT := ../zig-out

hello: hello.c $(ZIG_OUT)/lib/libzicl.a
	gcc hello.c -I$(ZIG_OUT)/include -L$(ZIG_OUT)/lib -lzicl -lm -o hello

$(ZIG_OUT)/lib/libzicl.a:
	cd .. && zig build

run: hello
	./hello

clean:
	rm hello

.PHONY: run clean
