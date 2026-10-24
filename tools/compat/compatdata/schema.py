"""A JSON Schema validator for the keywords docs/schema/compat.schema.json uses.

The builder runs on a bare Python, so it cannot rely on the jsonschema package.
CI checks the same output with jsonschema as well. A keyword this file does not
know is an error, so the schema cannot quietly use one that is never checked.
"""

import datetime
import json
import pathlib
import re

SCHEMA_PATH = pathlib.Path(__file__).resolve().parents[3] / "docs" / "schema" / "compat.schema.json"

ANNOTATIONS = {"$schema", "$id", "$comment", "title", "description", "$defs"}
CHECKS = {
    "$ref", "type", "enum", "const", "properties", "required", "additionalProperties",
    "propertyNames", "minProperties", "items", "minItems", "minLength", "pattern",
    "minimum", "maximum", "exclusiveMinimum", "format",
}
FORMATS = {"date", "date-time"}


class SchemaError(Exception):
    pass


def load(path=SCHEMA_PATH):
    schema = json.loads(pathlib.Path(path).read_text())
    _check_keywords(schema)
    return schema


def _check_keywords(node):
    if isinstance(node, list):
        for item in node:
            _check_keywords(item)
        return
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        if key not in ANNOTATIONS and key not in CHECKS:
            raise SchemaError(f"unsupported keyword {key!r}")
        if key == "format" and value not in FORMATS:
            raise SchemaError(f"unsupported format {value!r}")
        if key in ("properties", "$defs"):
            for sub in value.values():
                _check_keywords(sub)
        elif key in ("items", "additionalProperties", "propertyNames"):
            _check_keywords(value)


def errors(document, schema):
    """Every place where document breaks schema, as "path: reason" strings."""
    found = []
    _validate(document, schema, schema, "$", found)
    return found


def _type_of(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "integer" if value.is_integer() else "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def _is_type(value, wanted):
    actual = _type_of(value)
    return actual == wanted or (wanted == "number" and actual == "integer")


def _same(a, b):
    # JSON equality: true is not 1
    return _type_of(a) == _type_of(b) and a == b


def _valid_format(value, fmt):
    try:
        if fmt == "date":
            return bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", value)) and bool(datetime.date.fromisoformat(value))
        if fmt == "date-time":
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})", value):
                return False
            datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return True
    except ValueError:
        return False
    return False


def _resolve(ref, root):
    if not ref.startswith("#/"):
        raise SchemaError(f"only local references are supported: {ref}")
    node = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def _validate(value, schema, root, path, found):
    if "$ref" in schema:
        _validate(value, _resolve(schema["$ref"], root), root, path, found)

    if "type" in schema:
        wanted = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, t) for t in wanted):
            found.append(f"{path}: {_type_of(value)} is not {' or '.join(wanted)}")
            return
    if "enum" in schema and not any(_same(value, option) for option in schema["enum"]):
        found.append(f"{path}: {value!r} is not one of {schema['enum']!r}")
    if "const" in schema and not _same(value, schema["const"]):
        found.append(f"{path}: {value!r} is not {schema['const']!r}")

    kind = _type_of(value)
    if kind in ("integer", "number"):
        if "minimum" in schema and value < schema["minimum"]:
            found.append(f"{path}: {value} is below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            found.append(f"{path}: {value} is above {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            found.append(f"{path}: {value} is not above {schema['exclusiveMinimum']}")
    elif kind == "string":
        if "minLength" in schema and len(value) < schema["minLength"]:
            found.append(f"{path}: shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            found.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if "format" in schema and not _valid_format(value, schema["format"]):
            found.append(f"{path}: {value!r} is not a {schema['format']}")
    elif kind == "array":
        if "minItems" in schema and len(value) < schema["minItems"]:
            found.append(f"{path}: fewer than {schema['minItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                _validate(item, schema["items"], root, f"{path}[{index}]", found)
    elif kind == "object":
        for name in schema.get("required", []):
            if name not in value:
                found.append(f"{path}: {name} is missing")
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            found.append(f"{path}: fewer than {schema['minProperties']} properties")
        properties = schema.get("properties", {})
        for name, item in value.items():
            where = f"{path}.{name}"
            if "propertyNames" in schema:
                _validate(name, schema["propertyNames"], root, f"{where} (name)", found)
            if name in properties:
                _validate(item, properties[name], root, where, found)
            elif schema.get("additionalProperties") is False:
                found.append(f"{where}: not allowed")
            elif isinstance(schema.get("additionalProperties"), dict):
                _validate(item, schema["additionalProperties"], root, where, found)
