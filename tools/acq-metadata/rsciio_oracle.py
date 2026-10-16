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


def with_slugs(value):
    """A dict with every key also present slugified (HyperSpy's DictionaryTreeBrowser hands a mapped function slugified keys:
    `"Integration_time_s" in tags.keys()`); the original keys stay, as `_get_microscope_name` looks them up by their DM names."""
    if not isinstance(value, dict):
        return value
    out = {}
    for k, v in value.items():
        out[k] = with_slugs(v)
        out.setdefault(slug(k), out[k])
    return out


def apply_mapping(signal):
    """{target: value} for every mapping entry whose source holds a value; a function that raises or returns None gives no entry."""
    out = {}
    for source, (target, func) in signal['mapping'].items():
        value = lookup(signal['original_metadata'], source)
        if value is None:
            continue
        try:
            value = func(Box(with_slugs(value), box_dots=True) if isinstance(value, dict) else value) if func else value
        except Exception:
            continue
        if value is None:
            continue
        out[target] = value
    return out
