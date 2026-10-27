"""生成 Tests/RpycFixtures.generated.swift 里的 .rpyc 固定样本。

不依赖 Ren'Py 本体：把 renpy.ast / renpy.astsupport / renpy.parameter 伪装成模块
注册进 sys.modules，让 pickle 按真实类名和真实字段序列化，样本因此和官方
.rpyc 里出现的对象结构一致。

用法：python Tools/make_rpyc_fixture.py
"""

import base64
import pickle
import struct
import sys
import types
import zlib

# Ren'Py 8.x 写出的编译脚本是 pickle 协议 2
PROTOCOL = 2


# ---------------------------------------------------------------------------
# 伪装 Ren'Py 模块
# ---------------------------------------------------------------------------

def module(name):
    mod = types.ModuleType(name)
    mod.__path__ = []
    sys.modules[name] = mod
    return mod


renpy_pkg = module("renpy")
ast_mod = module("renpy.ast")
astsupport_mod = module("renpy.astsupport")
parameter_mod = module("renpy.parameter")
store_pkg = module("store")
layeredimage_mod = module("store.layeredimage")


def register(mod, cls, name=None):
    name = name or cls.__name__
    cls.__module__ = mod.__name__
    cls.__name__ = name
    cls.__qualname__ = name
    setattr(mod, name, cls)
    return cls


class Object:
    """对应 renpy.object.Object：状态是 __dict__ 加 __version__。"""

    __version__ = 5

    def __init__(self, **fields):
        self.__dict__.update(fields)

    def __getstate__(self):
        state = dict(self.__dict__)
        state["__version__"] = self.__version__
        return state


class PyExpr(str):
    """对应 renpy.astsupport.PyExpr：str 子类，用 __reduce__ 保存源码。"""

    def __new__(cls, text, filename="script.rpy", line=1, py=None, hashcode=0, col=0):
        self = str.__new__(cls, text)
        self.text = text
        self.filename = filename
        self.line = line
        self.hashcode = hashcode
        self.col = col
        return self

    def __reduce__(self):
        return (PyExpr, (self.text, self.filename, self.line, None, self.hashcode, self.col))


class PyCode:
    """对应 renpy.ast.PyCode：状态是 (版本, 源码, 位置, 模式, py, hash, 列)。"""

    def __init__(self, source, filename="script.rpy", line=1):
        self.source = source
        self.filename = filename
        self.line = line

    def __getstate__(self):
        return (1, self.source, (self.filename, self.line), "exec", None, 0, 0)

    def __setstate__(self, state):
        self.state = state


class Parameter:
    __slots__ = ("name", "kind", "default")

    POSITIONAL_OR_KEYWORD = 1
    VAR_POSITIONAL = 2
    VAR_KEYWORD = 4

    def __init__(self, name, kind=POSITIONAL_OR_KEYWORD, default=None):
        self.name = name
        self.kind = kind
        self.default = default

    def __getstate__(self):
        return (None, {slot: getattr(self, slot) for slot in self.__slots__})


class Signature:
    """Parameters of a label; 新版叫 ParameterInfo，是同一个类的别名。"""

    __slots__ = ("parameters",)

    def __init__(self, parameters):
        self.parameters = {param.name: param for param in parameters}

    def __getstate__(self):
        return (None, {"parameters": self.parameters})


class ArgumentInfo(Object):
    def __init__(self, arguments):
        super().__init__(arguments=arguments)


register(astsupport_mod, PyExpr)
register(ast_mod, PyCode)
register(parameter_mod, Parameter)
register(parameter_mod, Signature)
register(parameter_mod, Signature, "ParameterInfo")
register(parameter_mod, ArgumentInfo)


class Label(Object): pass
class Say(Object): pass
class TranslateSay(Say): pass
class Menu(Object): pass
class Jump(Object): pass
class Call(Object): pass
class Return(Object): pass
class If(Object): pass
class While(Object): pass
class Scene(Object): pass
class Show(Object): pass
class Hide(Object): pass
class Image(Object): pass
class Define(Object): pass
class Default(Object): pass
class Init(Object): pass
class Python(Object): pass
class UserStatement(Object): pass
class Translate(Object): pass
class EndTranslate(Object): pass
class With(Object): pass
class Screen(Object): pass


for cls in (Label, Say, TranslateSay, Menu, Jump, Call, Return, If, While,
            Scene, Show, Hide, Image, Define, Default, Init, Python,
            UserStatement, Translate, EndTranslate, With, Screen):
    register(ast_mod, cls)


# layeredimage 的自定义语句把解析结果（Raw* 对象）直接放进 UserStatement.parsed，
# 编译脚本里因此会出现 store.layeredimage 的类
class RawLayeredImage(Object): pass
class RawAlways(Object): pass
class RawAttributeGroup(Object): pass
class RawAttribute(Object): pass


for cls in (RawLayeredImage, RawAlways, RawAttributeGroup, RawAttribute):
    register(layeredimage_mod, cls)


# ---------------------------------------------------------------------------
# 语法树
# ---------------------------------------------------------------------------

def say(who, what, attributes=()):
    return Say(who=who, what=what, with_=None, interact=True,
               attributes=attributes, temporary_attributes=(),
               arguments=None)


def start_block():
    return [
        Scene(imspec=(("bg", "room"), [], "master"), layer="master"),
        Show(imspec=(("e", "happy"), None, None, [], "master", None)),
        # 真实的 8.x 里台词的 who/what 是 PyExpr（str 子类），用 __reduce__ 保存
        say(PyExpr("e"), PyExpr("你好，今天也要加油。")),
        With(expr=PyExpr("Fade(1.0, 0.2, 1.0)"), paired=None),
        Python(code=PyCode("points = points + 1"), hide=False, store="store"),
        If(entries=[
            (PyExpr("points >= 2"), [say("e", "你已经很努力了。")]),
            ("True", [say("e", "再试一次。")]),
        ]),
        Menu(items=[
            ("要不要去厨房？", "True", None),
            (PyExpr("去厨房"), "True", [
                UserStatement(line='play music "audio/theme.ogg" loop',
                              block=None, parsed=None),
                Python(code=PyCode("visited = True"), hide=False, store="store"),
                say("e", "厨房里有蛋糕。"),
            ]),
            ("留下来", "True", [say("e", "那我们就待在这儿。")]),
            ("偷偷吃蛋糕", PyExpr("points > 5"), [
                Python(code=PyCode("cake = cake + 1"), hide=False, store="store"),
            ]),
        ], **{"set": None}, with_=None, has_caption=True,
            arguments=None, item_arguments=None),
        If(entries=[
            (PyExpr("visited"), [say("e", "你吃了蛋糕，分数是 {points}。")]),
        ]),
        Call(label="secret", expression=False,
             arguments=ArgumentInfo([(None, PyExpr("'远处传来'"))]),
             global_label=""),
        say(None, "（远处传来钟声）"),
        Return(expression=None),
    ]


def base_tree():
    return [
        Define(store="store", varname="e", index=None, operator="=",
               code=PyCode('Character("艾莉")')),
        Define(store="store", varname="points", index=None, operator="=",
               code=PyCode("0")),
        Default(store="store", varname="visited", code=PyCode("False")),
        Default(store="store", varname="cake", code=PyCode("0")),
        Init(block=[Image(imgname=("bg", "room"), code=PyCode('"bg/room.png"'), atl=None)],
             priority=500),
        Label(_name="start", block=start_block(),
              parameters=None, hide=False),
        Label(_name="secret", block=[
            say(None, "（{who}的钟声）"),
            Return(expression=None),
        ], parameters=Signature([Parameter("who")]), hide=False),
    ]


def translated_say(who, what, identifier):
    return TranslateSay(who=who, what=what, with_=None, interact=True,
                        attributes=(), temporary_attributes=(), arguments=None,
                        language=None, identifier=identifier, alternate=None)


def slot_two_tree():
    """模拟静态变换后的语法树：台词被 TranslateSay 包住，整体多一层 Translate。"""
    block = []
    for index, node in enumerate(start_block()):
        if isinstance(node, Say):
            # 第一句和槽 1 不同，测试要能判断出读的到底是哪个槽
            text = "槽二的台词" if index == 2 else node.what
            block.append(translated_say(node.who, text, "t%d" % index))
        else:
            block.append(node)

    return [
        Define(store="store", varname="e", index=None, operator="=",
               code=PyCode('Character("艾莉")')),
        Define(store="store", varname="points", index=None, operator="=",
               code=PyCode("0")),
        Default(store="store", varname="visited", code=PyCode("False")),
        Default(store="store", varname="cake", code=PyCode("0")),
        Init(block=[Image(imgname=("bg", "room"), code=PyCode('"bg/room.png"'), atl=None)],
             priority=500),
        Label(_name="start", block=[
            Translate(identifier="start_default", language=None, block=block,
                      alternate=None),
            EndTranslate(),
            # 非空 language 的翻译块在默认语言下必须被跳过
            Translate(identifier="start_japanese", language="japanese",
                      block=[say("e", "日本語のセリフ")], alternate=None),
        ], parameters=None, hide=False),
        Label(_name="secret", block=[
            say(None, "（{who}的钟声）"),
            Return(expression=None),
        ], parameters=Signature([Parameter("who")]), hide=False),
    ]


def dynamic_tree():
    """`start` 用 jump expression 选章节，和真实发行包的写法一致。"""
    return [
        Define(store="store", varname="next_chapter", index=None, operator="=",
               code=PyCode('"chapter_b"')),
        Label(name="start", block=[
            say(None, "准备出发。"),
            # get_start_label() 是游戏自己的函数，播放器求不出来，只能走兜底
            Jump(target=PyExpr("game.get_start_label()"), expression=True, global_label="start"),
        ], parameters=None, hide=False),
        Label(name="chapter_a", block=[
            say(None, "第一章"),
            Jump(target=PyExpr("next_chapter"), expression=True, global_label="chapter_a"),
        ], parameters=None, hide=False),
        Label(name="chapter_b", block=[
            say(None, "第二章"),
            Return(expression=None),
        ], parameters=None, hide=False),
    ]


def layered_tree():
    """`layeredimage e:`：always 部件 + face 属性组，后面用 `at left` 摆位置。"""
    face = RawAttributeGroup(
        image_name="e",
        group="face",
        properties={},
        children=[
            RawAttribute(name="smiling", image="e face smiling",
                         properties={"default": True}),
            RawAttribute(name="angry", image="e face angry", properties={}),
        ],
    )
    image = RawLayeredImage(
        name="e",
        children=[
            # FG_CEN 是游戏自己的常量，玩家端求不出来，只能退回字符串字面量
            RawAlways(image=PyExpr('"e body base" + FG_CEN'), properties={}),
            face,
        ],
        properties={},
    )
    return [
        Define(store="store", varname="e", index=None, operator="=",
               code=PyCode('Character("艾莉")')),
        Init(block=[Image(imgname=("bg", "room"), code=PyCode('"bg/room.png"'), atl=None)],
             priority=500),
        UserStatement(line="layeredimage e:", block=None,
                      parsed=(("layeredimage",), image)),
        Label(_name="start", block=[
            Scene(imspec=(("bg", "room"), [], "master"), layer="master"),
            Show(imspec=(("e",), None, None, ["left"], "master", None)),
            say("e", "第一句"),
            # 只换表情、不写 at：位置必须沿用上一次的 left
            Show(imspec=(("e", "angry"), None, None, [], "master", None)),
            say("e", "第二句"),
            Return(expression=None),
        ], parameters=None, hide=False),
    ]


# ---------------------------------------------------------------------------
# 容器
# ---------------------------------------------------------------------------

DATA = {"version": 1, "translation": None}


def pickle_tree(tree):
    return pickle.dumps((DATA, tree), protocol=PROTOCOL)


def packed(tree):
    return zlib.compress(pickle_tree(tree), 3)


def rpc4(payloads):
    header = b"RENPY RPC4"
    slots = sorted(payloads)
    table_length = 12 * (len(slots) + 1)
    base = len(header) + table_length

    table = b""
    body = b""
    for slot in slots:
        data = payloads[slot]
        # renpy/script.py 用 struct.pack("III") 写槽表，实际发行包都是小端
        table += struct.pack("<III", slot, base + len(body), len(data))
        body += data
    table += struct.pack("<III", 0, 0, 0)
    return header + table + body


def check_round_trip(blob):
    """按 Swift 端的读取方式再走一遍，确认容器和压缩都没问题。"""
    assert blob.startswith(b"RENPY RPC")
    offset = len(b"RENPY RPC4")
    slots = {}
    while True:
        slot, start, length = struct.unpack("<III", blob[offset:offset + 12])
        offset += 12
        if slot == 0:
            break
        slots[slot] = (start, length)
    for slot in sorted(slots):
        start, length = slots[slot]
        payload = zlib.decompress(blob[start:start + length])
        data, tree = pickle.loads(payload)
        assert data == DATA and isinstance(tree, list) and tree


# ---------------------------------------------------------------------------
# 归档样本
# ---------------------------------------------------------------------------

ARCHIVE_KEY = 0x42424242


def build_archive(members):
    """复刻发行包的归档：魔数被改掉、索引是 7 元组、偏移和长度异或了密钥。"""
    blobs = {name: data for name, data in members.items()}
    header_length = 8 + 16 + 1 + 8 + 1
    body = b""
    index = {}
    offsets = {}
    for name, data in blobs.items():
        offsets[name] = header_length + len(body)
        body += data

    # 索引本身也要放进数据区，先占位算长度
    placeholder = {}
    for name, data in blobs.items():
        offset = offsets[name]
        length = len(data)
        placeholder[name] = [(b"", offset ^ ARCHIVE_KEY, length ^ ARCHIVE_KEY,
                              length ^ ARCHIVE_KEY, b"", b"", b"")]
    index_offset = header_length + len(body)
    index_blob = zlib.compress(pickle.dumps(placeholder, protocol=2), 9)

    header = b"xehsoidx" + ("%016x" % index_offset).encode("ascii") + b" " \
        + ("%08x" % ARCHIVE_KEY).encode("ascii") + b"\n"
    assert len(header) == header_length
    return header + body + index_blob


def check_archive(blob, members):
    offset = int(blob[8:24], 16)
    key = int(blob[25:33], 16)
    index = pickle.loads(zlib.decompress(blob[offset:]))
    for name, data in members.items():
        entry = index[name][0]
        assert entry[0] == b""
        start, length = entry[1] ^ key, entry[2] ^ key
        assert blob[start:start + length] == data, name


def main():
    both = rpc4({1: packed(base_tree()), 2: packed(slot_two_tree())})
    slot_two = rpc4({2: packed(slot_two_tree())})
    dynamic = rpc4({1: packed(dynamic_tree())})
    layered = rpc4({1: packed(layered_tree())})
    legacy = packed(base_tree())

    for blob in (both, slot_two, dynamic, layered):
        check_round_trip(blob)
    data, tree = pickle.loads(zlib.decompress(legacy))
    assert data == DATA and tree

    entries = [
        ("modern", "双槽容器：槽 1 是原始语法树，槽 2 带 Translate 包装", both),
        ("slotTwoOnly", "只有槽 2，台词都在 TranslateSay 里，另有必须跳过的日文翻译块", slot_two),
        ("dynamicJump", "start 用 jump expression 选章节", dynamic),
        ("layered", "分层立绘：always 部件加 face 属性组，show 带 at 定位", layered),
        ("legacy", "旧格式：整份文件就是一个 zlib 压缩的 pickle", legacy),
    ]

    lines = [
        "// 由 Tools/make_rpyc_fixture.py 生成，请勿手工修改。",
        "",
        "/// 测试用的 .rpyc 固定样本（base64）。",
        "enum RpycFixtures {",
    ]
    for name, comment, blob in entries:
        encoded = base64.b64encode(blob).decode("ascii")
        lines.append("\t/// %s" % comment)
        lines.append('\tstatic let %s = "%s"' % (name, encoded))
        lines.append("")
    lines.append("}")

    with open("Tests/RpycFixtures.generated.swift", "w", encoding="utf-8", newline="\n") as file:
        file.write("\n".join(lines) + "\n")

    members = {
        "scripts/scenario/start.rpyc": dynamic,
        "images/bg room.png": b"not-a-real-png",
    }
    archive = build_archive(members)
    check_archive(archive, members)
    encoded_archive = base64.b64encode(archive).decode("ascii")
    with open("Tests/ArchiveFixtures.generated.swift", "w", encoding="utf-8", newline="\n") as file:
        file.write("// 由 Tools/make_rpyc_fixture.py 生成，请勿手工修改。\n\n")
        file.write("/// 测试用的 .rpa 固定样本（base64）。\n")
        file.write("enum ArchiveFixtures {\n")
        file.write("\t/// 魔数被改成 xehsoidx、索引是 7 元组、偏移和长度异或了密钥\n")
        file.write('\tstatic let obfuscated = "%s"\n' % encoded_archive)
        file.write("}\n")

    print("wrote Tests/RpycFixtures.generated.swift")
    for name, _, blob in entries:
        print("%-12s %6d bytes" % (name, len(blob)))
    print("wrote Tests/ArchiveFixtures.generated.swift")
    print("%-12s %6d bytes" % ("archive", len(archive)))


if __name__ == "__main__":
    main()
