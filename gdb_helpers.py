import gdb

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
