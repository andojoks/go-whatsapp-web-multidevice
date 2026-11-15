#!/usr/bin/env bash
# Read and update KEY=value entries in a dotenv file without executing it.
#
# Values may contain shell metacharacters, so the file is never sourced.
# Surrounding single or double quotes are stripped by env_file_get.

env_file_get() {
  local file="$1"
  local key="$2"
  local default="${3:-}"

  if [[ ! -f "$file" ]]; then
    printf '%s' "$default"
    return 0
  fi

  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n1 || true)"
  if [[ -z "$line" ]]; then
    printf '%s' "$default"
    return 0
  fi

  line="${line#*=}"
  line="${line%$'\r'}"

  if [[ ${#line} -ge 2 && "${line:0:1}" == '"' && "${line: -1}" == '"' ]]; then
    line="${line:1:${#line}-2}"
    line="${line//\\\"/\"}"
    line="${line//\\\\/\\}"
  elif [[ ${#line} -ge 2 && "${line:0:1}" == "'" && "${line: -1}" == "'" ]]; then
    line="${line:1:${#line}-2}"
  fi

  printf '%s' "$line"
}

# Replace an existing key or append it. The value is written verbatim.
env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ "^[[:space:]]*" key "=") {
        if (!replaced) {
          print key "=" value
          replaced = 1
        }
        next
      }
      print line
    }
    END {
      if (!replaced) {
        print key "=" value
      }
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Set a key only when it is missing or empty.
env_set_default() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ -z "$(env_file_get "$file" "$key")" ]]; then
    env_set "$file" "$key" "$value"
  fi
}
