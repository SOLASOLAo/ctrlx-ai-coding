"""Read-only checks for the user's BPP OpCon Plus ST/SFC layout.

Use --transition for raw native transition expressions; ordinary paths are ST.
This checks formatting, not PLC syntax, SFC behavior or native-source freshness.
"""

import argparse
from bisect import bisect_right
from collections import namedtuple
from pathlib import Path
import re
import sys


Token = namedtuple("Token", "text start end line column")
Issue = namedtuple("Issue", "path line column rule message")
LOGICAL = {"AND", "OR", "AND_THEN", "OR_ELSE"}
WORD = re.compile(r"[A-Za-z_][A-Za-z_0-9]*|:=|=>|<>|<=|>=|.", re.DOTALL)


def tokens_for(text):
    """Retain positions while excluding nested comments and compiler pragmas."""
    starts = [0] + [i + 1 for i, char in enumerate(text) if char == "\n"]
    tokens = []
    position = 0
    while position < len(text):
        if text[position].isspace():
            position += 1
            continue
        if text.startswith("//", position):
            end = text.find("\n", position)
            position = len(text) if end == -1 else end
            continue
        if text.startswith("(*", position):
            depth = 1
            position += 2
            while position < len(text) and depth:
                if text.startswith("(*", position):
                    depth += 1
                    position += 2
                elif text.startswith("*)", position):
                    depth -= 1
                    position += 2
                else:
                    position += 1
            if depth:
                raise ValueError("Unterminated ST block comment")
            continue
        if text[position] == "{":
            end = text.find("}", position + 1)
            if end == -1:
                raise ValueError("Unterminated compiler pragma")
            position = end + 1
            continue
        start = position
        if text[position] in "\"'":
            quote = text[position]
            position += 1
            while position < len(text):
                if text[position] == "$":
                    position += 2
                elif text[position] == quote:
                    position += 1
                    if position < len(text) and text[position] == quote:
                        position += 1
                    else:
                        break
                else:
                    position += 1
            else:
                raise ValueError("Unterminated ST string")
        else:
            position = WORD.match(text, position).end()
        line = bisect_right(starts, start)
        tokens.append(Token(text[start:position], start, position, line,
                            start - starts[line - 1]))
    return tokens


def check_st(text, path="<ST>"):
    tokens = tokens_for(text)
    lines = text.splitlines()
    issues = []
    by_line = {}
    for token in tokens:
        by_line.setdefault(token.line, []).append(token)

    def report(token, rule, message):
        issue = Issue(str(path), token.line, token.column + 1, rule, message)
        if issue not in issues:
            issues.append(issue)

    def wrapped(parts):
        if not parts or parts[0].text != "(" or parts[-1].text != ")":
            return False
        depth = 0
        for i, part in enumerate(parts):
            depth += (part.text == "(") - (part.text == ")")
            if depth == 0 and i < len(parts) - 1:
                return False
        return depth == 0

    def condition(parts, require_group=True):
        if not parts:
            return
        depth = 0
        operators = []
        for i, part in enumerate(parts):
            depth += (part.text == "(") - (part.text == ")")
            if depth == 0 and part.text.upper() in LOGICAL:
                operators.append(i)
        if operators:
            beginning = 0
            first_column = parts[0].column
            for i in operators:
                operator = parts[i]
                if i == 0 or parts[i - 1].line != operator.line:
                    report(operator, "ST_OPERATOR_END", "Keep AND/OR at the preceding line's end.")
                if i + 1 < len(parts) and parts[i + 1].line == operator.line:
                    report(operator, "ST_CONDITION_LINE", "Start the next independent condition on a new line.")
                condition(parts[beginning:i])
                beginning = i + 1
                if beginning < len(parts) and parts[beginning].column != first_column:
                    report(parts[beginning], "ST_CONDITION_ALIGN", "Align sibling condition operands.")
            condition(parts[beginning:])
        elif wrapped(parts):
            if (not text[parts[0].end:parts[0].end + 1].isspace()
                    or not text[parts[-1].start - 1:parts[-1].start].isspace()):
                report(parts[0], "ST_CONDITION_SPACE", "Write the condition as ( Condition ).")
            condition(parts[1:-1], require_group=False)
        elif require_group:
            report(parts[0], "ST_CONDITION_GROUP", "Parenthesize each independent condition: ( Condition ).")
        elif parts[0].text.upper() == "NOT" and wrapped(parts[1:]):
            condition(parts[1:])

    # Only executable IF/ELSIF/WHILE headers are parsed as conditions. Bitwise
    # expressions and FB argument lists are not mistaken for IF operands.
    header_lines = set()
    branch_first_lines = {}
    for index, token in enumerate(tokens):
        upper = token.text.upper()
        if upper not in {"IF", "ELSIF", "WHILE"}:
            continue
        terminator = "DO" if upper == "WHILE" else "THEN"
        end = index + 1
        while end < len(tokens) and tokens[end].text.upper() != terminator:
            if tokens[end].text == ";":
                raise ValueError(f"{path}:{token.line}: Missing {terminator} in condition header")
            end += 1
        if end == len(tokens):
            raise ValueError(f"{path}:{token.line}: Missing {terminator} in condition header")
        condition(tokens[index + 1:end])
        header_lines.update(range(token.line + 1, tokens[end].line + 1))
        if upper != "WHILE":
            then = tokens[end]
            if len(by_line[then.line]) != 1:
                report(then, "ST_THEN_LINE", "Put THEN alone on the next code line.")
            if then.column != token.column:
                report(then, "ST_THEN_ALIGN", "Align THEN with IF/ELSIF.")
            if end + 1 < len(tokens):
                first = tokens[end + 1]
                if first.text.upper() not in {"END_IF", "ELSE", "ELSIF"}:
                    branch_first_lines[first.line] = token.column + 2

    assignment_run = []

    def flush_assignments():
        if len(assignment_run) > 1:
            target = max(item.column for item in assignment_run)
            for item in assignment_run:
                if item.column != target:
                    report(item, "ST_ASSIGN_ALIGN", "Align := in consecutive assignments at the same indentation.")
        assignment_run.clear()

    previous_line = 0
    previous_indent = None
    declaration = False
    open_call_depth = 0
    previous_tail = None
    for line_number, parts in by_line.items():
        first = parts[0]
        upper = first.text.upper()
        continuation = (previous_tail is not None and
                        (previous_tail.text.upper() in LOGICAL or
                         previous_tail.text in {":=", ",", "(", "["}))
        previous_tail = parts[-1]
        if upper.startswith("VAR") and (upper == "VAR" or upper.startswith("VAR_")):
            declaration = True
        if declaration:
            flush_assignments()
            if upper == "END_VAR":
                declaration = False
            continue
        prefix = lines[line_number - 1][:first.column]
        if "\t" in prefix:
            report(first, "ST_INDENT_TAB", "Use spaces, not tabs, for indentation.")
        if upper in LOGICAL:
            report(first, "ST_OPERATOR_END", "Keep AND/OR at the preceding line's end.")
        if line_number in branch_first_lines and first.column != branch_first_lines[line_number]:
            report(first, "ST_BRANCH_INDENT", "Indent the first branch statement by two spaces.")
        if (line_number not in header_lines and not continuation
                and open_call_depth == 0 and first.column % 2):
            report(first, "ST_INDENT_WIDTH", "Use two-space block indentation.")
        if sum(part.text == ";" for part in parts) > 1:
            report(first, "ST_STATEMENT_LINE", "Put each executable statement on its own line.")

        assignment = None
        depth = open_call_depth
        for part in parts:
            if part.text == ":=" and depth == 0:
                assignment = part
                break
            depth += (part.text in {"(", "["}) - (part.text in {")", "]"})
        # Only complete assignment statements form an alignment block. An IF,
        # named call argument or multiline expression is not an adjacent write.
        if assignment and parts[-1].text == ";" and upper not in {"IF", "ELSIF", "WHILE"}:
            if previous_line != line_number - 1 or previous_indent != first.column:
                flush_assignments()
            assignment_run.append(assignment)
            previous_line = line_number
            previous_indent = first.column
        else:
            flush_assignments()
        for part in parts:
            open_call_depth += (part.text in {"(", "["}) - (part.text in {")", "]"})
    flush_assignments()
    return issues


def check_transition(text, path="<transition>"):
    expression = text.strip()
    if not expression:
        raise ValueError(f"Empty SFC transition: {path}")
    tokens_for(expression)  # Refuse malformed comments/strings, too.
    if "\n" in expression or "\r" in expression:
        return [Issue(str(path), 1, 1, "SFC_SINGLE_LINE",
                      "Keep the native SFC transition expression on one physical line.")]
    return []


def expand_paths(paths, directory_pattern):
    expanded = []
    for raw in paths:
        path = Path(raw)
        if not path.exists():
            raise ValueError(f"Input does not exist: {path}")
        if path.is_dir():
            files = sorted(path.rglob(directory_pattern))
            if not files:
                raise ValueError(f"No {directory_pattern} inputs in {path}")
            expanded.extend(files)
        else:
            expanded.append(path)
    return list(dict.fromkeys(expanded))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="ST files or directories of *.st; native text readbacks are accepted")
    parser.add_argument("--transition", action="append", default=[], metavar="FILE",
                        help="Raw native SFC expression file; repeat for each affected transition")
    args = parser.parse_args(argv)
    try:
        sources = expand_paths(args.paths, "*.st")
        transitions = expand_paths(args.transition, "*.txt")
        if not sources and not transitions:
            raise ValueError("Select at least one ST source or native transition expression")
        issues = []
        for path in sources:
            source = path.read_text(encoding="utf-8-sig")
            if not source.strip():
                raise ValueError(f"Empty ST input: {path}")
            issues.extend(check_st(source, path))
        for path in transitions:
            issues.extend(check_transition(path.read_text(encoding="utf-8-sig"), path))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"OpCon style INPUT ERROR: {error}", file=sys.stderr)
        return 2
    for issue in issues:
        print(f"{issue.path}:{issue.line}:{issue.column}: {issue.rule}: {issue.message}")
    print(f"OpCon style {'FAILED' if issues else 'OK'}: {len(sources)} ST, "
          f"{len(transitions)} SFC expressions, {len(issues)} violations")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
