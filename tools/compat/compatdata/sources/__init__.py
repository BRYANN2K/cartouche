"""One module per source. Each returns its blocks keyed by Steam App ID.

A source raises http.Unavailable when it does not answer, so the build can keep
its previous records, and FormatError when it answers with something the
builder does not understand, so the build stops before publishing.
"""


class FormatError(Exception):
    pass


class Result:
    def __init__(self, blocks=None, names=None, warnings=None, meta=None):
        self.blocks = blocks or {}
        self.names = names or {}
        self.warnings = warnings or []
        self.meta = meta or {}


def expect(condition, message):
    if not condition:
        raise FormatError(message)
