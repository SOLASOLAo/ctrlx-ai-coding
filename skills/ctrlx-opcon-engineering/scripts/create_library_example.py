"""Copy one bundled example into a new/empty directory; never starts engineering tools."""
import argparse
from pathlib import Path
import shutil


EXAMPLES = ("machinecommon", "ind360", "inntai")
EXAMPLE_ROOT = Path(__file__).resolve().parents[1] / "assets" / "library-examples"
IGNORED = {"__pycache__", ".pytest_cache", "data", "tmp"}


def example_files(source):
    return sorted(
        path for path in source.rglob("*")
        if path.is_file() and not path.is_symlink()
        and not any(part in IGNORED for part in path.relative_to(source).parts)
        and path.suffix != ".pyc"
    )


def create_example(name, destination, preview=False):
    if name not in EXAMPLES:
        raise ValueError("Unknown example: " + name)
    source = (EXAMPLE_ROOT / name).resolve()
    destination = Path(destination).resolve()
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError("Destination must be separate from the bundled source")
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise ValueError("Destination must be new or empty: " + str(destination))
    files = example_files(source)
    if not (source / "README.md").is_file() or not files:
        raise ValueError("Incomplete bundled example: " + str(source))
    if not preview:
        destination.mkdir(parents=True, exist_ok=True)
        for path in files:
            target = destination / path.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    return [str(path.relative_to(source)) for path in files]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--example", choices=EXAMPLES, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    try:
        files = create_example(args.example, args.destination, args.preview)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + "\n")
    print(("Would copy" if args.preview else "Copied"), len(files), "files to", args.destination.resolve())
    if args.preview:
        print("\n".join(files))
    else:
        print("Next: read", args.destination.resolve() / "README.md")
        print("No IDE, library installation, PLC runtime or device operation was performed.")


if __name__ == "__main__":
    main()
