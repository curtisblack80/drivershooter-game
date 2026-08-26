#!/usr/bin/env python3
"""Structural validator for this Godot 4 project.

Godot only reports most of these problems at runtime, one at a time, after a
slow editor import — and several of them (a mistyped node path inside an
`@onready`, an input action that was never defined, a `res://` path that moved)
fail silently or only on the code path that touches them. This script checks the
whole project in a second, with no engine involved, so a broken reference is
caught at commit time instead of during a four-player playtest.

It parses the text formats directly rather than pretending to be a GDScript
compiler. That bounds what it can prove: it verifies that everything *refers to
something that exists*, not that the code is correct. Type errors, bad API usage
and logic bugs still need the editor.

Checks performed
----------------
  1. Every `res://` path mentioned in any .gd / .tscn / .tres / project.godot
     file exists on disk.
  2. Every ExtResource / SubResource id used in a scene is declared in it.
  3. Every node's `parent` was declared earlier in the same scene.
  4. `load_steps` in a scene header matches the number of resources declared.
  5. Autoload scripts named in project.godot exist.
  6. Every input action used from GDScript is defined in project.godot.
  7. `class_name` declarations are unique and do not collide with autoloads.
  8. `$NodePath` and `%UniqueName` lookups in a scene's own scripts resolve
     against that scene's node tree.
  9. GDScript files are indented with tabs only, and brackets balance.
 10. A script attached to a node `extends` the node's declared type.

Usage:  python3 tools/validate_project.py [project_root]
Exit code is 1 when any error is found, 0 otherwise. Warnings do not fail.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Godot's built-in input actions. Using one of these without declaring it in
# project.godot is legal, so they must not be reported as missing.
# --------------------------------------------------------------------------
BUILTIN_ACTIONS = {
    "ui_accept", "ui_select", "ui_cancel", "ui_focus_next", "ui_focus_prev",
    "ui_left", "ui_right", "ui_up", "ui_down", "ui_page_up", "ui_page_down",
    "ui_home", "ui_end", "ui_cut", "ui_copy", "ui_paste", "ui_undo", "ui_redo",
    "ui_menu", "ui_text_completion_query", "ui_text_completion_accept",
    "ui_text_completion_replace", "ui_text_newline", "ui_text_newline_blank",
    "ui_text_newline_above", "ui_text_indent", "ui_text_dedent",
    "ui_text_backspace", "ui_text_delete", "ui_text_caret_left",
    "ui_text_caret_right", "ui_text_caret_up", "ui_text_caret_down",
    "ui_text_caret_line_start", "ui_text_caret_line_end",
    "ui_text_caret_page_up", "ui_text_caret_page_down",
    "ui_text_caret_document_start", "ui_text_caret_document_end",
    "ui_text_scroll_up", "ui_text_scroll_down", "ui_text_select_all",
    "ui_text_select_word_under_caret", "ui_text_add_selection_for_next_occurrence",
    "ui_text_clear_carets_and_selection", "ui_text_toggle_insert_mode",
    "ui_text_submit", "ui_graph_duplicate", "ui_graph_delete",
    "ui_filedialog_up_one_level", "ui_filedialog_refresh",
    "ui_filedialog_show_hidden", "ui_swap_input_direction",
}

RES_PATH_RE = re.compile(r'res://[A-Za-z0-9_\-./]+')
EXT_RESOURCE_RE = re.compile(r'^\[ext_resource\s+(.*)\]\s*$')
SUB_RESOURCE_RE = re.compile(r'^\[sub_resource\s+(.*)\]\s*$')
NODE_RE = re.compile(r'^\[node\s+(.*)\]\s*$')
HEADER_RE = re.compile(r'^\[gd_(scene|resource)\s+(.*)\]\s*$')
ATTR_RE = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
LOAD_STEPS_RE = re.compile(r'load_steps\s*=\s*(\d+)')
EXT_REF_RE = re.compile(r'ExtResource\(\s*"([^"]+)"\s*\)')
SUB_REF_RE = re.compile(r'SubResource\(\s*"([^"]+)"\s*\)')

ACTION_CALL_RE = re.compile(
    r'is_action(?:_just)?_(?:pressed|released)\(\s*&?"([^"]+)"'
)
GET_AXIS_RE = re.compile(
    r'get_axis\(\s*&?"([^"]+)"\s*,\s*&?"([^"]+)"\s*\)'
)
GET_VECTOR_RE = re.compile(
    r'get_vector\(\s*&?"([^"]+)"\s*,\s*&?"([^"]+)"\s*,\s*&?"([^"]+)"\s*,\s*&?"([^"]+)"\s*\)'
)
NODEPATH_VALUE_RE = re.compile(r'^NodePath\(\s*"([^"]*)"\s*\)\s*$')
CLASS_NAME_RE = re.compile(r'^class_name\s+(\w+)', re.MULTILINE)
EXTENDS_RE = re.compile(r'^(?:class_name\s+\w+\s+)?extends\s+([\w.]+)', re.MULTILINE)
DOLLAR_PATH_RE = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*)*)')
# `%` is both the unique-name prefix and the modulo/format operator. Requiring an
# identifier immediately after it, and nothing identifier-like immediately
# before, separates `%HealthBar` from `count % size`. String literals are
# stripped before this runs, which is what keeps "%d" out of the results.
UNIQUE_NAME_RE = re.compile(r'(?<![\w)\]])%([A-Za-z_][A-Za-z0-9_]*)')


@dataclass
class SceneNode:
    name: str
    node_type: str
    parent: str
    path: str
    is_instance: bool


@dataclass
class NodePathUse:
    owner_path: str
    property_name: str
    value: str
    line: int


@dataclass
class Scene:
    path: Path
    nodes: list[SceneNode] = field(default_factory=list)
    node_paths: set[str] = field(default_factory=set)
    unique_names: set[str] = field(default_factory=set)
    # node path -> res:// path of its script
    scripts: dict[str, str] = field(default_factory=dict)
    ext_ids: dict[str, str] = field(default_factory=dict)
    node_path_uses: list[NodePathUse] = field(default_factory=list)
    instances: set[str] = field(default_factory=set)


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f"{where}: {message}")


def parse_attrs(text: str) -> dict[str, str]:
    return {key: value for key, value in ATTR_RE.findall(text)}


def strip_strings_and_comments(source: str) -> str:
    """Blank out string literals and comments, preserving line structure.

    Node lookups (`$Child`, `%Unique`) must be found in code, never in text.
    Without this, every "%d" in a format string and every "res://" inside a
    comment looks like a node reference, and the real findings drown in noise.
    Characters are replaced with spaces rather than deleted so that reported
    line and column numbers still line up with the original file.
    """
    output: list[str] = []
    index = 0
    length = len(source)
    quote: str | None = None
    triple = False
    in_comment = False

    while index < length:
        character = source[index]

        if in_comment:
            if character == "\n":
                in_comment = False
                output.append(character)
            else:
                output.append(" ")
            index += 1
            continue

        if quote is not None:
            if triple and source.startswith(quote * 3, index):
                output.append("   ")
                index += 3
                quote = None
                triple = False
                continue
            if not triple and character == quote:
                output.append(" ")
                quote = None
                index += 1
                continue
            if character == "\\" and index + 1 < length:
                output.append("  ")
                index += 2
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue

        if character in "\"'":
            if source.startswith(character * 3, index):
                triple = True
                quote = character
                output.append("   ")
                index += 3
                continue
            quote = character
            triple = False
            output.append(" ")
            index += 1
            continue

        if character == "#":
            in_comment = True
            output.append(" ")
            index += 1
            continue

        output.append(character)
        index += 1

    return "".join(output)


def relative(root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def res_to_path(root: Path, res: str) -> Path:
    return root / res[len("res://"):]


# --------------------------------------------------------------------------
# Check 1 & 5: resource paths and autoloads
# --------------------------------------------------------------------------

def check_res_paths(root: Path, files: list[Path], report: Report) -> None:
    for file in files:
        text = file.read_text(encoding="utf-8", errors="replace")
        for res in sorted(set(RES_PATH_RE.findall(text))):
            # Strip a trailing dot that a sentence in a comment may have caught.
            candidate = res.rstrip(".")
            target = res_to_path(root, candidate)
            if not target.exists():
                report.error(relative(root, file), f"missing resource path {candidate}")


def check_autoloads(root: Path, report: Report) -> set[str]:
    project = root / "project.godot"
    names: set[str] = set()
    if not project.exists():
        report.error("project.godot", "file not found")
        return names

    in_autoload = False
    for line in project.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_autoload = stripped == "[autoload]"
            continue
        if not in_autoload or "=" not in stripped:
            continue
        name, value = stripped.split("=", 1)
        names.add(name.strip())
        res = value.strip().strip('"').lstrip("*")
        if res.startswith("res://") and not res_to_path(root, res).exists():
            report.error("project.godot", f"autoload '{name.strip()}' points at missing {res}")
    return names


def read_input_actions(root: Path) -> set[str]:
    project = root / "project.godot"
    actions: set[str] = set()
    if not project.exists():
        return actions
    in_input = False
    for line in project.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_input = stripped == "[input]"
            continue
        if in_input and "=" in stripped and not stripped.startswith(('"', "}")):
            name = stripped.split("=", 1)[0].strip()
            if name:
                actions.add(name)
    return actions


# --------------------------------------------------------------------------
# Checks 2, 3, 4: scene structure
# --------------------------------------------------------------------------

def parse_scene(root: Path, path: Path, report: Report) -> Scene:
    scene = Scene(path=path)
    lines = path.read_text(encoding="utf-8").splitlines()

    declared_ext: set[str] = set()
    declared_sub: set[str] = set()
    declared_steps: int | None = None
    current_node: SceneNode | None = None
    where = relative(root, path)

    for number, line in enumerate(lines, start=1):
        header = HEADER_RE.match(line)
        if header:
            found = LOAD_STEPS_RE.search(header.group(2))
            declared_steps = int(found.group(1)) if found else None
            continue

        ext = EXT_RESOURCE_RE.match(line)
        if ext:
            attrs = parse_attrs(ext.group(1))
            identifier = attrs.get("id", "")
            declared_ext.add(identifier)
            scene.ext_ids[identifier] = attrs.get("path", "")
            current_node = None
            continue

        sub = SUB_RESOURCE_RE.match(line)
        if sub:
            declared_sub.add(parse_attrs(sub.group(1)).get("id", ""))
            current_node = None
            continue

        node = NODE_RE.match(line)
        if node:
            body = node.group(1)
            attrs = parse_attrs(body)
            name = attrs.get("name", "")
            parent = attrs.get("parent", "")
            node_type = attrs.get("type", "")
            is_instance = "instance=" in body

            if not parent:
                node_path = "."
            elif parent == ".":
                node_path = name
            else:
                node_path = f"{parent}/{name}"

            if parent and parent != "." and parent not in scene.node_paths:
                report.error(
                    where,
                    f"line {number}: node '{name}' has parent '{parent}' "
                    "which was not declared before it",
                )

            entry = SceneNode(name, node_type, parent, node_path, is_instance)
            scene.nodes.append(entry)
            scene.node_paths.add(node_path)
            if is_instance:
                scene.instances.add(node_path)
            current_node = entry
            continue

        if line.startswith("["):
            current_node = None
            continue

        # Property line.
        if current_node is not None and "=" in line:
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key == "unique_name_in_owner" and value == "true":
                scene.unique_names.add(current_node.name)
            if key == "script":
                match = EXT_REF_RE.search(value)
                if match:
                    scene.scripts[current_node.path] = scene.ext_ids.get(match.group(1), "")
            node_path_value = NODEPATH_VALUE_RE.match(value)
            if node_path_value:
                scene.node_path_uses.append(
                    NodePathUse(current_node.path, key, node_path_value.group(1), number)
                )

        for identifier in EXT_REF_RE.findall(line):
            if identifier not in declared_ext:
                report.error(where, f"line {number}: undeclared ExtResource(\"{identifier}\")")
        for identifier in SUB_REF_RE.findall(line):
            if identifier not in declared_sub:
                report.error(where, f"line {number}: undeclared SubResource(\"{identifier}\")")

    actual_steps = len(declared_ext) + len(declared_sub) + 1
    if declared_steps is not None and declared_steps != actual_steps:
        # Godot rewrites this on save, so a mismatch is cosmetic rather than
        # fatal — but it is also a reliable sign that a resource was added or
        # removed by hand and something else was missed alongside it.
        report.warn(
            where,
            f"load_steps is {declared_steps} but {actual_steps} would be correct "
            f"({len(declared_ext)} ext + {len(declared_sub)} sub + 1)",
        )

    return scene


# --------------------------------------------------------------------------
# Checks 6-10: GDScript
# --------------------------------------------------------------------------

def check_gdscript(root: Path, path: Path, actions: set[str], report: Report) -> None:
    where = relative(root, path)
    text = path.read_text(encoding="utf-8")

    # 6. Input actions.
    used: set[str] = set(ACTION_CALL_RE.findall(text))
    for pair in GET_AXIS_RE.findall(text):
        used.update(pair)
    for quad in GET_VECTOR_RE.findall(text):
        used.update(quad)
    for action in sorted(used):
        if action not in actions and action not in BUILTIN_ACTIONS:
            report.error(where, f"input action '{action}' is not defined in project.godot")

    # 9. Indentation and bracket balance.
    in_block_string = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line.count('"""') % 2 == 1:
            in_block_string = not in_block_string
        if in_block_string or not line.strip():
            continue
        leading = line[: len(line) - len(line.lstrip())]
        if " " in leading:
            report.error(
                where,
                f"line {number}: indentation contains spaces; this project uses tabs",
            )

    # Self-targeted RPCs. `rpc_id(1, ...)` executed on the host targets the host
    # itself, and Godot only runs a self-targeted RPC when the method is declared
    # "call_local" — a "call_remote" one is silently dropped. The result is a
    # feature that works perfectly for every client and never works for the host.
    # A method may opt out with `# validator: host-never-calls-this` on its @rpc
    # line, for the case where the host provably takes a different code path.
    code = strip_strings_and_comments(text)
    rpc_modes: dict[str, str] = {}
    pending: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("@rpc"):
            pending = stripped
            continue
        if pending is not None and stripped.startswith("func "):
            name = stripped[len("func "):].split("(")[0].strip()
            rpc_modes[name] = pending
            pending = None
        elif stripped and not stripped.startswith("#"):
            pending = None

    for match in re.finditer(r'(\w+)\.rpc_id\(\s*1\s*,', code):
        name = match.group(1)
        mode = rpc_modes.get(name)
        if mode is None or "call_local" in mode:
            continue
        if "validator: host-never-calls-this" in mode:
            continue
        report.error(
            where,
            f"'{name}' is called with rpc_id(1, ...) but is not declared "
            "call_local, so the host's own call is dropped",
        )

    for opener, closer in (("(", ")"), ("[", "]"), ("{", "}")):
        if text.count(opener) != text.count(closer):
            report.warn(
                where,
                f"unbalanced '{opener}{closer}' "
                f"({text.count(opener)} vs {text.count(closer)}) — "
                "may be legitimate if they appear inside strings",
            )


def check_script_scene_binding(root: Path, scenes: list[Scene], report: Report) -> None:
    """Check 8 and 10: a script's node lookups resolve inside its own scene."""
    for scene in scenes:
        where = relative(root, scene.path)
        node_types = {node.path: node.node_type for node in scene.nodes}

        for node_path, script_res in scene.scripts.items():
            if not script_res.startswith("res://"):
                continue
            script_file = res_to_path(root, script_res)
            if not script_file.exists():
                continue
            source = script_file.read_text(encoding="utf-8")

            # 10. extends matches the node's declared type.
            declared_type = node_types.get(node_path, "")
            extends = EXTENDS_RE.search(source)
            if extends and declared_type and extends.group(1) != declared_type:
                report.warn(
                    where,
                    f"node '{node_path}' is type {declared_type} but "
                    f"{relative(root, script_file)} extends {extends.group(1)} "
                    "(fine if one derives from the other)",
                )

            code = strip_strings_and_comments(source)

            # `$Child` is relative to the node the script sits on, so a script on
            # a child resolves against that child's path, not the scene root.
            for lookup in sorted(set(DOLLAR_PATH_RE.findall(code))):
                resolved = resolve_node_path(node_path, lookup)
                if resolved is None or resolved in scene.node_paths:
                    continue
                report.error(
                    where,
                    f"{relative(root, script_file)} (on '{node_path}') looks up "
                    f"${lookup} -> '{resolved}', which is not a node in this scene",
                )

            # `%Unique` searches the whole owning scene, so it is only meaningful
            # to check from the root's script.
            if node_path != ".":
                continue

            for unique in sorted(set(UNIQUE_NAME_RE.findall(code))):
                if unique not in scene.unique_names:
                    report.error(
                        where,
                        f"{relative(root, script_file)} looks up %{unique} but no node "
                        "in this scene sets unique_name_in_owner",
                    )


def resolve_node_path(owner_path: str, value: str) -> str | None:
    """Resolve a relative NodePath against the node that declares it.

    Returns the resulting scene-relative path, or None for paths this validator
    deliberately does not follow (absolute paths, property sub-paths).
    """
    if not value or value.startswith("/") or ":" in value:
        return None

    components: list[str] = [] if owner_path == "." else owner_path.split("/")
    for part in value.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not components:
                # Climbed above the scene root; the target is outside this scene.
                return None
            components.pop()
        else:
            components.append(part)
    return "/".join(components) if components else "."


def check_node_paths(root: Path, scenes: list[Scene], report: Report) -> None:
    """A NodePath exported into a scene is the single most common thing to get
    silently wrong by hand: Godot resolves it to null at runtime and the feature
    just does not happen, with no error. Every vehicle surface link and wheel
    mapping in this project depends on one."""
    for scene in scenes:
        where = relative(root, scene.path)
        for use in scene.node_path_uses:
            resolved = resolve_node_path(use.owner_path, use.value)
            if resolved is None:
                continue
            if resolved in scene.node_paths:
                continue
            # A path that leads into an instanced sub-scene cannot be checked
            # from here, because those nodes live in the other scene file.
            inside_instance = any(
                resolved == instance or resolved.startswith(instance + "/")
                for instance in scene.instances
            )
            if inside_instance:
                continue
            report.error(
                where,
                f"line {use.line}: node '{use.owner_path}' property "
                f"{use.property_name} = NodePath(\"{use.value}\") resolves to "
                f"'{resolved}', which is not a node in this scene",
            )


def check_class_names(root: Path, scripts: list[Path], autoloads: set[str],
                      report: Report) -> None:
    seen: dict[str, Path] = {}
    for path in scripts:
        text = path.read_text(encoding="utf-8")
        match = CLASS_NAME_RE.search(text)
        if not match:
            continue
        name = match.group(1)
        if name in seen:
            report.error(
                relative(root, path),
                f"class_name '{name}' is already declared in {relative(root, seen[name])}",
            )
        seen[name] = path
        if name in autoloads:
            report.error(
                relative(root, path),
                f"class_name '{name}' collides with the autoload of the same name",
            )


# --------------------------------------------------------------------------

def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    report = Report()

    scripts = sorted(root.rglob("*.gd"))
    scene_files = sorted(root.rglob("*.tscn"))
    resource_files = sorted(root.rglob("*.tres"))
    all_text_files = scripts + scene_files + resource_files + [root / "project.godot"]
    all_text_files = [path for path in all_text_files if path.exists()]

    check_res_paths(root, all_text_files, report)
    autoloads = check_autoloads(root, report)
    actions = read_input_actions(root)

    scenes = [parse_scene(root, path, report) for path in scene_files]
    check_script_scene_binding(root, scenes, report)
    check_node_paths(root, scenes, report)
    check_class_names(root, scripts, autoloads, report)

    for path in scripts:
        check_gdscript(root, path, actions, report)

    print(f"Validated {len(scripts)} scripts, {len(scene_files)} scenes, "
          f"{len(resource_files)} resources under {root}")
    print(f"Input actions defined: {len(actions)}   Autoloads: {len(autoloads)}")
    print()

    for warning in report.warnings:
        print(f"  WARN   {warning}")
    for error in report.errors:
        print(f"  ERROR  {error}")

    print()
    if report.errors:
        print(f"FAILED — {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
        return 1
    print(f"OK — 0 errors, {len(report.warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
