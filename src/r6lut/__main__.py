import argparse
import json
from pathlib import Path
import sys

from . import __version__


def main(argv=None):
    parser = argparse.ArgumentParser(description="R6 III CUBE → PF3/full33 offline converter")
    parser.add_argument("--version", action="version", version=__version__)
    commands = parser.add_subparsers(dest="command", required=True)
    convert = commands.add_parser("convert", help="Convert one CUBE or a directory of CUBEs")
    convert.add_argument("--input", type=Path, required=True)
    convert.add_argument("--output", type=Path, required=True)
    convert.add_argument("--base", type=Path)
    convert.add_argument("--camera-data", type=Path)
    convert.add_argument("--library", type=Path)
    convert.add_argument("--context", type=Path, help="Your locally initialized camera/PSE context directory")
    convert.add_argument("--adaptation", choices=("none", "clog2", "clog3"), default="none",
                         help="Optional experimental photographic Log-input approximation; default unchanged direct conversion")
    convert.add_argument("--log-gamut", choices=("cinema-gamut", "bt709", "bt2020"), default="cinema-gamut")
    convert.add_argument("--lut-output", choices=("srgb", "gamma24", "same-log"), default="srgb",
                         help="Assumed source-CUBE output transfer; only used with CLog adaptation")
    preview = commands.add_parser("preview-lut", help="Prepare a color-managed photographic preview lookup")
    preview.add_argument("--input", type=Path, required=True)
    preview.add_argument("--output", type=Path, required=True)
    preview.add_argument("--adaptation", choices=("none", "clog2", "clog3"), default="none")
    preview.add_argument("--log-gamut", choices=("cinema-gamut", "bt709", "bt2020"), default="cinema-gamut")
    preview.add_argument("--lut-output", choices=("srgb", "gamma24", "same-log"), default="gamma24")
    preview.add_argument("--size", type=int, choices=(17,33,65), default=65)
    pf3_preview = commands.add_parser("preview-pf3", help="Preview a native PF3 using installed Canon offline rendering libraries")
    pf3_preview.add_argument("--input", type=Path, required=True)
    pf3_preview.add_argument("--photo", type=Path, required=True)
    pf3_preview.add_argument("--output", type=Path, required=True)
    pf3_preview.add_argument("--helper", type=Path, required=True)
    setup = commands.add_parser("setup-context", help="Create a private local context from your PSE Standard baseline and camera snapshot")
    setup.add_argument("--base", type=Path, required=True)
    setup.add_argument("--camera-data", type=Path, required=True)
    setup.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "preview-lut":
            from .preview import make_preview_lut
            result = make_preview_lut(args.input,args.output,args.adaptation,args.log_gamut,args.lut_output,args.size)
            print(json.dumps(result,ensure_ascii=False),flush=True)
        elif args.command == "preview-pf3":
            from .pf3_preview import preview_pf3
            result = preview_pf3(args.input, args.photo, args.output, args.helper)
            print(json.dumps(result, ensure_ascii=False), flush=True)
        elif args.command == "setup-context":
            from .context import setup_context
            result = setup_context(args.base, args.camera_data, args.output)
            print(json.dumps(result, ensure_ascii=False), flush=True)
        else:
            from .convert import convert as run_convert
            run_convert(args.input, args.output, args.base, args.camera_data, args.library,
                        lambda event: print(json.dumps(event, ensure_ascii=False), flush=True),
                        adaptation=args.adaptation, log_gamut=args.log_gamut, lut_output=args.lut_output,
                        context_path=args.context)
    except (ValueError, RuntimeError, OSError, UnicodeError) as error:
        print("r6lut: " + str(error), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
