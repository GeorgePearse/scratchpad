# Scratchpad

A blank, endless iPad canvas for Apple Pencil, with a visual model watching it. You sketch boxes, arrows and
handwriting; each time the Pencil lifts, a model looks at the canvas and edits the diagram: rough
shapes become clean ones, handwriting becomes labels, a scribble through something deletes it.

There is no toolbox. Ink is how you talk to the model.

## Running it

Open `Scratchpad.xcodeproj` in Xcode 27 or later.

- **On an iPad:** select the Scratchpad target, set your team under Signing & Capabilities, pick the
  iPad as the destination and run. Then tap the gear and paste an Anthropic API key.
- **In the simulator:** it runs as is, and the mouse draws.

If something misbehaves on the device, launch with `-trace YES` to print every touch and loop event:
`xcrun devicectl device process launch --device <id> --console com.georgepearse.scratchpad -- -trace YES`

To see the whole loop without a Pencil or a key, add `-demo YES` to the scheme's launch arguments.
That plays a short scripted session against a canned model.

## Using it

| Input | What it does |
| --- | --- |
| Pencil | Draws ink. The model takes a look half a second after you lift it. |
| Finger | Draws too, by default. Turn "Draw with a finger" off in settings and a finger drags clean shapes instead, with their connectors following. |
| Eraser | Rubs out ink, and any shape outline or connector it crosses. |
| Pinch, two-finger drag | Zooms (10% to 500%) and pans. With finger drawing off, one finger pans. |
| Arrows-in button | Fits everything on the pad into view. |
| Pencil double-tap | Switches between pen and eraser. |
| Sparkles button | Turns the model on and off, and shows how long the last pass took. |

Undo steps back through your strokes and the model's edits alike.

Settings has the model (Haiku 5.5 by default, because it is the fastest), the effort level, how long
to wait after a stroke, and standing instructions that are sent with every pass.

## How it works

The canvas is two layers: a clean diagram (nodes and edges, drawn with Core Graphics) under live
PencilKit ink.

1. **Trigger.** `ModelLoop` runs a pass only after the user changes something, once the Pencil has
   been up for the settle time. One pass is in flight at a time; changes made during it trigger the
   next one. An idle canvas makes no requests.
2. **Snapshot.** The part of the canvas on screen is rendered to a PNG (1024 px on the long edge,
   always black on white), so the model works on what you are looking at, at the zoom you chose.
   In the model's copy each clean element has its id printed beside it in magenta, so the model can
   refer to it. The same elements go along as JSON.
3. **Model.** The model replies with a list of ops: `node` and `edge` create or replace, `delete`
   removes, `erase` clears the ink in a rectangle.
4. **Merge.** The reply is a second or two old when it lands, so it is merged three ways against the
   snapshot it answered. Anything you changed in the meantime wins, and only ink the model actually
   saw can be erased.

### Plugging in a different model

A model is anything that conforms to `DiagramModel`:

```swift
public protocol DiagramModel: Sendable {
    func edit(_ input: ModelInput) async throws -> ModelOutput
}
```

It gets the PNG, its pixel size and the current diagram, and returns ops in the image's pixel
coordinates. It keeps no state between passes, so a hosted VLM, a local detector or a rules engine
all fit. `ClaudeModel` is the one implementation today; `PadStore.modelOverride` swaps in another.

## Layout

```
Scratchpad/          The iPad app: canvas, renderer, controls, settings
ScratchKit/          Swift package with everything that isn't UI
  Diagram, EditOp      the data model and the op vocabulary
  Merge                three-way merge and ink erasure rules
  ModelLoop            when a pass runs
  Prompt, ClaudeModel  the prompt, reply schema and Messages API client
  padmodel             command-line tool: one pass over a PNG
ScratchpadUITests/   Tests that draw on the real canvas
Examples/            A script that builds a large pad (an RF-DETR paper explainer) as JSON
```

## Testing

```sh
cd ScratchKit && swift test          # merge, geometry, client and loop logic, on the Mac
```

`⌘U` in Xcode runs the UI tests, which draw real strokes and drag shapes in the iPad simulator
against a canned model, so they need no API key.

To try a prompt or a model against a saved canvas without the iPad:

```sh
cd ScratchKit
ANTHROPIC_API_KEY=... swift run padmodel canvas.png --model claude-sonnet-5-5
```

A demo run saves the snapshots it sent to the app's Documents folder as `pass-N.png`, which are
ready-made inputs for this.

## Limits

- The canvas is large rather than truly infinite: 20,000 points square, about fifteen screens each way.
- The model only sees what is on screen. Zoomed far out, small ink becomes too small for it to read.
- Connectors join two shapes; there are no free-floating arrows.
- The API key is stored in the device keychain and requests go straight from the iPad to Anthropic.
  That suits a personal tool, not something you would ship to other people.
