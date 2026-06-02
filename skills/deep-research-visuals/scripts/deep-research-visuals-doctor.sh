#!/bin/zsh

set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SKILLS_ROOT="$(cd "${SKILL_ROOT}/.." && pwd -P)"
NATURE_FIGURE_SKILL="${NATURE_FIGURE_SKILL_ROOT:-${SKILLS_ROOT}/nature-figure}"
VISUAL_ROOT="${RESEARCH_VISUAL_TOOLS_ROOT:-${HOME}/.local/share/research-visual-tools}"
PYTHON_VENV="${VISUAL_ROOT}/venv/bin/python"
BIOICONS_ROOT="${VISUAL_ROOT}/bioicons"

cmd_status() {
  local name="$1"
  local version_cmd="$2"
  local cmd_path
  cmd_path="$(command -v "${name}" 2>/dev/null || true)"
  if [[ -z "${cmd_path}" ]]; then
    jq -nc --arg name "${name}" '{name:$name, available:false}'
    return
  fi
  local version
  version="$(eval "${version_cmd}" 2>&1 | head -n 1 | tr -d '\r')"
  jq -nc --arg name "${name}" --arg path "${cmd_path}" --arg version "${version}" '{name:$name, available:true, path:$path, version:$version}'
}

python_status='{"available":false,"packages":{}}'
if [[ -x "${PYTHON_VENV}" ]]; then
  python_status="$("${PYTHON_VENV}" - <<'PY'
import json
mods = ["diagrams", "schemdraw", "matplotlib", "seaborn", "numpy", "pandas", "statsmodels"]
out = {"available": True, "packages": {}}
for name in mods:
    try:
        mod = __import__(name)
        out["packages"][name] = getattr(mod, "__version__", "unknown")
    except Exception as exc:
        out["packages"][name] = {"error": str(exc)}
print(json.dumps(out))
PY
)"
fi

bioicons_count=0
if [[ -d "${BIOICONS_ROOT}" ]]; then
  bioicons_count="$(find "${BIOICONS_ROOT}" -type f -name '*.svg' | wc -l | tr -d ' ')"
fi

nature_figure_available="false"
if [[ -f "${NATURE_FIGURE_SKILL}/SKILL.md" && -f "${NATURE_FIGURE_SKILL}/manifest.yaml" ]]; then
  nature_figure_available="true"
fi

jq -n \
  --arg skill_root "${SKILL_ROOT}" \
  --arg nature_figure_root "${NATURE_FIGURE_SKILL}" \
  --argjson nature_figure_available "${nature_figure_available}" \
  --argjson drawio "$(cmd_status drawio 'drawio --version')" \
  --argjson mermaid "$(cmd_status mmdc 'mmdc --version')" \
  --argjson plantuml "$(cmd_status plantuml 'plantuml -version')" \
  --argjson graphviz "$(cmd_status dot 'dot -V')" \
  --argjson manim "$(cmd_status manim 'manim --version')" \
  --argjson python_tools "${python_status}" \
  --arg bioicons_root "${BIOICONS_ROOT}" \
  --argjson bioicons_count "${bioicons_count}" \
  '
  def pkg_ready($name): (($python_tools.packages[$name] | type) == "string");
  {
    skill_root: $skill_root,
    status: (
      if (
        $nature_figure_available
        and $drawio.available
        and $mermaid.available
        and $plantuml.available
        and $graphviz.available
        and $manim.available
        and $python_tools.available
        and pkg_ready("diagrams")
        and pkg_ready("schemdraw")
        and pkg_ready("matplotlib")
        and pkg_ready("seaborn")
        and pkg_ready("numpy")
        and pkg_ready("pandas")
        and pkg_ready("statsmodels")
        and ($bioicons_count > 0)
      ) then "ready" else "incomplete" end
    ),
    tools: {
      deep_research_visuals: {available: true, root: $skill_root},
      nature_figure: {available: $nature_figure_available, root: $nature_figure_root},
      drawio: $drawio,
      mermaid_cli: $mermaid,
      plantuml: $plantuml,
      graphviz: $graphviz,
      manim: $manim,
      python_tools: $python_tools,
      bioicons: {available: ($bioicons_count > 0), root: $bioicons_root, svg_count: $bioicons_count}
    }
  }'
