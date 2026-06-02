---
name: deep-research-visuals
description: "Use for Deep Research final-delivery figures, diagrams, PPT visuals, scientific schematics, semiconductor/AI roadmaps, evidence matrices, and any requested visual asset. Integrates source-first figure reuse, draw.io/Mermaid/PlantUML/Graphviz/Manim/Diagrams/Schemdraw/Bioicons, and Nature-style publication figures through nature-figure."
---

# Deep Research Visuals

This skill is the visual routing layer for the Deep Research project. It replaces ad-hoc "figure-ready" prose with real, readable, source-traceable visual assets.

## Core Policy

1. Source-first: inspect cited papers, PDFs, official pages, and web sources for reusable figures before drawing.
2. If a source figure is suitable and legally usable, save it with source URL, title, citation, and license/usage note.
3. If a source figure is absent, restricted, low-resolution, or not aligned with the argument, redraw an original figure.
4. Never ship only a figure-ready paragraph when the user asked for a figure, diagram, flowchart, or PPT visual.
5. Prefer PNG as the stable display artifact for Obsidian/PDF/PPT. Keep SVG/PDF/TIFF/script/source data beside it when useful.
6. Do not use draw.io `foreignObject` SVG as the only rendered artifact.

## Composition, Not Either-Or

Read `references/tool-routing.md` when deciding tools.

This skill is an orchestrator. Do not treat tools as mutually exclusive. Combine them when the figure benefits from the intersection:

- `nature-figure` supplies the figure contract, scientific argument, panel hierarchy, restrained palette, typography, and publication/export discipline.
- Python/matplotlib/seaborn implements quantitative panels, matrices, roadmaps, radar/forest/interval charts, and final multi-panel assembly.
- draw.io supplies manually polished strategy/system panels that can be embedded into a larger Nature-style page.
- Mermaid/PlantUML/Graphviz produce reproducible structure, timeline, architecture, and evidence-map panels that can be rendered and then included as one panel in a composed figure.
- Manim/schemdraw/Bioicons produce specialist scientific, mathematical, electronic, or domain-icon subpanels.

The default question is not "A or B?" It is "which tool owns which panel, and what final composition makes the argument clearest?"

Default ownership choices:

- `nature-figure`: scientific, quantitative, evidence-bearing, roadmap, heatmap, radar, matrix, forest/interval, or multi-panel report/PPT figures. For Deep Research automation, use backend `python` unless the user explicitly asks for R.
- `drawio`: system frameworks, layered architecture, strategy maps, and diagrams that need manual executive polish.
- `mermaid`: simple flowcharts, timelines, sequence charts, and stage pipelines.
- `plantuml`: UML/C4/component/deployment diagrams.
- `graphviz`: DAGs, evidence maps, dependency/causal graphs, knowledge graphs.
- `manim`: mathematical or scientific concept frames.
- `schemdraw`: circuit/electronic schematics.
- `bioicons`: biology/chemistry icon support.
- `diagrams`: cloud/system infrastructure.

## Nature-Figure Integration

For deep-research final delivery, the backend choice is explicit: `backend=python`. This avoids blocking a long-running final-delivery agent with "Python or R?" while still using the `nature-figure` contract.

Use the project visual Python runtime for all Python-backed rendering unless the caller explicitly overrides it:

```bash
${RESEARCH_VISUAL_TOOLS_ROOT:-${HOME}/.local/share/research-visual-tools}/venv/bin/python
```

Do not fall back to system `python3` for matplotlib/nature-style rendering when the project venv exists. If the venv is missing or lacks packages, run the doctor and report the blocker instead of silently changing renderer.

Use `nature-figure` patterns for:

- technology roadmaps and density-equivalent curves
- evidence-strength bars or interval plots
- boundary/risk matrices and heatmaps
- business-fit radar or polar summaries
- multi-panel scientific concept pages
- semiconductor, AI accelerator, packaging, and platform comparison figures

Each nature-style generated figure should keep:

- editable SVG
- PDF
- stable PNG display artifact
- script under `visual_assets/scripts/`
- source data under `visual_assets/data/` when quantitative

When another tool produces a subpanel, save that subpanel as SVG/PNG/PDF and record it in the same figure entry. The final assembled figure can still be `deep-research-visuals:nature-figure+drawio`, `deep-research-visuals:nature-figure+graphviz`, or another explicit combination.

## Required Output

`visual_asset_plan.json` must include one entry per figure:

```json
{
  "visual_asset_policy_version": "2026-06-01",
  "source_first": true,
  "figures": [
    {
      "figure_id": "F1",
      "title": "",
      "purpose": "",
      "figure_contract": {
        "core_conclusion": "",
        "archetype": "quantitative grid | schematic-led composite | image plate + quant | asymmetric mixed-modality figure | system diagram",
        "evidence_chain": []
      },
      "source_search": {
        "performed": true,
        "queries": [],
        "candidate_sources": []
      },
      "decision": "reuse_source_figure | draw_original",
      "tool": "deep-research-visuals:nature-figure | drawio | mermaid | plantuml | graphviz | manim | diagrams | schemdraw | bioicons",
      "toolchain": ["nature-figure", "matplotlib"],
      "panel_sources": [
        {
          "panel_id": "a",
          "tool": "nature-figure",
          "artifact": "visual_assets/F1_panel_a.svg",
          "role": "hero quantitative panel"
        }
      ],
      "backend": "python | r | drawio | mermaid | plantuml | graphviz | manim | diagrams | schemdraw | source",
      "editable_artifact": "visual_assets/scripts/F1.py",
      "rendered_artifact": "visual_assets/F1.png",
      "svg_artifact": "visual_assets/F1.svg",
      "pdf_artifact": "visual_assets/F1.pdf",
      "source_url": "",
      "license_or_usage_note": "",
      "qa_status": "opened_or_rasterized",
      "status": "reused_source_figure | drawn_rendered"
    }
  ]
}
```

`visual_asset_log.md` must explain source inspection, reuse/redraw decisions, tool choice, QA result, and the final display artifact referenced by `final_delivery.md` / `ppt_outline.md`.

## Huawei Tao Law Defaults

For `huawei-tao-law-20250607`-style research, prefer:

- source timeline: `nature-figure` if evidence-tiered, otherwise Mermaid
- tau concept frame: `nature-figure` or Manim
- density-equivalent vs lithography-node comparison: `nature-figure`
- applicability boundary matrix: `nature-figure`
- industry ecosystem: draw.io or Graphviz
- Lenovo business mapping / AI PC route: `nature-figure` when quantitative, draw.io only when it is a strategy architecture map

## Verification

Run:

```bash
zsh skills/deep-research-visuals/scripts/deep-research-visuals-doctor.sh
```

Before marking final delivery ready, rendered assets must be nonblank, readable, and referenced by the final Markdown/PPT outline.
