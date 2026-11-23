"""What the QA agent runs to use the canary copy of Nirux, through the app's
channel (channel.py): no focus taken, no Accessibility permission needed.
It reads NIRUX_STATE_DIR and NIRUX_CANARY_TOKEN from its environment.

  canaryctl.py snapshot | press <label> | menu <title>... |
               key <characters> [--code N] [--mod command|control|option|shift]... |
               text <text> | render
"""

import argparse
import os
import sys

from channel import Channel, ChannelError

MODIFIERS = ("command", "control", "option", "shift")


def parser():
    root = argparse.ArgumentParser(prog="canaryctl")
    actions = root.add_subparsers(dest="action", required=True)
    actions.add_parser("snapshot", help="the window's accessibility elements, as JSON")
    actions.add_parser("press", help="press the enabled element with this label").add_argument("label")
    actions.add_parser("menu", help="pick a menu item by its titles").add_argument("path", nargs="+")
    key = actions.add_parser("key", help="one key press, routed like a typed key")
    key.add_argument("characters")
    key.add_argument("--code", type=int, default=0, help="macOS virtual key code")
    key.add_argument("--mod", action="append", default=[], choices=MODIFIERS)
    actions.add_parser("text", help="type text, one key per character").add_argument("text")
    actions.add_parser("render", help="a PNG of the window; prints its path")
    return root


def run(args, client):
    actions = {
        "snapshot": lambda: client.call("snapshot"),
        "press": lambda: client.call("press", label=args.label),
        "menu": lambda: client.menu(*args.path),
        "key": lambda: client.key(args.characters, key_code=args.code, modifiers=args.mod),
        "text": lambda: client.text(args.text),
        "render": lambda: str(client.render()),
    }
    return actions[args.action]()


def main(argv=None, environ=os.environ):
    args = parser().parse_args(argv)
    try:
        client = Channel(environ["NIRUX_STATE_DIR"], environ["NIRUX_CANARY_TOKEN"])
        print(run(args, client))
    except KeyError as missing:
        print(f"canaryctl: {missing.args[0]} is not set", file=sys.stderr)
        return 2
    except ChannelError as error:
        print(f"canaryctl: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
