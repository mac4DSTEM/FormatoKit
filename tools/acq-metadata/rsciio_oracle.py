"""RosettaSciIO's returned `mapping` applied the way HyperSpy applies it (shared by generate.py). A source path matches a
key when their slugs are equal, as HyperSpy's DictionaryTreeBrowser slugifies: parentheses dropped, runs of spaces and
hyphens become one underscore. The mapped function gets the original (unslugified) value."""
import re

from box import Box


def slug(key):
    key = re.sub(r'[^\w\s-]', '', str(key)).strip()
    return re.sub(r'[-\s]+', '_', key)


def lookup(tree, dotted):
    node = tree
    for part in dotted.split('.'):
        if not isinstance(node, dict):
            return None
        match = [k for k in node if slug(k) == slug(part)]
        if not match:
            return None
        node = node[match[0]]
    return node


def apply_mapping(signal):
    """{target: value} for every mapping entry whose source holds a value; a function that raises or returns None gives no entry."""
    out = {}
    for source, (target, func) in signal['mapping'].items():
        value = lookup(signal['original_metadata'], source)
        if value is None:
            continue
        try:
            value = func(Box(value, box_dots=True) if isinstance(value, dict) else value) if func else value
        except Exception:
            continue
        if value is None:
            continue
        out[target] = value
    return out
