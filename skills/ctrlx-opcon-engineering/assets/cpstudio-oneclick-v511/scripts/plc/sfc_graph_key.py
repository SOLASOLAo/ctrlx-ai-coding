"""Comparison key for the observed PLE 2.6 native REST SFC serialization.

Not a graph editor. Revalidate serializer normalizations on another version.
"""
import xml.etree.ElementTree as ET


def graph_key(text):
    root = ET.fromstring(text)

    def key(el):
        tag = el.tag.rsplit('}', 1)[-1]
        attrs = dict(el.attrib)
        if tag == 'transition':
            attrs.pop('name', None)  # Observed native serializer omits this field.
        if tag == 'connection' and attrs.get('formalParameter') == 'sfc':
            attrs.pop('formalParameter')  # Observed native SFC port inference.
        return tag, sorted(attrs.items()), (el.text or '').strip(), [key(c) for c in el]

    return key(root)
