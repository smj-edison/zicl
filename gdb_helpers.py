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
    "list",
    "dict",
    "reference",
    "cached_local_var",
    "cached_lexical_var",
    "upvar_link",
    "closure",
    "custom_type",
]


def get_objects_ptr():
    val = gdb.parse_and_eval("(void*)objects_ptr_for_gdb")
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


TagPtrFn()
ZiclTagCmd()
