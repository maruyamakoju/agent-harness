"""Tests for forge.evaluator — evaluation helpers."""

from __future__ import annotations

from pathlib import Path

import pytest

from forge.evaluator import _sanitize_summary, _strip_control_chars, detect_language


# ---------------------------------------------------------------------------
# detect_language
# ---------------------------------------------------------------------------


class TestDetectLanguage:
    def test_python_pyproject(self, tmp_path: Path) -> None:
        (tmp_path / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
        assert detect_language(tmp_path) == "python"

    def test_python_setup_py(self, tmp_path: Path) -> None:
        (tmp_path / "setup.py").write_text("from setuptools import setup\n", encoding="utf-8")
        assert detect_language(tmp_path) == "python"

    def test_javascript(self, tmp_path: Path) -> None:
        (tmp_path / "package.json").write_text('{"name":"test"}\n', encoding="utf-8")
        assert detect_language(tmp_path) == "javascript"

    def test_rust(self, tmp_path: Path) -> None:
        (tmp_path / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
        assert detect_language(tmp_path) == "rust"

    def test_go(self, tmp_path: Path) -> None:
        (tmp_path / "go.mod").write_text("module example.com/test\n", encoding="utf-8")
        assert detect_language(tmp_path) == "go"

    def test_python_pytest_ini(self, tmp_path: Path) -> None:
        (tmp_path / "pytest.ini").write_text("[pytest]\n", encoding="utf-8")
        assert detect_language(tmp_path) == "python"

    def test_unknown(self, tmp_path: Path) -> None:
        assert detect_language(tmp_path) == "unknown"

    def test_python_takes_precedence_over_js(self, tmp_path: Path) -> None:
        """If both pyproject.toml and package.json exist, Python wins."""
        (tmp_path / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
        (tmp_path / "package.json").write_text('{"name":"test"}\n', encoding="utf-8")
        assert detect_language(tmp_path) == "python"


# ---------------------------------------------------------------------------
# _sanitize_summary
# ---------------------------------------------------------------------------


class TestSanitizeSummary:
    def test_strips_control_chars(self) -> None:
        text = "hello\x00world\x07test"
        result = _sanitize_summary(text)
        assert "\x00" not in result
        assert "\x07" not in result
        assert "helloworld" in result

    def test_escapes_backslashes(self) -> None:
        text = r"C:\Users\test\file.py"
        result = _sanitize_summary(text)
        assert "\\\\" in result

    def test_replaces_newlines(self) -> None:
        text = "line1\nline2\rline3"
        result = _sanitize_summary(text)
        assert "\n" not in result
        assert "\r" not in result

    def test_truncates_to_max_len(self) -> None:
        text = "x" * 500
        result = _sanitize_summary(text, max_len=200)
        assert len(result) <= 200

    def test_truncates_default(self) -> None:
        text = "a" * 300
        result = _sanitize_summary(text)
        assert len(result) <= 200

    def test_empty_string(self) -> None:
        assert _sanitize_summary("") == ""

    def test_preserves_tabs(self) -> None:
        # Tab is \x09, which is NOT matched by the control char regex
        # (regex is \x00-\x08 and \x0b-\x1f)
        text = "hello\tworld"
        result = _sanitize_summary(text)
        assert "\t" in result


# ---------------------------------------------------------------------------
# _strip_control_chars
# ---------------------------------------------------------------------------


class TestStripControlChars:
    def test_strips_null_byte(self) -> None:
        assert _strip_control_chars("a\x00b") == "ab"

    def test_preserves_newline_and_tab(self) -> None:
        # \n is \x0a (not in range \x00-\x08 or \x0b-\x1f)
        # But \x0b (vertical tab) IS stripped
        result = _strip_control_chars("a\nb")
        assert "\n" in result

    def test_strips_bell_char(self) -> None:
        assert _strip_control_chars("a\x07b") == "ab"
