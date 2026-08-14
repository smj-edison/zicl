import gdb

CHUNK_SIZE = 64 * 1024 * 1024  # 64 MiB, chunked so one giant mapping can't stall the scan.
NEEDLE_SIZE = 8  # pointer width on x86-64/aarch64.


def iter_maps(pid, include_all):
    """Yield (start, end, perms, pathname) for each /proc/<pid>/maps line.

    Without include_all, keeps only anonymous-looking regions (no backing
    file, or one of the synthetic [heap]/[stack]/[stack:tid] names) since
    that's where malloc'd objects and thread stacks live. Always drops the
    unreadable/special vsyscall-family mappings.
    """
    with open(f"/proc/{pid}/maps") as f:
        for line in f:
            parts = line.split(None, 5)
            addr_range, perms = parts[0], parts[1]
            pathname = parts[5].strip() if len(parts) > 5 else ""
            start_str, end_str = addr_range.split("-")
            start, end = int(start_str, 16), int(end_str, 16)

            if pathname in ("[vsyscall]", "[vvar]", "[vdso]"):
                continue

            is_anon = pathname == "" or pathname.startswith("[")
            if not include_all and not is_anon:
                continue

            yield start, end, perms, pathname


def describe_address(addr):
    try:
        out = gdb.execute(f"info symbol 0x{addr:x}", to_string=True).strip()
    except gdb.error:
        return ""
    return "" if out.startswith("No symbol matches") else out


class ZiclScanHeapCmd(gdb.Command):
    """scan-heap-for <address> [--all] [--aligned]

    Scan the inferior's memory for every raw occurrence of a pointer-sized
    value, across all anonymous mappings (every malloc arena, not just
    `[heap]`, plus thread stacks) rather than a single contiguous region.

    Meant for the case where a single object's tracked history isn't enough:
    you have an address and want every current holder of it, found by
    reading process memory directly rather than by walking typed structures
    (so it works even when object-graph introspection isn't wired up, or
    when you don't want to touch the live-tracing machinery because it
    perturbs timing enough to hide the bug you're chasing).

    Run this once you've already stopped (crash, assert, breakpoint) -- a
    single scan at that point can't affect a race that has already happened,
    unlike leaving heavyweight tracing running for the whole reproduction.

    --all      also scan file-backed mappings (binary/library .data/.bss),
               not just anonymous ones.
    --aligned  only check 8-byte-aligned offsets (faster; real pointer-sized
               struct fields are essentially always aligned, so this is a
               reasonable default to reach for if a full byte scan is slow).
    """

    def __init__(self):
        super().__init__("scan-heap-for", gdb.COMMAND_DATA)

    def invoke(self, argument, from_tty):
        args = gdb.string_to_argv(argument)
        if not args:
            print("usage: scan-heap-for <address> [--all] [--aligned]")
            return

        target = int(gdb.parse_and_eval(args[0])) & ((1 << 64) - 1)
        include_all = "--all" in args[1:]
        aligned_only = "--aligned" in args[1:]
        needle = target.to_bytes(NEEDLE_SIZE, byteorder="little")

        inferior = gdb.selected_inferior()
        regions = [r for r in iter_maps(inferior.pid, include_all) if "r" in r[2]]

        print(f"Scanning {len(regions)} readable region(s) for 0x{target:x}...")
        total_hits = 0
        for start, end, perms, pathname in regions:
            offset = 0
            size = end - start
            # Chunk with NEEDLE_SIZE-1 bytes of overlap so a match straddling
            # a chunk boundary isn't missed.
            while offset < size:
                read_len = min(CHUNK_SIZE, size - offset)
                try:
                    mem = bytes(inferior.read_memory(start + offset, read_len))
                except gdb.error:
                    # Unreadable page (e.g. a stack guard page) inside an
                    # otherwise-readable mapping; skip past this chunk.
                    offset += read_len
                    continue

                pos = 0
                while True:
                    idx = mem.find(needle, pos)
                    if idx == -1:
                        break
                    addr = start + offset + idx
                    pos = idx + 1
                    if aligned_only and addr % NEEDLE_SIZE != 0:
                        continue
                    total_hits += 1
                    label = describe_address(addr)
                    align_note = "" if addr % NEEDLE_SIZE == 0 else "  (unaligned)"
                    print(f"  0x{addr:x}  in {pathname or '[anon]'} ({perms}){align_note}  {label}")

                reached_end = offset + read_len >= size
                if reached_end:
                    break
                offset += read_len - (NEEDLE_SIZE - 1)

        print(f"Done. {total_hits} hit(s).")

TAG_NAMES = [
    "none",
    "invalid",
    "marked",
    "index",
    "integer",
    "float",
    "bool",
    "string",
    "source",
    "list",
    "dict",
    "dict_sugar",
    "parsed_script_command",
    "reference",
    "cached_local_var",
    "cached_lexical_var",
    "upvar_link",
    "closure",
    "custom_type",
    "hash_reference",
    "regexp",
    "free_list",
]


def get_objects_ptr():
    val = gdb.parse_and_eval("(void*)obj_ptr_for_gdb")
    return int(val)

def get_tag_addr(object_idx):
    # This is the address for the byte containing the object's tag, so a watchpoint can be set.
    return get_objects_ptr() + object_idx * 16 + 7

def get_tag(object_idx):
    addr = get_tag_addr(object_idx)
    mem = gdb.selected_inferior().read_memory(addr, 1)
    byte = bytes(mem)[0]

    # .tag is packed, so it's the highest 5 bits.
    return byte >> 3

class TagPtrFn(gdb.Function):
    """
    $tag_ptr(idx) -> unsigned char*
    """

    def __init__(self):
        super().__init__("tag_ptr")

    def invoke(self, idx):
        addr = get_tag_addr(int(idx))
        char_ptr = gdb.lookup_type("unsigned char").pointer()
        return gdb.Value(int(addr)).cast(char_ptr)

class ZiclTagCmd(gdb.Command):
    """tag <idx>. Print the tag value."""

    def __init__(self):
        super().__init__("tag", gdb.COMMAND_DATA)

    def invoke(self, argument, _from_tty):
        args = gdb.string_to_argv(argument)
        assert len(args) == 1

        idx = int(gdb.parse_and_eval(args[0]))
        tag = get_tag(idx)
        addr = get_tag_addr(idx)

        tag_name = TAG_NAMES[tag] if tag < len(TAG_NAMES) else f"unknown({tag})"
        print(f"object[{idx}] tag = {tag} ({tag_name})  [tag byte @ {addr:#x}]")


class ZiclStrCmd(gdb.Command):
    """zicl-str <idx>. Print the object's current string representation, if any."""

    def __init__(self):
        super().__init__("zicl-str", gdb.COMMAND_DATA)

    def invoke(self, argument, _from_tty):
        args = gdb.string_to_argv(argument)
        assert len(args) == 1

        idx = int(gdb.parse_and_eval(args[0]))

        try:
            val = gdb.parse_and_eval(f"objStringPtrForGdb({idx})")
        except gdb.error as e:
            print(f"Failed to resolve object[{idx}] string: {e}")
            return

        ptr = int(val)
        if ptr == 0:
            print(f"object[{idx}] has no string representation")
            return

        MAX_LEN = 4096
        try:
            mem = gdb.selected_inferior().read_memory(ptr, MAX_LEN)
        except gdb.error as e:
            print(f"object[{idx}] string pointer {ptr:#x} is unreadable: {e}")
            return

        raw = bytes(mem)
        null_pos = raw.find(b'\x00')
        if null_pos == -1:
            raw = raw[:MAX_LEN]
            truncated = True
        else:
            raw = raw[:null_pos]
            truncated = False

        try:
            string = raw.decode('utf-8')
        except UnicodeDecodeError:
            string = repr(raw)

        suffix = " ... (truncated)" if truncated else ""
        print(f"object[{idx}] string = {string!r}{suffix}")


TagPtrFn()
ZiclTagCmd()
ZiclStrCmd()
ZiclScanHeapCmd()
