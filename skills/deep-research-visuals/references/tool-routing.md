# Deep Research Visual Tool Composition

## Composition Principle

Use tools as panel owners, not as mutually exclusive alternatives. A strong deep-research visual often has:

- one `nature-figure` hero panel that carries the core scientific or business conclusion
- one quantitative Python/matplotlib panel for evidence
- one draw.io or Graphviz panel for structure/causality
- one Mermaid/PlantUML panel for process or architecture when needed
- one specialist Manim/schemdraw/Bioicons panel when the domain requires it

The final artifact should look like one coherent figure. Match typography, labels, palette, margins, and panel letters across subpanels.

## Tool Ownership Table

| Need | Panel Owner | Common Combinations |
|---|---|---|
| Nature-style scientific multi-panel figure | `nature-figure` with Python backend | Can embed draw.io/Graphviz/Mermaid rendered subpanels. |
| Quantitative bars, trends, intervals, heatmaps, radar, matrices | Python/matplotlib under `nature-figure` contract | Combine with source figure crops or draw.io schematic panel. |
| Semiconductor/AI roadmap | Python/matplotlib under `nature-figure` contract | Add Graphviz dependency map or draw.io architecture inset. |
| Applicability/boundary/risk matrix | Python/matplotlib heatmap/table hybrid | Combine with a draw.io quadrant explanation if needed. |
| System framework / executive architecture | `drawio` | Wrap in Nature-style panel frame and labels when part of final figure. |
| Simple flow/timeline/stage process | `mermaid` | Use as a subpanel in a larger Nature-style page if the figure is evidence-bearing. |
| UML/C4/component/deployment | `plantuml` | Use as architecture subpanel; avoid using it for quantitative evidence. |
| Evidence map / dependency DAG / causal graph | `graphviz` | Combine with quantitative evidence-strength panel. |
| Mathematical/scientific concept frame | `manim` or Python schematic | Use Manim for geometry/math; assemble final page with Python if multi-panel. |
| Circuit/electronic schematic | `schemdraw` | Use as a specialist subpanel, not the whole final page when business evidence is needed. |
| Biology/chemistry schematic | `bioicons` plus Python/draw.io | Use icons as assets inside composed panels. |

## Deep Research Default

When no explicit user backend is provided, Deep Research final delivery should set `backend=python` for `nature-figure` figures. This is a project-level routing decision, not a user-facing question.

Use `drawio` only for the panel where manual architecture/strategy layout matters. Do not use draw.io as a substitute for quantitative scientific panels; embed it as a subpanel when both are needed.

## Composition Patterns

1. `nature-figure + matplotlib`: all panels are quantitative or matrix/roadmap based.
2. `nature-figure + drawio`: one hero data panel plus one polished system/strategy diagram.
3. `nature-figure + graphviz`: evidence-strength panel plus causal/dependency graph.
4. `nature-figure + mermaid`: roadmap/timeline panel plus process flow.
5. `nature-figure + schemdraw`: quantitative electronics/packaging comparison plus circuit/schematic inset.
6. `source figure + nature-figure redraw`: preserve source claim/citation, redraw a cleaner original panel for delivery.

## Quality Rules

- A figure must state the conclusion it supports.
- Each panel must add unique evidence.
- Direct labels are preferred over legends when they reduce eye travel.
- Use one restrained palette per figure.
- Keep final display PNG readable at report size.
- Keep SVG text editable when using Python/matplotlib.
- Record source data and rendering script for every quantitative figure.
- Record `toolchain` and `panel_sources` in `visual_asset_plan.json` whenever more than one tool contributes.
