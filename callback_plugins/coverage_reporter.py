"""Ansible callback plugin that generates Cobertura XML task-level coverage."""

from __future__ import annotations

import os
import time
import xml.etree.ElementTree as ET
from xml.etree.ElementTree import Element, ElementTree, SubElement

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
    name: coverage_reporter
    type: aggregate
    short_description: Generate Cobertura XML task-coverage report
    description:
        - Records which Ansible tasks execute (file + line) and writes a
          Cobertura XML report so Codecov (or any compatible tool) can
          visualise playbook task coverage.
    requirements:
        - Enable via callbacks_enabled or ANSIBLE_CALLBACKS_ENABLED
    options:
        output_path:
            description: Path to write the Cobertura XML file.
            default: coverage.xml
            env:
                - name: ANSIBLE_COVERAGE_OUTPUT
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "coverage_reporter"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self._executed: dict[str, set[int]] = {}
        self._project_root: str | None = None
        self._output_path = os.environ.get("ANSIBLE_COVERAGE_OUTPUT", "coverage.xml")

    def v2_playbook_on_start(self, playbook):
        self._project_root = os.path.dirname(os.path.abspath(playbook._file_name))

    def v2_playbook_on_task_start(self, task, is_conditional):
        path_str = task.get_path()
        if ":" not in path_str:
            return
        filepath, line_str = path_str.rsplit(":", 1)
        try:
            line_num = int(line_str)
        except ValueError:
            return
        filepath = os.path.abspath(filepath)
        self._executed.setdefault(filepath, set()).add(line_num)

    def v2_playbook_on_stats(self, stats):
        if not self._project_root:
            return
        all_tasks = self._scan_task_lines()
        self._write_cobertura(all_tasks)

    # ------------------------------------------------------------------
    # Task-line scanner
    # ------------------------------------------------------------------

    def _scan_task_lines(self) -> dict[str, list[int]]:
        result: dict[str, list[int]] = {}
        skip_dirs = {".git", "__pycache__", ".tox", "node_modules", ".github"}
        for root, dirs, files in os.walk(self._project_root):
            dirs[:] = [d for d in dirs if d not in skip_dirs]
            for fname in sorted(files):
                if not fname.endswith((".yml", ".yaml")) or fname.startswith("."):
                    continue
                fpath = os.path.join(root, fname)
                lines = self._task_lines_in(fpath)
                if lines:
                    result[fpath] = lines
        return result

    @staticmethod
    def _task_lines_in(filepath: str) -> list[int]:
        try:
            with open(filepath) as fh:
                content = fh.read()
        except OSError:
            return []
        is_playbook = "hosts:" in content
        if not is_playbook and "import_tasks:" not in content:
            return []
        lines: list[int] = []
        for i, line in enumerate(content.splitlines(), 1):
            stripped = line.lstrip()
            if not stripped.startswith("- name:"):
                continue
            # In playbook files, indent-0 '- name:' is a play definition, not a task.
            if is_playbook and not line[0].isspace():
                continue
            lines.append(i)
        return lines

    # ------------------------------------------------------------------
    # Merge with prior run
    # ------------------------------------------------------------------

    def _load_existing_hits(self) -> dict[str, set[int]]:
        if not os.path.exists(self._output_path):
            return {}
        try:
            tree = ET.parse(self._output_path)
            root = tree.getroot()
            sources = root.findall(".//source")
            base = sources[0].text if sources else ""
            hits: dict[str, set[int]] = {}
            for cls in root.findall(".//class"):
                fname = cls.get("filename", "")
                fpath = os.path.abspath(os.path.join(base, fname)) if base else fname
                for line_el in cls.findall(".//line"):
                    if line_el.get("hits", "0") != "0":
                        hits.setdefault(fpath, set()).add(int(line_el.get("number")))
            return hits
        except Exception:  # noqa: BLE001
            return {}

    # ------------------------------------------------------------------
    # Cobertura XML writer
    # ------------------------------------------------------------------

    def _write_cobertura(self, all_tasks: dict[str, list[int]]) -> None:
        prior = self._load_existing_hits()
        merged: dict[str, set[int]] = {}
        for fpath in set(list(self._executed) + list(prior)):
            merged[fpath] = self._executed.get(fpath, set()) | prior.get(fpath, set())

        total = sum(len(v) for v in all_tasks.values())
        covered = 0
        for fpath, task_lines in all_tasks.items():
            covered += len(set(task_lines) & merged.get(fpath, set()))

        rate = (covered / total) if total else 0

        root_el = Element("coverage")
        root_el.set("version", "1")
        root_el.set("timestamp", str(int(time.time())))
        root_el.set("lines-valid", str(total))
        root_el.set("lines-covered", str(covered))
        root_el.set("line-rate", f"{rate:.4f}")
        root_el.set("branches-valid", "0")
        root_el.set("branches-covered", "0")
        root_el.set("branch-rate", "0")
        root_el.set("complexity", "0")

        sources_el = SubElement(root_el, "sources")
        src = SubElement(sources_el, "source")
        src.text = self._project_root

        packages_el = SubElement(root_el, "packages")
        pkg = SubElement(packages_el, "package")
        pkg.set("name", "ansible")
        pkg.set("line-rate", f"{rate:.4f}")
        pkg.set("branch-rate", "0")
        pkg.set("complexity", "0")

        classes_el = SubElement(pkg, "classes")

        for fpath in sorted(all_tasks):
            task_lines = all_tasks[fpath]
            executed = merged.get(fpath, set())
            rel = os.path.relpath(fpath, self._project_root)

            cls = SubElement(classes_el, "class")
            cls.set("name", os.path.basename(fpath))
            cls.set("filename", rel)
            hit = len(set(task_lines) & executed)
            cls.set("line-rate", f"{(hit / len(task_lines)) if task_lines else 0:.4f}")
            cls.set("branch-rate", "0")
            cls.set("complexity", "0")

            SubElement(cls, "methods")
            lines_el = SubElement(cls, "lines")
            for num in sorted(task_lines):
                line_el = SubElement(lines_el, "line")
                line_el.set("number", str(num))
                line_el.set("hits", "1" if num in executed else "0")

        tree = ElementTree(root_el)
        with open(self._output_path, "wb") as fh:
            tree.write(fh, encoding="utf-8", xml_declaration=True)
        self._display.display(
            f"Coverage report written to {self._output_path} "
            f"({covered}/{total} tasks covered)",
            color="green",
        )
