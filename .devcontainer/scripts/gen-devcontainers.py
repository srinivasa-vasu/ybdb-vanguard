#!/usr/bin/env python3
"""
Generate .devcontainer/<exercise>/devcontainer.json from:
  .devcontainer/base.json                 shared defaults (ports, build, extensions, …)
  .devcontainer/<exercise>/override.json  per-exercise unique config

and validates every override.json "tasks" list plus
  .devcontainer/tasks.shared.json         tasks used by several exercises (ysql, clean, …)

.vscode/tasks.json is git-ignored and rendered inside each container (onCreateCommand,
refreshed in postStartCommand) with only that exercise's terminals:
  python3 gen-devcontainers.py --render-tasks <exercise> [out-path]

Usage:
  python3 gen-devcontainers.py [exercise-dir …]

  With no arguments, processes every init-* directory that has an override.json.
  Task specs of all exercises are always validated.

Generator-only keys in override.json (stripped before writing devcontainer.json):
  extensions           list   replace base extensions entirely when present
  extraForwardPorts    list   appended to base forwardPorts
  extraPortsAttributes dict   merged into base portsAttributes
  extraExclude         list   extra paths added to files.exclude beyond the default set
  tasks                list   terminals that auto-open for this exercise (see below)

Task spec (one entry in override.json "tasks"):
  label    str        task name; must include one "<x>-demo" and one "<x>-ws" per exercise
  detail   str        shown in Run Task
  command  str        shell command (no ART_PATH guard — only this exercise's tasks are rendered)
  group    str|null   terminal group (default: label); same group = split side by side,
                      null = no group. Never shared with another exercise.
  clear    bool       presentation.clear (default: true)
  "//"     list[str]  comment lines written above the task
  raw      dict       emit this task verbatim instead (compound / dependsOn tasks)

tasks.shared.json: {"head": [...], "tail": [...]} — head entries are raw tasks for every
exercise; tail entries are full tasks limited by "only": [ex, …] or "except": [ex, …].

Standard devcontainer keys whose presence in override.json triggers special handling:
  containerEnv         dict   deep-merged with base (additive)
  portsAttributes      dict   replaces base portsAttributes entirely when present
  runArgs              list   replaces base runArgs when present
  hostRequirements     dict   replaces base hostRequirements when present
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DC_DIR = os.path.dirname(SCRIPT_DIR)
ROOT_DIR = os.path.dirname(DC_DIR)


def load(path):
    with open(path) as f:
        return json.load(f)


def all_exercises():
    """List init-* dirs from the repo root — these are the workspace-root paths
    used in files.exclude and also match the .devcontainer/init-* structure."""
    return sorted(
        d for d in os.listdir(ROOT_DIR)
        if d.startswith("init-") and os.path.isdir(os.path.join(ROOT_DIR, d))
    )


def build_files_exclude(current, exercises, extra):
    """Always-hidden paths + every exercise directory except the current one."""
    out = {}
    for p in ["ybdb", "voyager-data", ".devcontainer", ".github"]:
        out[p] = True
    for ex in exercises:
        if ex != current:
            out[ex] = True
    for p in extra:
        out[p] = True
    return out


def generate(exercise, base, exercises):
    override_path = os.path.join(DC_DIR, exercise, "override.json")
    if not os.path.exists(override_path):
        return False

    ov = load(override_path)

    # validate required keys upfront for a clear error message
    for key in ("name", "postStartCommand"):
        if key not in ov:
            sys.exit(f"  ✗  {exercise}/override.json: missing required key '{key}'")

    # ── strip generator-only keys ─────────────────────────────────────────────
    extra_ports   = ov.pop("extraForwardPorts", [])
    extra_attrs   = ov.pop("extraPortsAttributes", {})
    extra_exclude = ov.pop("extraExclude", [])
    ext_override  = ov.pop("extensions", None)
    ports_replace = ov.pop("portsAttributes", None)   # full replacement if present
    ov.pop("tasks", None)                             # → .vscode/tasks.json (write_tasks)

    out = {}

    # ── fixed key order matches existing devcontainer.json style ──────────────
    out["name"]  = ov.pop("name")
    out["build"] = base["build"]

    # optional passthrough keys — present in override only when needed.
    # onCreateCommand always renders this exercise's .vscode/tasks.json first (it finishes
    # before the editor attaches); an override's own onCreateCommand runs after it.
    render = base["renderTasksCommand"]
    for k in ("initializeCommand", "features", "mounts"):
        if k in ov:
            out[k] = ov.pop(k)
    own = ov.pop("onCreateCommand", None)
    out["onCreateCommand"] = f"{render}; {own}" if own else render
    for k in ("updateContentCommand", "postCreateCommand", "waitFor", "postStopCommand"):
        if k in ov:
            out[k] = ov.pop(k)

    out["runArgs"]          = ov.pop("runArgs", base["runArgs"])
    out["containerEnv"]     = {**base["containerEnv"], **ov.pop("containerEnv", {})}
    out["hostRequirements"] = ov.pop("hostRequirements", base["hostRequirements"])

    # re-render on every start so pulled spec changes apply (no write when unchanged)
    out["postStartCommand"] = f"{render}; {ov.pop('postStartCommand')}"

    extensions = (ext_override if ext_override is not None
                  else list(base["customizations"]["vscode"]["extensions"]))
    out["customizations"] = {
        "vscode": {
            "settings": {
                "task.allowAutomaticTasks": "on",
                "files.exclude": build_files_exclude(exercise, exercises, extra_exclude),
            },
            "extensions": extensions,
        }
    }

    out["forwardPorts"] = list(dict.fromkeys(base["forwardPorts"] + extra_ports))

    attrs = {**(ports_replace if ports_replace is not None else base["portsAttributes"]),
             **extra_attrs}
    out["portsAttributes"] = attrs
    if "otherPortsAttributes" in ov:
        out["otherPortsAttributes"] = ov.pop("otherPortsAttributes")

    out["remoteUser"] = base["remoteUser"]

    if ov:
        print(f"  ⚠  {exercise}: unrecognised override keys: {list(ov.keys())}")

    out_path = os.path.join(DC_DIR, exercise, "devcontainer.json")
    with open(out_path, "w") as f:
        f.write("// Generated by gen-devcontainers.py — edit override.json instead.\n")
        json.dump(out, f, indent=2)
        f.write("\n")
    return True


# ── .vscode/tasks.json (rendered per exercise, inside the container) ──────────

def label_of(spec):
    return spec["raw"]["label"] if "raw" in spec else spec["label"]


def build_task(spec):
    if "raw" in spec:
        return dict(spec["raw"])
    presentation = {"reveal": "always", "panel": "dedicated"}
    group = spec.get("group", spec["label"])
    if group is not None:
        presentation["group"] = group
    presentation.update({"showReuseMessage": False, "clear": spec.get("clear", True), "close": True})
    return {
        "label": spec["label"],
        "detail": spec["detail"],
        "type": "shell",
        "command": spec["command"],
        "runOptions": {"runOn": "folderOpen"},
        "presentation": presentation,
        "problemMatcher": [],
    }


def build_shared_task(spec, exercise):
    """None if the shared task doesn't apply to this exercise (its only/except lists)."""
    if "raw" in spec:
        return dict(spec["raw"])
    if exercise not in spec.get("only", [exercise]) or exercise in spec.get("except", []):
        return None
    t = {k: v for k, v in spec.items() if k not in ("//", "only", "except")}
    order = ["label", "detail", "type", "command", "runOptions", "presentation", "problemMatcher"]
    return {k: t[k] for k in order if k in t} | {k: v for k, v in t.items() if k not in order}


def validate_tasks(per_exercise, shared, exercises):
    """Enforce the terminal conventions. Returns [(exercise or None, problem)];
    None marks a problem in tasks.shared.json, which affects every exercise."""
    problems, labels, group_owner = [], {}, {}
    for t in shared:
        labels[label_of(t)] = "tasks.shared.json"
        for ex in t.get("only", []) + t.get("except", []):
            if ex not in exercises:
                problems.append((None, f"tasks.shared.json/{label_of(t)}: unknown exercise '{ex}'"))
    for ex, specs in per_exercise.items():
        if not specs:
            problems.append((ex, f"{ex}: no tasks"))
            continue
        names = [label_of(s) for s in specs]
        demo = [n for n in names if n.endswith("-demo")]
        ws = [n for n in names if n.endswith("-ws")]
        if not demo or not ws:
            problems.append((ex, f"{ex}: needs a '<x>-demo' and a '<x>-ws' task (has {names})"))
        for s in specs:
            if "raw" in s:
                continue
            if "${env:ART_PATH}" in s["command"]:
                problems.append((ex, f"{ex}/{s['label']}: command must not test ART_PATH (tasks are per exercise)"))
            if s["label"] in demo + ws and f"cd {ex}" not in s["command"]:
                problems.append((ex, f"{ex}/{s['label']}: demo/ws terminals must 'cd {ex}'"))
            g = s.get("group", s["label"])
            if g is not None and group_owner.setdefault(g, ex) != ex:
                problems.append((ex, f"{ex}/{s['label']}: group '{g}' already used by {group_owner[g]}"))
        dgroups = {s.get("group", s["label"]) for s in specs if "raw" not in s and s["label"] in demo}
        wgroups = {s.get("group", s["label"]) for s in specs if "raw" not in s and s["label"] in ws}
        if (dgroups & wgroups) - {None}:
            problems.append((ex, f"{ex}: demo and ws terminals share group {dgroups & wgroups} (they'd open in one panel)"))
        for n in names:
            if n in labels:
                problems.append((ex, f"{ex}: label '{n}' already defined in {labels[n]}"))
            labels[n] = ex
    for ex, specs in per_exercise.items():
        for s in specs:
            for dep in s.get("raw", {}).get("dependsOn", []):
                if dep not in labels:
                    problems.append((ex, f"{ex}/{label_of(s)}: dependsOn unknown task '{dep}'"))
    return problems


def load_task_specs(exercises):
    shared = load(os.path.join(DC_DIR, "tasks.shared.json"))
    per_exercise, names = {}, {}
    for ex in exercises:
        p = os.path.join(DC_DIR, ex, "override.json")
        if os.path.exists(p):
            ov = load(p)
            per_exercise[ex] = ov.get("tasks", [])
            names[ex] = ov.get("name", "")
    return shared, per_exercise, names


def render_task(task, comment_lines):
    body = json.dumps(task, indent=2, ensure_ascii=False).replace("\n", "\n    ")
    if comment_lines:
        first, rest = body.split("\n", 1)
        body = first + "\n" + "".join(f"      // {c}\n" for c in comment_lines) + rest
    return "    " + body


def section(title):
    bar = "═" * 75
    return f"    // {bar}\n    // {title}\n    // {bar}\n"


def render_tasks(exercise, exercises, out_path):
    """Write tasks.json with only this exercise's terminals. Problems in other
    exercises are reported but never block this one. Returns (count, changed)."""
    shared, per_exercise, names = load_task_specs(exercises)
    if exercise not in per_exercise:
        sys.exit(f"  ✗  --render-tasks: unknown exercise '{exercise}'")
    fatal = []
    for owner, problem in validate_tasks(per_exercise, shared["head"] + shared["tail"], exercises):
        if owner in (exercise, None):
            fatal.append(problem)
        else:
            print(f"  ⚠  (other exercise) {problem}", file=sys.stderr)
    if fatal:
        sys.exit("  ✗  tasks.json not written:\n" + "\n".join(f"       - {p}" for p in fatal))

    def shared_blocks(specs):
        built = [(build_shared_task(s, exercise), s.get("//")) for s in specs]
        return [render_task(t, c) for t, c in built if t is not None]

    blocks = [section("Shared — open the README, housekeeping")] + shared_blocks(shared["head"])
    blocks.append("\n" + section(f"{exercise}  — {names[exercise]}"))
    blocks += [render_task(build_task(s), s.get("//")) for s in per_exercise[exercise]]
    tail = shared_blocks(shared["tail"])
    if tail:
        blocks += ["\n" + section("Shared — terminals used by several exercises")] + tail
    count = sum(1 for b in blocks if not b.startswith(("\n", "    //")))

    header = (
        f"// Rendered for {exercise} by gen-devcontainers.py --render-tasks — do not edit\n"
        "// (git-ignored; regenerated on container create and start). Edit the \"tasks\" list in\n"
        f"// .devcontainer/{exercise}/override.json or .devcontainer/tasks.shared.json instead.\n"
    )
    out = header + '{\n  "version": "2.0.0",\n  "tasks": [\n\n'
    out += "".join(b if b.startswith(("\n", "    //")) else b + ",\n" for b in blocks).rstrip(",\n") + "\n  ]\n}\n"

    # Unchanged → don't touch the file, so a running session never sees tasks.json rewritten
    if os.path.exists(out_path) and open(out_path).read() == out:
        return count, False
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write(out)
    return count, True


def main():
    base      = load(os.path.join(DC_DIR, "base.json"))
    exercises = all_exercises()

    # In-container mode (onCreateCommand / postStartCommand):
    #   gen-devcontainers.py --render-tasks <exercise> [out-path]
    if sys.argv[1:2] == ["--render-tasks"]:
        if len(sys.argv) not in (3, 4):
            sys.exit("usage: gen-devcontainers.py --render-tasks <exercise> [out-path]")
        out_path = sys.argv[3] if len(sys.argv) == 4 else os.path.join(ROOT_DIR, ".vscode", "tasks.json")
        n, changed = render_tasks(sys.argv[2], exercises, out_path)
        state = "written" if changed else "unchanged"
        print(f"  ✓  {os.path.relpath(out_path, ROOT_DIR)} {state}  ({n} tasks for {sys.argv[2]})")
        return

    targets   = sys.argv[1:] if len(sys.argv) > 1 else exercises

    ok = skip = 0
    for ex in targets:
        if generate(ex, base, exercises):
            print(f"  ✓  {ex}/devcontainer.json")
            ok += 1
        else:
            print(f"  –  {ex}  (no override.json)")
            skip += 1

    shared, per_exercise, _ = load_task_specs(exercises)
    problems = validate_tasks(per_exercise, shared["head"] + shared["tail"], exercises)
    if problems:
        sys.exit("  ✗  task specs invalid:\n" + "\n".join(f"       - {p}" for _, p in problems))
    n = sum(map(len, per_exercise.values()))
    print(f"  ✓  task specs valid  ({n} tasks across {len(per_exercise)} exercises; rendered per container)")
    print(f"\n{ok} generated, {skip} skipped.")


if __name__ == "__main__":
    main()
