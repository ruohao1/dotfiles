# Shared, additive schema for session line pins. Keep snapshots backward compatible.
def pin_integer($minimum):
  type == "number" and floor == . and . >= $minimum and . <= 2147483647;

# jq can retain numeric source spelling (1.0, 1e0, -0). Hash integer values.
def canonical_line_pin:
  .line |= (floor + 0) | .col |= (floor + 0);

def line_pin_location:
  type == "object"
  and (keys == ["col", "line", "path"])
  and (.path | type == "string" and startswith("/") and utf8bytelength <= 8192
    and (contains("\u0000") | not))
  and (.line | pin_integer(1))
  and (.col | pin_integer(0));

def line_pin_record:
  type == "object"
  and (keys == ["col", "id", "line", "path"])
  and (.id | type == "string" and test("^[0-9a-f]{64}$"))
  and (del(.id) | line_pin_location);

def line_pin_state:
  type == "object"
  and (keys == ["pins", "version"])
  and .version == 1
  and (.pins | type == "array"
    and all(.[]; line_pin_record)
    and (length == (unique_by(.id) | length))
    and (length == (unique_by([.path, .line, .col]) | length)));
