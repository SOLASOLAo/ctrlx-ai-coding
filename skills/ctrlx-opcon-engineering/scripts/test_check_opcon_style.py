"""Behavioral regression checks for the shared, read-only layout gate."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).with_name("check_opcon_style.py")
spec = importlib.util.spec_from_file_location("opcon_style", CHECKER)
style = importlib.util.module_from_spec(spec)
spec.loader.exec_module(style)

SCREENSHOT = """// Confirm the physical trigger is inhibited before selecting a program.
_retVal := RUNNING;
IF ( Wp100._DkGuardState = 20 ) AND ( NOT Wp100._DkGuardFault ) AND
   ( Wp101M740DanikorScrewer.Unit.ExecState = OpconExecState.READY ) AND
   ( Wp101M740DanikorScrewer.Unit.OutImm.IsSessionReady ) AND ( Wp101M740DanikorScrewer.Unit.OutImm.IsResultSubscriptionActive ) AND
   ( Wp101M740DanikorScrewer.Unit.OutImm.ToolStateKnown ) AND ( NOT Wp101M740DanikorScrewer.Unit.OutImm.IsToolEnabled )
THEN
  _retVal := OK;
END_IF
"""

GOOD = """_retVal := RUNNING;

IF ( Wp100._DkGuardState = 20 ) AND
   ( NOT Wp100._DkGuardFault ) AND
   ( Wp101M740DanikorScrewer.Unit.ExecState = OpconExecState.READY ) AND
   ( Wp101M740DanikorScrewer.Unit.OutImm.IsSessionReady ) AND
   ( Wp101M740DanikorScrewer.Unit.OutImm.IsResultSubscriptionActive ) AND
   ( Wp101M740DanikorScrewer.Unit.OutImm.ToolStateKnown ) AND
   ( NOT Wp101M740DanikorScrewer.Unit.OutImm.IsToolEnabled )
THEN
  _retVal := OK;
END_IF
"""


class LayoutChecks(unittest.TestCase):
    def rules(self, text):
        return {issue.rule for issue in style.check_st(text)}

    def test_both_workpositions_reject_the_reported_screenshot(self):
        for text in (SCREENSHOT, SCREENSHOT.replace("Wp100", "Wp300").replace("Wp101M740", "Wp103M740")):
            with self.subTest(workposition=text[100:130]):
                issues = style.check_st(text)
                broken_lines = {item.line for item in issues if item.rule == "ST_CONDITION_LINE"}
                self.assertEqual(broken_lines, {3, 5, 6})

    def test_both_corrected_actions_pass(self):
        self.assertEqual(style.check_st(GOOD), [])
        self.assertEqual(style.check_st(GOOD.replace("Wp100", "Wp300").replace("Wp101M740", "Wp103M740")), [])

    def test_consecutive_assignments_must_align(self):
        issues = style.check_st("Done := TRUE;\nLampOn := FALSE;\n")
        self.assertTrue(any(item.rule == "ST_ASSIGN_ALIGN" and item.line == 1 for item in issues))
        self.assertEqual(style.check_st("Done   := TRUE;\nLampOn := FALSE;\n"), [])

    def test_unrelated_assignment_blocks_are_not_padded_together(self):
        self.assertEqual(style.check_st("Short := 1;\n\nLongerName := 2;\n"), [])
        self.assertEqual(style.check_st("Short := 1;\n// Another responsibility.\nLongerName := 2;\n"), [])

    def test_then_must_be_alone_and_aligned(self):
        self.assertIn("ST_THEN_LINE", self.rules("IF ( Ready ) THEN\n  Start := TRUE;\nEND_IF\n"))
        self.assertIn("ST_THEN_ALIGN", self.rules("IF ( Ready )\n  THEN\n  Start := TRUE;\nEND_IF\n"))
        self.assertEqual(style.check_st("IF ( Ready )\nTHEN // Permission verified.\n  Start := TRUE;\nEND_IF\n"), [])

    def test_parentheses_and_internal_spaces_are_required(self):
        for condition in ("Ready", "(Ready )", "( Ready)", "(Ready)"):
            with self.subTest(condition=condition):
                self.assertTrue(self.rules(f"IF {condition}\nTHEN\n  Start := TRUE;\nEND_IF\n"))

    def test_logical_operator_belongs_at_previous_line_end(self):
        self.assertIn("ST_OPERATOR_END", self.rules("IF ( Ready )\n   AND ( Enabled )\nTHEN\n  Start := TRUE;\nEND_IF\n"))

    def test_nested_mixed_operators_and_not_keep_their_grouping(self):
        source = "IF ( ( A ) OR\n     ( NOT B ) ) AND\n   ( NOT ( ( C ) AND\n           ( D ) ) )\nTHEN\n  Done := TRUE;\nEND_IF\n"
        self.assertEqual(style.check_st(source), [])
        self.assertIn("ST_CONDITION_LINE", self.rules(source.replace("( A ) OR\n     ( NOT B )", "( A ) OR ( NOT B )")))

    def test_continuation_operands_must_align(self):
        self.assertIn("ST_CONDITION_ALIGN", self.rules("IF ( A ) AND\n     ( B )\nTHEN\n  Done := TRUE;\nEND_IF\n"))

    def test_comments_strings_and_pragmas_do_not_create_fake_statements(self):
        source = """(* Native readback header. (* IF bad THEN x:=1; y:=2; *) *)
{attribute 'IF a AND b THEN'}
Message := 'IF A AND B THEN; O$'Brien';
Other   := "IF A OR B;";
// IF bad THEN ignored := 1; ignoredToo := 2;
"""
        self.assertEqual(style.check_st(source), [])

    def test_two_space_branch_indent_and_one_statement_per_line(self):
        self.assertIn("ST_BRANCH_INDENT", self.rules("IF ( Ready )\nTHEN\n    Start := TRUE;\nEND_IF\n"))
        self.assertIn("ST_INDENT_TAB", self.rules("IF ( Ready )\nTHEN\n\tStart := TRUE;\nEND_IF\n"))
        self.assertIn("ST_STATEMENT_LINE", self.rules("A := 1; B := 2;\n"))

    def test_fb_arguments_and_bitwise_assignments_are_not_if_conditions(self):
        self.assertEqual(style.check_st("Call(\n  Short := A,\n  ALongArgument := B\n);\nMask := Value AND 16#FF;\n"), [])

    def test_aligned_boolean_assignment_continuations_are_not_block_indents(self):
        self.assertEqual(style.check_st("Ready := ( A ) AND\n         ( B );\n"), [])

    def test_supplier_declarations_in_native_text_are_not_reformatted(self):
        source = "VAR_INPUT\n    A : BOOL; B : BOOL;\nEND_VAR\n" + GOOD
        self.assertEqual(style.check_st(source), [])

    def test_single_line_sfc_all_ok_join_is_accepted_without_st_wrapping(self):
        expression = "( _retVal = OK ) AND ( _retVal2 = OK ) AND ( _retVal3 = OK )\r\n"
        self.assertEqual(style.check_transition(expression), [])

    def test_multiline_sfc_expression_is_rejected(self):
        for newline in ("\n", "\r\n", "\r"):
            issues = style.check_transition(f"( _retVal = OK ) AND{newline}( _retVal2 = OK )")
            self.assertEqual([item.rule for item in issues], ["SFC_SINGLE_LINE"])

    def test_bad_inputs_do_not_return_a_false_pass(self):
        for source in ("(* unfinished", "Message := 'unfinished", "IF ( Ready )"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                style.check_st(source)
        with self.assertRaises(ValueError):
            style.check_transition(" \n ")


class CommandChecks(unittest.TestCase):
    def test_real_exit_codes_and_read_only_inputs(self):
        with tempfile.TemporaryDirectory(prefix="opcon-style-test-") as temp:
            root = Path(temp)
            good = root / "good.st"
            bad = root / "bad.st"
            empty = root / "empty.st"
            transition = root / "join.txt"
            good.write_text(GOOD, encoding="utf-8")
            bad.write_text(SCREENSHOT, encoding="utf-8")
            empty.write_text("", encoding="utf-8")
            transition.write_text("( _retVal = OK ) AND\n( _retVal2 = OK )", encoding="utf-8")
            before = {path.name: path.read_bytes() for path in root.iterdir()}
            for arguments, expected in (([str(good)], 0), ([str(bad)], 1),
                                        (["--transition", str(transition)], 1),
                                        ([str(root / "missing.st")], 2),
                                        ([str(empty)], 2), ([], 2)):
                with self.subTest(arguments=arguments):
                    result = subprocess.run([sys.executable, str(CHECKER), *arguments], capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertEqual(before, {path.name: path.read_bytes() for path in root.iterdir()})


if __name__ == "__main__":
    unittest.main()
