import 'dart:convert';

// A rule with every construct the diagram draws, and the engine's real
// `automation.diagram` replies for it, dumped from the engine's
// `Diagram.of` and `Diagram.mark`, so the app tests use their exact
// shape.

Map<String, Object?> everyPartSpec() =>
    jsonDecode(_spec) as Map<String, Object?>;

Map<String, Object?> _reply(String json) => {
  'ok': true,
  ...jsonDecode(json) as Map<String, Object?>,
};

/// The diagram of [everyPartSpec].
Map<String, Object?> everyPartDiagram() => _reply(_plain);

/// Lit by a run: the check passed seeing 31, the If went its no way,
/// and the try failed into its fallback.
Map<String, Object?> everyPartRun() => _reply(_run);

/// Lit by a trigger the onlyIf check stopped, seeing 24.
Map<String, Object?> everyPartSkip() => _reply(_skip);

const _spec = r'''
{
  "name": "Every part",
  "when": [
    {
      "on": "jade.home",
      "change": {
        "to": true
      }
    },
    {
      "time": "18:00"
    }
  ],
  "onlyIf": [
    {
      "state": "room_temp.temp",
      "op": ">",
      "value": 28
    }
  ],
  "then": [
    {
      "do": "desk_lamp.power",
      "params": {
        "value": true
      }
    },
    {
      "if": [
        {
          "state": "desk_lamp.state",
          "op": "==",
          "value": true
        }
      ],
      "then": [
        {
          "wait": 3000
        }
      ],
      "else": [
        {
          "notify": {
            "title": "Lamp is off"
          }
        }
      ]
    },
    {
      "together": [
        [
          {
            "do": "hall_bulb.power",
            "params": {
              "value": true
            }
          }
        ],
        [
          {
            "wait": 1000
          },
          {
            "notify": {
              "title": "B"
            }
          }
        ]
      ]
    },
    {
      "try": [
        {
          "do": "desk_lamp.wake"
        }
      ],
      "otherwise": [
        {
          "notify": {
            "title": "Failed"
          }
        }
      ]
    },
    {
      "repeat": {
        "times": 3,
        "every": 3000,
        "do": [
          {
            "toggle": "desk_lamp.power"
          }
        ]
      }
    },
    {
      "forEach": {
        "in": "room:Study",
        "do": [
          {
            "notify": {
              "title": "{{%item}}"
            }
          }
        ]
      }
    },
    {
      "ask": {
        "title": "Lights?",
        "choices": [
          "On",
          "Off"
        ]
      }
    },
    {
      "if": [
        {
          "var": "%answer",
          "op": "==",
          "value": "On"
        }
      ],
      "then": [
        {
          "do": "hall_bulb.power",
          "params": {
            "value": true
          }
        }
      ]
    }
  ]
}
''';

const _plain = r'''
{
  "nodes": [
    {
      "id": "/when/0",
      "kind": "trigger",
      "path": "/when/0",
      "words": "When jade home turns on",
      "thing": "jade",
      "compiled": [
        "when_0"
      ]
    },
    {
      "id": "/when/1",
      "kind": "trigger",
      "path": "/when/1",
      "words": "At 18:00",
      "compiled": [
        "when_1"
      ]
    },
    {
      "id": "/onlyIf/0",
      "kind": "check",
      "path": "/onlyIf/0",
      "words": "room temp temp is above 28",
      "compiled": [
        "only_if"
      ]
    },
    {
      "id": "/onlyIf/0#end",
      "kind": "end",
      "words": "Stops here"
    },
    {
      "id": "/then/0",
      "kind": "step",
      "path": "/then/0",
      "words": "desk lamp power on",
      "thing": "desk_lamp",
      "compiled": [
        "then_0"
      ]
    },
    {
      "id": "/then/1",
      "kind": "decision",
      "path": "/then/1",
      "words": "if desk lamp state is on",
      "checks": [
        {
          "path": "/then/1/if/0",
          "words": "desk lamp state is on"
        }
      ],
      "compiled": [
        "then_1"
      ]
    },
    {
      "id": "/then/1/then/0",
      "kind": "step",
      "path": "/then/1/then/0",
      "words": "wait 3 s",
      "compiled": [
        "then_1_then_0"
      ]
    },
    {
      "id": "/then/1/else/0",
      "kind": "step",
      "path": "/then/1/else/0",
      "words": "notify \"Lamp is off\"",
      "compiled": [
        "then_1_else_0"
      ]
    },
    {
      "id": "/then/1#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "/then/2",
      "kind": "group",
      "path": "/then/2",
      "words": "hall bulb power on and wait 1 s then notify \"B\"",
      "group": "together",
      "compiled": [
        "then_2"
      ],
      "children": [
        "/then/2/together/0/0",
        "/then/2/together/1/0",
        "/then/2/together/1/1"
      ]
    },
    {
      "id": "/then/2/together/0/0",
      "kind": "step",
      "path": "/then/2/together/0/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_2_together_0_0"
      ]
    },
    {
      "id": "/then/2/together/1/0",
      "kind": "step",
      "path": "/then/2/together/1/0",
      "words": "wait 1 s",
      "compiled": [
        "then_2_together_1_0"
      ]
    },
    {
      "id": "/then/2/together/1/1",
      "kind": "step",
      "path": "/then/2/together/1/1",
      "words": "notify \"B\"",
      "compiled": [
        "then_2_together_1_1"
      ]
    },
    {
      "id": "/then/2#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "/then/3",
      "kind": "group",
      "path": "/then/3",
      "words": "try desk lamp wake, if that fails notify \"Failed\"",
      "group": "try",
      "children": [
        "/then/3/try/0"
      ]
    },
    {
      "id": "/then/3/try/0",
      "kind": "step",
      "path": "/then/3/try/0",
      "words": "desk lamp wake",
      "thing": "desk_lamp",
      "compiled": [
        "then_3_try_0"
      ]
    },
    {
      "id": "/then/3/otherwise/0",
      "kind": "step",
      "path": "/then/3/otherwise/0",
      "words": "notify \"Failed\"",
      "compiled": [
        "then_3_otherwise_0"
      ]
    },
    {
      "id": "/then/3#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "/then/4",
      "kind": "group",
      "path": "/then/4",
      "words": "repeat 3 times, every 3 s",
      "group": "repeat",
      "compiled": [
        "then_4"
      ],
      "children": [
        "/then/4/repeat/do/0"
      ]
    },
    {
      "id": "/then/4/repeat/do/0",
      "kind": "step",
      "path": "/then/4/repeat/do/0",
      "words": "toggle desk lamp power",
      "thing": "desk_lamp",
      "compiled": [
        "then_4_repeat_do_0"
      ]
    },
    {
      "id": "/then/4#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "/then/5",
      "kind": "group",
      "path": "/then/5",
      "words": "for each device in Study",
      "group": "forEach",
      "compiled": [
        "then_5"
      ],
      "children": [
        "/then/5/forEach/do/0"
      ]
    },
    {
      "id": "/then/5/forEach/do/0",
      "kind": "step",
      "path": "/then/5/forEach/do/0",
      "words": "notify \"the item\"",
      "compiled": [
        "then_5_for_each_do_0"
      ]
    },
    {
      "id": "/then/5#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "/then/6",
      "kind": "ask",
      "path": "/then/6",
      "words": "ask \"Lights?\" (On or Off)",
      "compiled": [
        "then_6"
      ]
    },
    {
      "id": "/then/7/then/0",
      "kind": "step",
      "path": "/then/7/then/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_7_then_0"
      ]
    },
    {
      "id": "/then/6#merge",
      "kind": "merge",
      "words": ""
    },
    {
      "id": "#end",
      "kind": "end",
      "words": "Done"
    }
  ],
  "edges": [
    {
      "from": "/when/0",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      }
    },
    {
      "from": "/when/1",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      }
    },
    {
      "from": "/onlyIf/0",
      "to": "/onlyIf/0#end",
      "label": "no",
      "insert": {
        "path": "/onlyIf/1",
        "as": "check"
      }
    },
    {
      "from": "/onlyIf/0",
      "to": "/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/0",
        "as": "step"
      }
    },
    {
      "from": "/then/0",
      "to": "/then/1",
      "insert": {
        "path": "/then/1",
        "as": "step"
      }
    },
    {
      "from": "/then/1",
      "to": "/then/1/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/1/then/0",
        "as": "step"
      }
    },
    {
      "from": "/then/1",
      "to": "/then/1/else/0",
      "label": "no",
      "insert": {
        "path": "/then/1/else/0",
        "as": "step"
      }
    },
    {
      "from": "/then/1/then/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/then/1",
        "as": "step"
      }
    },
    {
      "from": "/then/1/else/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/else/1",
        "as": "step"
      }
    },
    {
      "from": "/then/1#merge",
      "to": "/then/2",
      "insert": {
        "path": "/then/2",
        "as": "step"
      }
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/0/0",
      "insert": {
        "path": "/then/2/together/0/0",
        "as": "step"
      }
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/1/0",
      "insert": {
        "path": "/then/2/together/1/0",
        "as": "step"
      }
    },
    {
      "from": "/then/2/together/1/0",
      "to": "/then/2/together/1/1",
      "insert": {
        "path": "/then/2/together/1/1",
        "as": "step"
      }
    },
    {
      "from": "/then/2/together/0/0",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/0/1",
        "as": "step"
      }
    },
    {
      "from": "/then/2/together/1/1",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/1/2",
        "as": "step"
      }
    },
    {
      "from": "/then/2#merge",
      "to": "/then/3",
      "insert": {
        "path": "/then/3",
        "as": "step"
      }
    },
    {
      "from": "/then/3",
      "to": "/then/3/try/0",
      "insert": {
        "path": "/then/3/try/0",
        "as": "step"
      }
    },
    {
      "from": "/then/3",
      "to": "/then/3/otherwise/0",
      "label": "fails",
      "insert": {
        "path": "/then/3/otherwise/0",
        "as": "step"
      }
    },
    {
      "from": "/then/3/try/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/try/1",
        "as": "step"
      }
    },
    {
      "from": "/then/3/otherwise/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/otherwise/1",
        "as": "step"
      }
    },
    {
      "from": "/then/3#merge",
      "to": "/then/4",
      "insert": {
        "path": "/then/4",
        "as": "step"
      }
    },
    {
      "from": "/then/4",
      "to": "/then/4/repeat/do/0",
      "label": "each",
      "insert": {
        "path": "/then/4/repeat/do/0",
        "as": "step"
      }
    },
    {
      "from": "/then/4/repeat/do/0",
      "to": "/then/4#merge",
      "insert": {
        "path": "/then/4/repeat/do/1",
        "as": "step"
      }
    },
    {
      "from": "/then/4#merge",
      "to": "/then/5",
      "insert": {
        "path": "/then/5",
        "as": "step"
      }
    },
    {
      "from": "/then/5",
      "to": "/then/5/forEach/do/0",
      "label": "each",
      "insert": {
        "path": "/then/5/forEach/do/0",
        "as": "step"
      }
    },
    {
      "from": "/then/5/forEach/do/0",
      "to": "/then/5#merge",
      "insert": {
        "path": "/then/5/forEach/do/1",
        "as": "step"
      }
    },
    {
      "from": "/then/5#merge",
      "to": "/then/6",
      "insert": {
        "path": "/then/6",
        "as": "step"
      }
    },
    {
      "from": "/then/6",
      "to": "/then/7/then/0",
      "label": "On",
      "insert": {
        "path": "/then/7/then/0",
        "as": "step"
      }
    },
    {
      "from": "/then/7/then/0",
      "to": "/then/6#merge",
      "insert": {
        "path": "/then/7/then/1",
        "as": "step"
      }
    },
    {
      "from": "/then/6",
      "to": "/then/6#merge",
      "label": "Off",
      "insert": {
        "path": "/then/8",
        "as": "step"
      }
    },
    {
      "from": "/then/6#merge",
      "to": "#end",
      "insert": {
        "path": "/then/8",
        "as": "step"
      }
    }
  ],
  "source": "rule"
}
''';

const _run = r'''
{
  "nodes": [
    {
      "id": "/when/0",
      "kind": "trigger",
      "path": "/when/0",
      "words": "When jade home turns on",
      "thing": "jade",
      "compiled": [
        "when_0"
      ],
      "status": "ran"
    },
    {
      "id": "/when/1",
      "kind": "trigger",
      "path": "/when/1",
      "words": "At 18:00",
      "compiled": [
        "when_1"
      ],
      "status": "skipped"
    },
    {
      "id": "/onlyIf/0",
      "kind": "check",
      "path": "/onlyIf/0",
      "words": "room temp temp is above 28",
      "compiled": [
        "only_if"
      ],
      "status": "ran",
      "seen": 31
    },
    {
      "id": "/onlyIf/0#end",
      "kind": "end",
      "words": "Stops here",
      "status": "skipped"
    },
    {
      "id": "/then/0",
      "kind": "step",
      "path": "/then/0",
      "words": "desk lamp power on",
      "thing": "desk_lamp",
      "compiled": [
        "then_0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/1",
      "kind": "decision",
      "path": "/then/1",
      "words": "if desk lamp state is on",
      "checks": [
        {
          "path": "/then/1/if/0",
          "words": "desk lamp state is on"
        }
      ],
      "compiled": [
        "then_1"
      ],
      "status": "ran",
      "seen": false
    },
    {
      "id": "/then/1/then/0",
      "kind": "step",
      "path": "/then/1/then/0",
      "words": "wait 3 s",
      "compiled": [
        "then_1_then_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/1/else/0",
      "kind": "step",
      "path": "/then/1/else/0",
      "words": "notify \"Lamp is off\"",
      "compiled": [
        "then_1_else_0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/1#merge",
      "kind": "merge",
      "words": "",
      "status": "ran"
    },
    {
      "id": "/then/2",
      "kind": "group",
      "path": "/then/2",
      "words": "hall bulb power on and wait 1 s then notify \"B\"",
      "group": "together",
      "compiled": [
        "then_2"
      ],
      "children": [
        "/then/2/together/0/0",
        "/then/2/together/1/0",
        "/then/2/together/1/1"
      ],
      "status": "ran"
    },
    {
      "id": "/then/2/together/0/0",
      "kind": "step",
      "path": "/then/2/together/0/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_2_together_0_0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/2/together/1/0",
      "kind": "step",
      "path": "/then/2/together/1/0",
      "words": "wait 1 s",
      "compiled": [
        "then_2_together_1_0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/2/together/1/1",
      "kind": "step",
      "path": "/then/2/together/1/1",
      "words": "notify \"B\"",
      "compiled": [
        "then_2_together_1_1"
      ],
      "status": "ran"
    },
    {
      "id": "/then/2#merge",
      "kind": "merge",
      "words": "",
      "status": "ran"
    },
    {
      "id": "/then/3",
      "kind": "group",
      "path": "/then/3",
      "words": "try desk lamp wake, if that fails notify \"Failed\"",
      "group": "try",
      "children": [
        "/then/3/try/0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/3/try/0",
      "kind": "step",
      "path": "/then/3/try/0",
      "words": "desk lamp wake",
      "thing": "desk_lamp",
      "compiled": [
        "then_3_try_0"
      ],
      "status": "failed"
    },
    {
      "id": "/then/3/otherwise/0",
      "kind": "step",
      "path": "/then/3/otherwise/0",
      "words": "notify \"Failed\"",
      "compiled": [
        "then_3_otherwise_0"
      ],
      "status": "ran"
    },
    {
      "id": "/then/3#merge",
      "kind": "merge",
      "words": "",
      "status": "ran"
    },
    {
      "id": "/then/4",
      "kind": "group",
      "path": "/then/4",
      "words": "repeat 3 times, every 3 s",
      "group": "repeat",
      "compiled": [
        "then_4"
      ],
      "children": [
        "/then/4/repeat/do/0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/4/repeat/do/0",
      "kind": "step",
      "path": "/then/4/repeat/do/0",
      "words": "toggle desk lamp power",
      "thing": "desk_lamp",
      "compiled": [
        "then_4_repeat_do_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/4#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/5",
      "kind": "group",
      "path": "/then/5",
      "words": "for each device in Study",
      "group": "forEach",
      "compiled": [
        "then_5"
      ],
      "children": [
        "/then/5/forEach/do/0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/5/forEach/do/0",
      "kind": "step",
      "path": "/then/5/forEach/do/0",
      "words": "notify \"the item\"",
      "compiled": [
        "then_5_for_each_do_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/5#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/6",
      "kind": "ask",
      "path": "/then/6",
      "words": "ask \"Lights?\" (On or Off)",
      "compiled": [
        "then_6"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/7/then/0",
      "kind": "step",
      "path": "/then/7/then/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_7_then_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/6#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "#end",
      "kind": "end",
      "words": "Done",
      "status": "skipped"
    }
  ],
  "edges": [
    {
      "from": "/when/0",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      },
      "taken": true
    },
    {
      "from": "/when/1",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      },
      "taken": false
    },
    {
      "from": "/onlyIf/0",
      "to": "/onlyIf/0#end",
      "label": "no",
      "insert": {
        "path": "/onlyIf/1",
        "as": "check"
      },
      "taken": false
    },
    {
      "from": "/onlyIf/0",
      "to": "/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/0",
      "to": "/then/1",
      "insert": {
        "path": "/then/1",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/1",
      "to": "/then/1/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/1/then/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1",
      "to": "/then/1/else/0",
      "label": "no",
      "insert": {
        "path": "/then/1/else/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/1/then/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/then/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1/else/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/else/1",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/1#merge",
      "to": "/then/2",
      "insert": {
        "path": "/then/2",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/0/0",
      "insert": {
        "path": "/then/2/together/0/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/1/0",
      "insert": {
        "path": "/then/2/together/1/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2/together/1/0",
      "to": "/then/2/together/1/1",
      "insert": {
        "path": "/then/2/together/1/1",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2/together/0/0",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/0/1",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2/together/1/1",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/1/2",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/2#merge",
      "to": "/then/3",
      "insert": {
        "path": "/then/3",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/3",
      "to": "/then/3/try/0",
      "insert": {
        "path": "/then/3/try/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/3",
      "to": "/then/3/otherwise/0",
      "label": "fails",
      "insert": {
        "path": "/then/3/otherwise/0",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/3/try/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/try/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3/otherwise/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/otherwise/1",
        "as": "step"
      },
      "taken": true
    },
    {
      "from": "/then/3#merge",
      "to": "/then/4",
      "insert": {
        "path": "/then/4",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4",
      "to": "/then/4/repeat/do/0",
      "label": "each",
      "insert": {
        "path": "/then/4/repeat/do/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4/repeat/do/0",
      "to": "/then/4#merge",
      "insert": {
        "path": "/then/4/repeat/do/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4#merge",
      "to": "/then/5",
      "insert": {
        "path": "/then/5",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5",
      "to": "/then/5/forEach/do/0",
      "label": "each",
      "insert": {
        "path": "/then/5/forEach/do/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5/forEach/do/0",
      "to": "/then/5#merge",
      "insert": {
        "path": "/then/5/forEach/do/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5#merge",
      "to": "/then/6",
      "insert": {
        "path": "/then/6",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6",
      "to": "/then/7/then/0",
      "label": "On",
      "insert": {
        "path": "/then/7/then/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/7/then/0",
      "to": "/then/6#merge",
      "insert": {
        "path": "/then/7/then/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6",
      "to": "/then/6#merge",
      "label": "Off",
      "insert": {
        "path": "/then/8",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6#merge",
      "to": "#end",
      "insert": {
        "path": "/then/8",
        "as": "step"
      },
      "taken": false
    }
  ],
  "source": "rule",
  "run": {
    "run": "r1",
    "outcome": "completed",
    "startedAt": "2026-11-13T08:00:00Z",
    "dryRun": false
  }
}
''';

const _skip = r'''
{
  "nodes": [
    {
      "id": "/when/0",
      "kind": "trigger",
      "path": "/when/0",
      "words": "When jade home turns on",
      "thing": "jade",
      "compiled": [
        "when_0"
      ],
      "status": "ran"
    },
    {
      "id": "/when/1",
      "kind": "trigger",
      "path": "/when/1",
      "words": "At 18:00",
      "compiled": [
        "when_1"
      ],
      "status": "skipped"
    },
    {
      "id": "/onlyIf/0",
      "kind": "check",
      "path": "/onlyIf/0",
      "words": "room temp temp is above 28",
      "compiled": [
        "only_if"
      ],
      "status": "ran",
      "seen": 24
    },
    {
      "id": "/onlyIf/0#end",
      "kind": "end",
      "words": "Stops here",
      "status": "ran"
    },
    {
      "id": "/then/0",
      "kind": "step",
      "path": "/then/0",
      "words": "desk lamp power on",
      "thing": "desk_lamp",
      "compiled": [
        "then_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/1",
      "kind": "decision",
      "path": "/then/1",
      "words": "if desk lamp state is on",
      "checks": [
        {
          "path": "/then/1/if/0",
          "words": "desk lamp state is on"
        }
      ],
      "compiled": [
        "then_1"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/1/then/0",
      "kind": "step",
      "path": "/then/1/then/0",
      "words": "wait 3 s",
      "compiled": [
        "then_1_then_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/1/else/0",
      "kind": "step",
      "path": "/then/1/else/0",
      "words": "notify \"Lamp is off\"",
      "compiled": [
        "then_1_else_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/1#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/2",
      "kind": "group",
      "path": "/then/2",
      "words": "hall bulb power on and wait 1 s then notify \"B\"",
      "group": "together",
      "compiled": [
        "then_2"
      ],
      "children": [
        "/then/2/together/0/0",
        "/then/2/together/1/0",
        "/then/2/together/1/1"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/2/together/0/0",
      "kind": "step",
      "path": "/then/2/together/0/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_2_together_0_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/2/together/1/0",
      "kind": "step",
      "path": "/then/2/together/1/0",
      "words": "wait 1 s",
      "compiled": [
        "then_2_together_1_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/2/together/1/1",
      "kind": "step",
      "path": "/then/2/together/1/1",
      "words": "notify \"B\"",
      "compiled": [
        "then_2_together_1_1"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/2#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/3",
      "kind": "group",
      "path": "/then/3",
      "words": "try desk lamp wake, if that fails notify \"Failed\"",
      "group": "try",
      "children": [
        "/then/3/try/0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/3/try/0",
      "kind": "step",
      "path": "/then/3/try/0",
      "words": "desk lamp wake",
      "thing": "desk_lamp",
      "compiled": [
        "then_3_try_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/3/otherwise/0",
      "kind": "step",
      "path": "/then/3/otherwise/0",
      "words": "notify \"Failed\"",
      "compiled": [
        "then_3_otherwise_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/3#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/4",
      "kind": "group",
      "path": "/then/4",
      "words": "repeat 3 times, every 3 s",
      "group": "repeat",
      "compiled": [
        "then_4"
      ],
      "children": [
        "/then/4/repeat/do/0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/4/repeat/do/0",
      "kind": "step",
      "path": "/then/4/repeat/do/0",
      "words": "toggle desk lamp power",
      "thing": "desk_lamp",
      "compiled": [
        "then_4_repeat_do_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/4#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/5",
      "kind": "group",
      "path": "/then/5",
      "words": "for each device in Study",
      "group": "forEach",
      "compiled": [
        "then_5"
      ],
      "children": [
        "/then/5/forEach/do/0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/5/forEach/do/0",
      "kind": "step",
      "path": "/then/5/forEach/do/0",
      "words": "notify \"the item\"",
      "compiled": [
        "then_5_for_each_do_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/5#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "/then/6",
      "kind": "ask",
      "path": "/then/6",
      "words": "ask \"Lights?\" (On or Off)",
      "compiled": [
        "then_6"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/7/then/0",
      "kind": "step",
      "path": "/then/7/then/0",
      "words": "hall bulb power on",
      "thing": "hall_bulb",
      "compiled": [
        "then_7_then_0"
      ],
      "status": "skipped"
    },
    {
      "id": "/then/6#merge",
      "kind": "merge",
      "words": "",
      "status": "skipped"
    },
    {
      "id": "#end",
      "kind": "end",
      "words": "Done",
      "status": "skipped"
    }
  ],
  "edges": [
    {
      "from": "/when/0",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      },
      "taken": true
    },
    {
      "from": "/when/1",
      "to": "/onlyIf/0",
      "insert": {
        "path": "/onlyIf/0",
        "as": "check"
      },
      "taken": false
    },
    {
      "from": "/onlyIf/0",
      "to": "/onlyIf/0#end",
      "label": "no",
      "insert": {
        "path": "/onlyIf/1",
        "as": "check"
      },
      "taken": true
    },
    {
      "from": "/onlyIf/0",
      "to": "/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/0",
      "to": "/then/1",
      "insert": {
        "path": "/then/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1",
      "to": "/then/1/then/0",
      "label": "yes",
      "insert": {
        "path": "/then/1/then/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1",
      "to": "/then/1/else/0",
      "label": "no",
      "insert": {
        "path": "/then/1/else/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1/then/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/then/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1/else/0",
      "to": "/then/1#merge",
      "insert": {
        "path": "/then/1/else/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/1#merge",
      "to": "/then/2",
      "insert": {
        "path": "/then/2",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/0/0",
      "insert": {
        "path": "/then/2/together/0/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2",
      "to": "/then/2/together/1/0",
      "insert": {
        "path": "/then/2/together/1/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2/together/1/0",
      "to": "/then/2/together/1/1",
      "insert": {
        "path": "/then/2/together/1/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2/together/0/0",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/0/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2/together/1/1",
      "to": "/then/2#merge",
      "insert": {
        "path": "/then/2/together/1/2",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/2#merge",
      "to": "/then/3",
      "insert": {
        "path": "/then/3",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3",
      "to": "/then/3/try/0",
      "insert": {
        "path": "/then/3/try/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3",
      "to": "/then/3/otherwise/0",
      "label": "fails",
      "insert": {
        "path": "/then/3/otherwise/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3/try/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/try/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3/otherwise/0",
      "to": "/then/3#merge",
      "insert": {
        "path": "/then/3/otherwise/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/3#merge",
      "to": "/then/4",
      "insert": {
        "path": "/then/4",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4",
      "to": "/then/4/repeat/do/0",
      "label": "each",
      "insert": {
        "path": "/then/4/repeat/do/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4/repeat/do/0",
      "to": "/then/4#merge",
      "insert": {
        "path": "/then/4/repeat/do/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/4#merge",
      "to": "/then/5",
      "insert": {
        "path": "/then/5",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5",
      "to": "/then/5/forEach/do/0",
      "label": "each",
      "insert": {
        "path": "/then/5/forEach/do/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5/forEach/do/0",
      "to": "/then/5#merge",
      "insert": {
        "path": "/then/5/forEach/do/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/5#merge",
      "to": "/then/6",
      "insert": {
        "path": "/then/6",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6",
      "to": "/then/7/then/0",
      "label": "On",
      "insert": {
        "path": "/then/7/then/0",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/7/then/0",
      "to": "/then/6#merge",
      "insert": {
        "path": "/then/7/then/1",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6",
      "to": "/then/6#merge",
      "label": "Off",
      "insert": {
        "path": "/then/8",
        "as": "step"
      },
      "taken": false
    },
    {
      "from": "/then/6#merge",
      "to": "#end",
      "insert": {
        "path": "/then/8",
        "as": "step"
      },
      "taken": false
    }
  ],
  "source": "rule",
  "skip": {
    "at": "2026-11-13T09:00:00Z",
    "flow": "every_part",
    "trigger": "when_0",
    "kind": "condition",
    "stop": {
      "node": "only_if",
      "actual": 24
    },
    "reason": "room temp temp was 24, not above 28"
  }
}
''';
