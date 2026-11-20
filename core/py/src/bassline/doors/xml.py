"""XML, read with expat.

The first pass: each element is a record headed by its tag name (a
symbol), then a dict of the attributes it writes (text to text, ``{:}``
when it has none; defaults a DTD would add are not added), then its
children in order, where each run of text is one text. Names are kept as
written, prefix and all (``svg:rect``), and namespace declarations stay
attributes (``xmlns:svg``), so nothing about namespaces is resolved away.
Comments become ``(comment "…")``, processing instructions
``(pi target "…")``, and a document type ``(doctype name)``, with
``{public: … system: …}`` when it names them and the declarations of its
internal subset after that, in DTD terms: ``(ENTITY e "value")``,
``(ENTITY % p "value")``, ``(ATTLIST n lang "CDATA" "en")``,
``(ELEMENT n "(#PCDATA|b)*")``, ``(NOTATION gif {system: "image/gif"})``. An
entity reference the parser can't expand (one declared in an external DTD,
or an external entity) is kept where it stands as ``(entity name)``. Each
top-level node is one value, so a document is usually one value: its root
element.

What the first pass doesn't keep is the encoding layer: the XML
declaration (version, encoding, standalone), the byte-order mark, the
difference between CDATA and escaped text, and the references to internal
entities and characters, which are expanded. Whitespace between elements is
text like any other; the ``drop-whitespace`` lever takes it out.

The writer writes each value as a top-level node, back in the same
arrangement: a record whose first field is a dict is an element with those
attributes, other records with a name for a head are elements without
attributes, and other values inside an element are written as their text.
A value that isn't a node at all is refused.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import Any
from xml.parsers import expat

from ..errors import NotHeld
from ..text import to_text
from ..values import Dict, Kind, Record, Text, Value, rec, sym
from . import _vocab
from ._door import Door, TextWriter, spelled_keys, utf8_or_none

__all__ = ["door", "read", "loads", "dumps", "writer", "sure"]

COMMENT = sym.comment
PI = sym.pi
DOCTYPE = sym.doctype
ENTITY_REF = sym.entity
_EMPTY = Dict()
_DECLS = (sym.ENTITY, sym.ATTLIST, sym.ELEMENT, sym.NOTATION)
_QUANT = {expat.model.XML_CQUANT_NONE: "", expat.model.XML_CQUANT_OPT: "?",
          expat.model.XML_CQUANT_REP: "*", expat.model.XML_CQUANT_PLUS: "+"}


def _content_model(m) -> str:
    """An element declaration's content model, spelled as a DTD spells it."""
    kind, quant, name, children = m
    q = _QUANT[quant]
    if kind == expat.model.XML_CTYPE_EMPTY:
        return "EMPTY"
    if kind == expat.model.XML_CTYPE_ANY:
        return "ANY"
    if kind == expat.model.XML_CTYPE_MIXED:
        return "(#PCDATA" + "".join("|" + _content_model(c) for c in children) + ")" + q
    if kind == expat.model.XML_CTYPE_NAME:
        return name + q
    sep = "|" if kind == expat.model.XML_CTYPE_CHOICE else ","
    return "(" + sep.join(_content_model(c) for c in children) + ")" + q


def _ids(**ids) -> dict:
    return {sym(k): Text(v) for k, v in ids.items() if v}


def _parse(data: bytes | str) -> list[Value]:
    p = expat.ParserCreate()
    p.ordered_attributes = True
    p.specified_attributes = True
    top: list[Value] = []
    stack: list[list[Value]] = []
    text: list[str] = []
    doctype: list[Value] | None = None

    def flush() -> None:
        if text:
            if stack:
                stack[-1].append(Text("".join(text)))
            text.clear()

    def put(v: Value) -> None:
        flush()
        if doctype is not None:
            doctype.append(v)
        else:
            (stack[-1] if stack else top).append(v)

    def start(name, attrs):
        flush()
        pairs = ((Text(attrs[i]), Text(attrs[i + 1])) for i in range(0, len(attrs), 2))
        stack.append([sym(name), Dict(pairs) if attrs else _EMPTY])

    def end(name):
        flush()
        node = Record._trusted(tuple(stack.pop()))
        (stack[-1] if stack else top).append(node)

    def chars(data):
        if stack:
            text.append(data)

    def doctype_start(name, system, public, has_internal_subset):
        nonlocal doctype
        doctype = [sym(name), Dict(_ids(public=public, system=system))]

    def doctype_end():
        nonlocal doctype
        fields, doctype = doctype, None
        if len(fields) == 2 and not fields[1]:
            fields = fields[:1]
        put(rec(DOCTYPE, *fields))

    def entity_decl(name, is_parameter, value, base, system, public, notation):
        head = [sym.ENTITY] + ([sym("%")] if is_parameter else []) + [sym(name)]
        if value is not None:
            put(rec(*head, Text(value)))
        else:
            put(rec(*head, Dict(_ids(public=public, system=system, ndata=notation))))

    def attlist_decl(element, attr, kind, default, required):
        if default is None:
            spelled = [Text("#REQUIRED" if required else "#IMPLIED")]
        else:
            spelled = ([Text("#FIXED")] if required else []) + [Text(default)]
        put(rec(sym.ATTLIST, sym(element), sym(attr), Text(kind), *spelled))

    def skipped(name, is_parameter):
        if not is_parameter:
            put(rec(ENTITY_REF, sym(name)))

    def external(context, base, system, public):
        put(rec(ENTITY_REF, sym(context)))
        return 1

    p.StartElementHandler = start
    p.EndElementHandler = end
    p.CharacterDataHandler = chars
    p.CommentHandler = lambda data: put(rec(COMMENT, Text(data)))
    p.ProcessingInstructionHandler = lambda target, data: put(rec(PI, sym(target), Text(data)))
    p.StartDoctypeDeclHandler = doctype_start
    p.EndDoctypeDeclHandler = doctype_end
    p.EntityDeclHandler = entity_decl
    p.AttlistDeclHandler = attlist_decl
    p.ElementDeclHandler = lambda name, model: put(rec(sym.ELEMENT, sym(name),
                                                       Text(_content_model(model))))
    p.NotationDeclHandler = lambda name, base, system, public: put(
        rec(sym.NOTATION, sym(name), Dict(_ids(public=public, system=system))))
    p.SkippedEntityHandler = skipped
    p.ExternalEntityRefHandler = external
    try:
        p.Parse(data.encode("utf-8") if isinstance(data, str) else bytes(data), True)
    except expat.ExpatError as e:
        raise NotHeld(f"not XML: {e}") from None
    return top


# ---------------------------------------------------------------- writing

_NAME = re.compile(r"[A-Za-z_:][-A-Za-z0-9._:\u00b7\u00c0-\uffff]*\Z")


def _escape(s: str, attr: bool = False) -> str:
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if attr:
        s = (s.replace('"', "&quot;").replace("\t", "&#9;")
             .replace("\n", "&#10;").replace("\r", "&#13;"))
    else:
        s = s.replace("\r", "&#13;")
    return s


def _plain(v: Value) -> str:
    """A value inside an element, or an attribute value, as text."""
    k = v.kind
    if k in (Kind.TEXT, Kind.SYMBOL):
        return v.value
    if k == Kind.NIL:
        return ""
    s = _vocab.spelling(v) or _vocab.iso(v)
    if s is not None:
        return s
    if k == Kind.BYTES:
        return "0x" + v.value.hex()
    return to_text(v)


def _name_of(v: Value) -> str | None:
    if v.kind in (Kind.SYMBOL, Kind.TEXT) and _NAME.match(v.value):
        return v.value
    return None


def _attr_name(k: Value) -> str:
    name = _name_of(k)
    if name is None:
        raise NotHeld(f"{to_text(k)} can't be an XML attribute name")
    return name


def _node(v: Value, out: list[str], top: bool) -> None:
    if v.kind != Kind.RECORD:
        if top:
            raise NotHeld(f"an XML document is elements, records headed by a tag "
                          f"name; not {to_text(v)[:60]}")
        out.append(_escape(_plain(v)))
        return
    head, fields = v.head, v.fields
    if head == COMMENT and len(fields) == 1 and fields[0].kind == Kind.TEXT:
        if "--" in fields[0].value or fields[0].value.endswith("-"):
            raise NotHeld("an XML comment can't hold '--' or end with '-'")
        out.append(f"<!--{fields[0].value}-->")
        return
    if head == PI and len(fields) == 2 and _name_of(fields[0]) and fields[1].kind == Kind.TEXT:
        if "?>" in fields[1].value:
            raise NotHeld("a processing instruction can't hold '?>'")
        data = fields[1].value
        out.append(f"<?{fields[0].value}{' ' + data if data else ''}?>")
        return
    if head == DOCTYPE and fields and _name_of(fields[0]) and top:
        ids = fields[1] if len(fields) > 1 and fields[1].kind == Kind.DICT else _EMPTY
        s = f"<!DOCTYPE {fields[0].value}{_external_id(ids)}"
        decls = fields[2:] if len(fields) > 1 and fields[1].kind == Kind.DICT else fields[1:]
        if decls:
            s += " [\n" + "".join(_decl(d) + "\n" for d in decls) + "]"
        out.append(s + ">")
        return
    if head == ENTITY_REF and len(fields) == 1 and _name_of(fields[0]) and not top:
        out.append(f"&{fields[0].value};")
        return
    name = _name_of(head)
    if name is None:
        if top:
            raise NotHeld(f"{to_text(head)} can't be an XML element name")
        out.append(_escape(to_text(v)))
        return
    attrs, children = _EMPTY, fields
    if fields and fields[0].kind == Kind.DICT:
        attrs, children = fields[0], fields[1:]
    out.append("<" + name)
    for an, a in spelled_keys(attrs, _attr_name, "an XML element's attributes"):
        out.append(f' {an}="{_escape(_plain(a), attr=True)}"')
    if not children:
        out.append("/>")
        return
    out.append(">")
    for c in children:
        _node(c, out, False)
    out.append(f"</{name}>")


def _quoted(s: str) -> str:
    return f"'{s}'" if '"' in s else f'"{s}"'


def _external_id(ids: Value) -> str:
    public, system = ids.get(sym.public), ids.get(sym.system)
    if public is not None:
        return f" PUBLIC {_quoted(_plain(public))} {_quoted(_plain(system) if system is not None else '')}"
    if system is not None:
        return f" SYSTEM {_quoted(_plain(system))}"
    return ""


def _decl(d: Value) -> str:
    """A declaration of a doctype's internal subset, as the DTD spells it."""
    if d.kind != Kind.RECORD:
        raise NotHeld(f"a doctype holds declarations, not {to_text(d)[:60]}")
    if d.head in (COMMENT, PI):
        out: list[str] = []
        _node(d, out, False)
        return "".join(out)
    names = [f.value if f.kind in (Kind.SYMBOL, Kind.TEXT) else to_text(f) for f in d.fields]
    if d.head == sym.ENTITY and d.fields:
        last = d.fields[-1]
        if last.kind == Kind.TEXT:
            value = last.value.replace("&", "&#38;").replace("%", "&#37;").replace('"', "&#34;")
            return f'<!ENTITY {" ".join(names[:-1])} "{value}">'
        ids = last if last.kind == Kind.DICT else _EMPTY
        ndata = ids.get(sym.ndata)
        return (f"<!ENTITY {' '.join(names[:-1])}{_external_id(ids)}"
                f"{' NDATA ' + _plain(ndata) if ndata is not None else ''}>")
    if d.head == sym.ATTLIST and len(d.fields) >= 4:
        element, attr, kind, *default = names
        spelled = " ".join(x if x.startswith("#") else _quoted(x) for x in default)
        return f"<!ATTLIST {element} {attr} {kind} {spelled}>"
    if d.head == sym.ELEMENT and len(d.fields) == 2:
        return f"<!ELEMENT {names[0]} {names[1]}>"
    if d.head == sym.NOTATION and len(d.fields) == 2 and d.fields[1].kind == Kind.DICT:
        ids = d.fields[1]
        if sym.public in ids and sym.system not in ids:
            return f"<!NOTATION {names[0]} PUBLIC {_quoted(_plain(ids[sym.public]))}>"
        return f"<!NOTATION {names[0]}{_external_id(ids)}>"
    raise NotHeld(f"not a DTD declaration: {to_text(d)[:60]}")


def to_xml(v: Value) -> str:
    """One top-level node as XML text."""
    out: list[str] = []
    _node(v, out, True)
    return "".join(out)


class XMLDoor(Door):
    name = "xml"
    summary = "XML: elements as records headed by their tag, attributes, children"
    extensions = (".xml", ".svg", ".xhtml", ".xsd", ".xsl", ".rss", ".atom")
    readings = ("xml",)
    writers = ("xml",)

    def sure(self, data: bytes | str) -> int:
        text = utf8_or_none(data)
        if text is None:
            if not isinstance(data, (bytes, bytearray)) or b"<" not in bytes(data)[:64]:
                return 0
        elif not text.lstrip().startswith("<"):
            return 0
        try:
            nodes = _parse(data)
        except NotHeld:
            return 0
        return 85 if any(n.kind == Kind.RECORD and n.head not in (COMMENT, PI, DOCTYPE)
                         for n in nodes) else 0

    def _read(self, data, reading) -> Iterator[Value]:
        return iter(_parse(data))

    def _writer(self, out: Any, name: str) -> TextWriter:
        return TextWriter(out, lambda v: to_xml(v) + "\n")


door = XMLDoor()
read = door.read
loads = door.loads
dumps = door.dumps
writer = door.writer
sure = door.sure
