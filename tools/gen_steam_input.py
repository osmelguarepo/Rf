#!/usr/bin/env python3
"""Writes the Steam Input action manifest, steam_input/steam_input_manifest.vdf, and the default layout of each
controller type it lists, steam_input/controller_*.vdf (B4, docs/STEAM_INPUT.md).

    python3 tools/gen_steam_input.py [OUTPUT_FOLDER]     (default: the repository's steam_input/)

Standard library only. The action sets and actions must stay those of scripts/input/steam_input.gd (ACTIONS), and the
default layout the gamepad mapping of scripts/input/pads.gd and nav.gd: tests/test_steam_manifest.gd checks the files
it writes. Every action name is unique across the sets: ISteamInput's GetDigitalActionHandle() takes no set, so a name
used in two sets gets one handle and Steam ignores the other set's action.

Once a layout has been made in Steam's configurator and exported over its controller_*.vdf (docs/STEAM_INPUT.md),
edit that file by hand from then on: this script would write the generated layout over it again.
"""
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "steam_input")

# Action sets: name -> (title token, [(action, title token)]), in the order the configurator lists them.
SETS = [
    ("racing", "#Set_Racing", [
        ("accelerate", "#Action_Accelerate"),
        ("brake", "#Action_Brake"),
        ("steer_left", "#Action_SteerLeft"),
        ("steer_right", "#Action_SteerRight"),
        ("high_gear", "#Action_HighGear"),
        ("confirm", "#Action_Confirm"),
        ("pause", "#Action_Pause"),
        ("back", "#Action_Back"),
    ]),
    ("menus", "#Set_Menus", [
        ("menu_up", "#Menu_Up"),
        ("menu_down", "#Menu_Down"),
        ("menu_left", "#Menu_Left"),
        ("menu_right", "#Menu_Right"),
        ("menu_confirm", "#Menu_Confirm"),
        ("menu_back", "#Menu_Back"),
        ("menu_start", "#Menu_Start"),
        ("menu_quit", "#Menu_Quit"),
    ]),
]

_names = [action for _set, _title, actions in SETS for action, _token in actions]
assert len(_names) == len(set(_names)), "an action name is used twice"

LOCALIZATION = {
    "english": [
        ("Set_Racing", "Racing"),
        ("Set_Menus", "Menus"),
        ("Action_Accelerate", "Accelerate"),
        ("Action_Brake", "Brake"),
        ("Action_SteerLeft", "Steer left"),
        ("Action_SteerRight", "Steer right"),
        ("Action_HighGear", "High gear (also accelerates)"),
        ("Action_Confirm", "Confirm (a new controller takes a free car)"),
        ("Action_Pause", "Pause"),
        ("Action_Back", "Back (as a gamepad's Back)"),
        ("Menu_Up", "Up"),
        ("Menu_Down", "Down"),
        ("Menu_Left", "Left (one bot less)"),
        ("Menu_Right", "Right (one bot more)"),
        ("Menu_Confirm", "Confirm (join, choose, next round, rematch, retry)"),
        ("Menu_Back", "Back (leave your seat or the results)"),
        ("Menu_Start", "Start the race, resume"),
        ("Menu_Quit", "Back to the title, or to the join screen"),
        ("Title_Default", "Fuel Rivals"),
        ("Description_Default", "The game's own controls: the same buttons as a gamepad without Steam."),
    ],
    "spanish": [
        ("Set_Racing", "Carrera"),
        ("Set_Menus", "Menús"),
        ("Action_Accelerate", "Acelerar"),
        ("Action_Brake", "Frenar"),
        ("Action_SteerLeft", "Girar a la izquierda"),
        ("Action_SteerRight", "Girar a la derecha"),
        ("Action_HighGear", "Marcha alta (también acelera)"),
        ("Action_Confirm", "Confirmar (un mando nuevo toma un auto libre)"),
        ("Action_Pause", "Pausa"),
        ("Action_Back", "Atrás (como el Back de un mando)"),
        ("Menu_Up", "Arriba"),
        ("Menu_Down", "Abajo"),
        ("Menu_Left", "Izquierda (un bot menos)"),
        ("Menu_Right", "Derecha (un bot más)"),
        ("Menu_Confirm", "Confirmar (unirse, elegir, siguiente ronda, revancha, reintentar)"),
        ("Menu_Back", "Atrás (dejar tu plaza o los resultados)"),
        ("Menu_Start", "Empezar la carrera, reanudar"),
        ("Menu_Quit", "Volver al título, o a la pantalla de unión"),
        ("Title_Default", "Fuel Rivals"),
        ("Description_Default", "Los controles del juego: los mismos botones que un mando sin Steam."),
    ],
}

# Default bindings, the gamepad mapping of scripts/input/pads.gd and nav.gd. Per set: source kind ->
# [(mode, {input: [actions]})]. "dpad" is the controller's D-pad (the left trackpad on the 2015 Steam Controller),
# "joystick" the left stick, both in D-pad mode.
DIRECTIONS = {
    "racing": {"dpad_north": ["accelerate"], "dpad_south": ["brake"], "dpad_west": ["steer_left"],
               "dpad_east": ["steer_right"]},
    "menus": {"dpad_north": ["menu_up"], "dpad_south": ["menu_down"], "dpad_west": ["menu_left"],
              "dpad_east": ["menu_right"]},
}
FACE = {
    "racing": {"button_A": ["high_gear", "confirm"], "button_B": ["accelerate"]},
    "menus": {"button_A": ["menu_confirm"], "button_B": ["menu_back"]},
}
SWITCHES = {
    "racing": {"button_escape": ["pause"], "button_menu": ["back"]},
    "menus": {"button_escape": ["menu_start"], "button_menu": ["menu_quit"]},
}

# Controller type -> (file, the source of the directional pad).
CONTROLLERS = [
    ("controller_xbox360", "dpad"),
    ("controller_xboxone", "dpad"),
    ("controller_ps4", "dpad"),
    ("controller_ps5", "dpad"),
    ("controller_switch_pro", "dpad"),
    ("controller_generic", "dpad"),
    ("controller_steamcontroller_gordon", "left_trackpad"),
    ("controller_neptune", "dpad"),
]

LABELS = dict(LOCALIZATION["english"])
# The label of a binding follows a comma in its string ("game_action set action, label"): short, without commas.
BINDING_LABELS = {
    "accelerate": "Accelerate", "brake": "Brake", "steer_left": "Steer left", "steer_right": "Steer right",
    "high_gear": "High gear", "confirm": "Confirm", "pause": "Pause", "back": "Back", "menu_up": "Up",
    "menu_down": "Down", "menu_left": "Left", "menu_right": "Right", "menu_confirm": "Confirm",
    "menu_back": "Back", "menu_start": "Start", "menu_quit": "Title",
}


def q(text):
    return '"%s"' % text


class W:
    def __init__(self):
        self.lines = []
        self.depth = 0

    def kv(self, key, value):
        self.lines.append("\t" * self.depth + q(key) + "\t\t" + q(value))

    def open(self, key):
        self.lines.append("\t" * self.depth + q(key))
        self.lines.append("\t" * self.depth + "{")
        self.depth += 1

    def close(self):
        self.depth -= 1
        self.lines.append("\t" * self.depth + "}")

    def text(self):
        return "\n".join(self.lines) + "\n"


def actions_block(w, legacy):
    w.open("actions")
    for name, title, actions in SETS:
        w.open(name)
        w.kv("title", title)
        if legacy:
            w.kv("legacy_set", "0")
        w.open("StickPadGyro")
        w.close()
        w.open("AnalogTrigger")
        w.close()
        w.open("Button")
        for action, token in actions:
            w.kv(action, token)
        w.close()
        w.close()
    w.close()


def localization_block(w):
    w.open("localization")
    for language, entries in LOCALIZATION.items():
        w.open(language)
        for key, value in entries:
            w.kv(key, value)
        w.close()
    w.close()


def label_of(set_name, action):
    for name, _title, actions in SETS:
        if name == set_name:
            for each, _token in actions:
                if each == action:
                    return BINDING_LABELS[action]
    raise KeyError(action)


def group(w, gid, mode, inputs, set_name):
    w.open("group")
    w.kv("id", str(gid))
    w.kv("mode", mode)
    w.open("inputs")
    for name, actions in inputs.items():
        w.open(name)
        w.open("activators")
        w.open("Full_Press")
        w.open("bindings")
        for action in actions:
            w.kv("binding", "game_action %s %s, %s" % (set_name, action, label_of(set_name, action)))
        w.close()
        w.close()
        w.close()
        w.close()
    w.close()
    w.close()


def manifest():
    w = W()
    w.open("Action Manifest")
    w.open("configurations")
    for controller, _pad in CONTROLLERS:
        w.open(controller)
        w.open("0")
        w.kv("path", controller + ".vdf")
        w.close()
        w.close()
    w.close()
    actions_block(w, False)
    localization_block(w)
    w.close()
    return w.text()


def configuration(controller, pad):
    w = W()
    w.open("controller_mappings")
    w.kv("version", "3")
    w.kv("revision", "1")
    w.kv("title", "#Title_Default")
    w.kv("description", "#Description_Default")
    w.kv("controller_type", controller)
    w.kv("major_revision", "0")
    w.kv("minor_revision", "0")
    actions_block(w, True)
    localization_block(w)
    gid = 0
    presets = []
    for set_name, _title, _actions in SETS:
        sources = []
        group(w, gid, "four_buttons", FACE[set_name], set_name)
        sources.append((gid, "button_diamond"))
        gid += 1
        group(w, gid, "dpad", DIRECTIONS[set_name], set_name)
        sources.append((gid, pad))
        gid += 1
        group(w, gid, "dpad", DIRECTIONS[set_name], set_name)
        sources.append((gid, "joystick"))
        gid += 1
        group(w, gid, "switches", SWITCHES[set_name], set_name)
        sources.append((gid, "switch"))
        gid += 1
        presets.append((set_name, sources))
    for pid, (set_name, sources) in enumerate(presets):
        w.open("preset")
        w.kv("id", str(pid))
        w.kv("name", set_name)
        w.open("group_source_bindings")
        for gid_, source in sources:
            w.kv(str(gid_), source + " active")
        w.close()
        w.close()
    w.open("settings")
    w.close()
    w.close()
    return w.text()


os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "steam_input_manifest.vdf"), "w", encoding="utf-8", newline="\n") as f:
    f.write(manifest())
for controller, pad in CONTROLLERS:
    with open(os.path.join(OUT, controller + ".vdf"), "w", encoding="utf-8", newline="\n") as f:
        f.write(configuration(controller, pad))
print("wrote", 1 + len(CONTROLLERS), "files to", os.path.normpath(OUT))
