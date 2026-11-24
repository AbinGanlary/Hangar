"""Rename the app's visible name in Localizable.xcstrings: LiveContainer -> Hangar,
"built-in SideStore" -> "Hangar's installer". URLs (links to the upstream project) are kept.
Only "value" entries change; keys stay the same so the code that looks them up is untouched.
Run from the repo root: python -I branding/rebrand_strings.py
"""
import re

PATH = "Resources/Localizable.xcstrings"
URL = re.compile(r"(https?://[^\s)\"\]]+)")
VALUE = re.compile(r'("value" : ")((?:[^"\\]|\\.)*)(")')
NAME = re.compile(r"(?<![/\w.])LiveContainer(?![/.]\w)")


def fix(text: str) -> str:
    parts = URL.split(text)
    for i in range(0, len(parts), 2):  # even items are outside URLs
        p = parts[i]
        p = p.replace("Built-in SideStore", "Hangar's installer")
        p = p.replace("built-in SideStore", "Hangar's installer")
        p = NAME.sub("Hangar", p)
        parts[i] = p
    return "".join(parts)


def main():
    raw = open(PATH, encoding="utf-8").read()
    changed = 0

    def repl(m):
        nonlocal changed
        new = fix(m.group(2))
        if new != m.group(2):
            changed += 1
        return m.group(1) + new + m.group(3)

    out = VALUE.sub(repl, raw)
    with open(PATH, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    print("changed values:", changed)


if __name__ == "__main__":
    main()
