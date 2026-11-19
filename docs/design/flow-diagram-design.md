# Automation Diagram

> Status: approved, 2026-11-13. Building.

## Problem

An automation reads as a sentence, which is quick for "when X, then Y" and hard for anything with branches: an if with an otherwise, steps that run together, a try with a fallback, a repeat, or Ask with three answers. People want to see the whole thing as a decision graph, watch which way it went on a real run, and change a condition or a step right there.

## Requirements

1. Every automation can be shown as a diagram: triggers at the top, checks as decisions with a yes and a no way out, steps below, and branches side by side.
2. The diagram and the sentence are two views of one automation. A change made in one shows in the other at once, and both save the same rule.
3. Tapping a node edits that part with the same pickers the sentence uses. A "+" on any line adds a step or a check there. A node can be moved, copied or removed.
4. The last run, a test run or a live run lights up the path it took: which trigger fired, which way each decision went with the value it saw, which steps ran, failed or were skipped. A skipped run shows the check that said no.
5. It works on a phone held in one hand: it lays itself out, scrolls vertically, and zooms with two fingers.
6. Flows that came in as raw graphs (from an agent or `omni flow`) show too, read-only.

## Options

| | A. Laid out from the rule [Approved] | B. A free canvas with dragged wires [Rejected] |
| --- | --- | --- |
| Layout | Automatic, top to bottom, the same every time | Placed by hand, stored per node |
| Editing on a phone | Tap and "+" targets sized for a thumb | Dragging small ports and wires |
| What it edits | The rule, so the sentence stays in step | The compiled graph, which a rule cannot be rebuilt from |
| Dependency | None, Flutter painting and `InteractiveViewer` | `vyuh_node_flow`, a 0.x API that changed 12 times in a year |

A rule is structured: every if, together, try and repeat is a block with one way in and one way out. A layout computed from that structure is always tidy, so nothing has to be placed by hand. Option B suits free-form graphs, which OmniFlow keeps for agents and the CLI.

## How it works

1. The engine turns an automation into a diagram model: `automation.diagram {id}` or `{spec}` for an unsaved rule. Each node carries its place in the rule (`path`), so an edit on a node is an edit at that path. The engine owns this projection, as it owns the sentence.
2. The app lays the model out and paints it, and opens the existing pickers when a node is tapped. Edits go through the same rule state the sentence editor uses, so both views stay one model.
3. For runs, `automation.diagram` with `run` (a run id from the log), or the dry run's trace, or a new live `run.node {run, flow, node, status, seen?}` event the executor sends as each node finishes, mark each node `ran`, `failed`, `skipped` or `waiting`, and each decision with the branch taken and the value seen. Skips from `automation.skips` mark the check that said no.

### The diagram model

`automation.diagram` returns `{nodes, edges, source}`:

- **Node:** `{id, kind, path, words, icon?, color?, risk?, status?, seen?}`.
  - `kind` is one of `trigger`, `check`, `decision`, `step`, `ask`, `wait`, `group`, `merge`, `end`.
  - `path` is a JSON pointer into the rule, such as `/when/0`, `/onlyIf/1` or `/then/2/if/0`. A raw graph flow carries no path.
  - `words` is the same plain wording the sentence uses, for that part.
  - `status` and `seen` are present only when a run is asked for.
- **Edge:** `{from, to, label?, taken?}`, where `label` is one of `yes`, `no`, `otherwise`, `fails`, `each`, `then` or an Ask answer, and `taken` is set for a run.
- **Group:** a `group` node (together, try, repeat, repeat with each) holds `children: [node ids]`, so the app can draw a box around them.
- **Insert points:** each edge carries `insert: {path, as: step | check}`, where a "+" on that line adds a new item.

## The app

- **Sentence and Diagram views.** A switch at the top of the rule editor, remembered per person.
- **Nodes:**
  - Triggers are pills.
  - Checks and ifs are diamonds with a yes line and a no line.
  - Steps are cards with the device icon and colour.
  - Ask has one line per answer.
  - Groups are rounded boxes labelled "At the same time", "Try, if it fails" or "Repeat 3 times".
- **Editing:** tap opens the picker for that part. Long press gives Move up, Move down, Copy and Remove. A "+" on a line adds there. Undo works as it does in the sentence view.
- **Runs:** on the automation page, the diagram shows the last run with its path lit and the values at each decision. While a run is live, it animates node by node. Test run and Try as if open the same view.
- **Gestures:** vertical scroll, pinch to zoom, double tap to fit. Screen readers read the nodes in order with their words and status.
