#!/usr/bin/env python3
"""Adds new .swift files to HeadsUp.xcodeproj when xcodegen is not installed.

Run from the repo root: python3 tools/sync_xcodeproj.py

It looks for .swift files under HeadsUp/ and HeadsUpTests/ that the project does not
reference yet and adds each one to its folder's group and its target's Sources phase.
A new folder directly under HeadsUp/ gets a new group. It never removes anything.
File names must be unique across the project (they already are).
If xcodegen is available, prefer `xcodegen generate`; project.yml stays the source of truth.
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "HeadsUp.xcodeproj" / "project.pbxproj"
TARGETS = {"HeadsUp": "PBXSourcesBuildPhase app", "HeadsUpTests": "PBXSourcesBuildPhase tests"}


def make_id(kind, path):
    return hashlib.md5(f"{kind}:{path}".encode()).hexdigest()[:24].upper()


def insert_into_list(text, block_start, list_name, line):
    """Insert `line` into the `list_name = ( ... );` list of the object starting at block_start."""
    start = text.index(f"{list_name} = (\n", block_start) + len(f"{list_name} = (\n")
    end = text.index("\t\t\t);", start)
    lines = text[start:end].splitlines(keepends=True) + [line]
    lines.sort(key=lambda entry: entry.split("/* ")[1].lower())
    return text[:start] + "".join(lines) + text[end:]


def group_start(text, name, parent_path):
    """Index of the PBXGroup whose `path` is `name` (searching for its own path line)."""
    for match in re.finditer(r"\t\t([0-9A-F]{24}) /\* %s \*/ = \{\n\t\t\tisa = PBXGroup;" % re.escape(name), text):
        return match.start(), match.group(1)
    return None, None


def sources_phase_start(text, target):
    """The Sources build phase of a target, found through the PBXNativeTarget entry."""
    target_block = text.index(f"/* {target} */ = {{\n\t\t\tisa = PBXNativeTarget;")
    phase_id = re.search(r"([0-9A-F]{24}) /\* Sources \*/,", text[target_block:]).group(1)
    return text.index(f"\t\t{phase_id} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;")


def main():
    text = PBX.read_text()
    added = []
    for target in TARGETS:
        for path in sorted((ROOT / target).rglob("*.swift")):
            name = path.name
            if f"path = {name};" in text:
                continue
            relative = path.relative_to(ROOT)
            folder = path.parent.name
            file_id, build_id = make_id("file", relative), make_id("build", relative)

            text = text.replace(
                "/* End PBXBuildFile section */",
                f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
                "/* End PBXBuildFile section */")
            text = text.replace(
                "/* End PBXFileReference section */",
                f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
                f"path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */")

            start, _ = group_start(text, folder, relative.parent)
            if start is None:
                # New folder directly under the target folder: create its group.
                if path.parent.parent != ROOT / target:
                    sys.exit(f"{relative}: only one new folder level is supported")
                group_id = make_id("group", relative.parent)
                text = text.replace(
                    "/* End PBXGroup section */",
                    f"\t\t{group_id} /* {folder} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
                    f"\t\t\tpath = {folder};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n/* End PBXGroup section */")
                parent_start, _ = group_start(text, target, None)
                text = insert_into_list(text, parent_start, "children", f"\t\t\t\t{group_id} /* {folder} */,\n")
                start, _ = group_start(text, folder, relative.parent)
            text = insert_into_list(text, start, "children", f"\t\t\t\t{file_id} /* {name} */,\n")
            text = insert_into_list(text, sources_phase_start(text, target), "files",
                                    f"\t\t\t\t{build_id} /* {name} in Sources */,\n")
            added.append(str(relative))
    PBX.write_text(text)
    print("added:" if added else "nothing to add", *added, sep="\n  " if added else "")


if __name__ == "__main__":
    main()
