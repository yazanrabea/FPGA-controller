#!/usr/bin/env bash
# Shared helpers for scripts/run_phase*.sh -- sourced, not run directly.
#
# Picks a simulator so the same scripts work on the macOS laptops (Homebrew
# Icarus Verilog) and on the Windows lab PC (Vivado 2022.1 xsim, Git Bash):
#   1. Icarus (iverilog/vvp) on PATH, under /opt/homebrew, or C:/iverilog/bin (Windows installer)
#   2. otherwise Vivado xsim (xvlog/xelab/xsim) on PATH or under C:/Xilinx/Vivado/2022.1
# Force one with SIM=icarus or SIM=xsim.
#
# Usage inside a script:
#   source "$(dirname "$0")/sim_lib.sh"
#   sim_run <tb_top_module> <source files...>
#   PYTHON=$(sim_python)      # python3 if it can import yaml, else python

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

_find() {   # _find <name> <fallback dir...>: print the first existing executable
    local name=$1; shift
    command -v "$name" 2>/dev/null && return
    local d
    for d in "$@"; do
        [ -f "$d/$name" ] && { echo "$d/$name"; return; }
    done
}

if [ -z "${SIM:-}" ]; then
    if [ -n "$(_find iverilog /opt/homebrew/bin /c/iverilog/bin)" ]; then SIM=icarus
    elif [ -n "$(_find xvlog.bat /c/Xilinx/Vivado/2022.1/bin)$(_find xvlog /c/Xilinx/Vivado/2022.1/bin /tools/Xilinx/Vivado/2022.1/bin)" ]; then SIM=xsim
    else echo "ERROR: neither Icarus Verilog nor Vivado xsim found (see CLAUDE.md §4)" >&2; exit 1
    fi
fi
echo "Simulator: $SIM"

# On Windows (Git Bash) Vivado's tools are .bat files that need native paths.
_is_windows() { [ -n "$(_find cygpath)" ]; }
_native() { if _is_windows; then cygpath -w "$1"; else echo "$1"; fi; }

_xsim_tool() {   # _xsim_tool <xvlog|xelab|xsim> args...
    local t=$1; shift
    if _is_windows; then
        local bat
        bat=$(_find "$t.bat" /c/Xilinx/Vivado/2022.1/bin)
        cmd //c "$(cygpath -w "$bat")" "$@"
    else
        "$(_find "$t" /tools/Xilinx/Vivado/2022.1/bin)" "$@"
    fi
}

sim_run() {
    local top=$1; shift
    if [ "$SIM" = icarus ]; then
        "$(_find iverilog /opt/homebrew/bin /c/iverilog/bin)" -g2012 -o "$WORK/$top.vvp" "$@"
        "$(_find vvp /opt/homebrew/bin /c/iverilog/bin)" "$WORK/$top.vvp"
    else
        local d="$WORK/$top" f srcs=()
        mkdir -p "$d"
        for f in "$@"; do srcs+=("$(_native "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")"); done
        # xsim writes its scratch dirs into the cwd, so run inside $d. Output is
        # filtered to the testbench's own lines (plus any tool ERROR); the full
        # logs are printed only if a step fails.
        ( cd "$d" && _xsim_tool xvlog -sv "${srcs[@]}" > xvlog.log 2>&1 ) \
            || { cat "$d/xvlog.log"; return 1; }
        ( cd "$d" && _xsim_tool xelab -debug off -s snap "$top" > xelab.log 2>&1 ) \
            || { cat "$d/xelab.log"; return 1; }
        ( cd "$d" && _xsim_tool xsim snap -R > xsim.log 2>&1 ) \
            || { cat "$d/xsim.log"; return 1; }
        grep -v -E '^(Vivado Simulator|Copyright|Time resolution|source |# |INFO:|\$finish called|exit$|run -all|quit$)' "$d/xsim.log" \
            | sed '/^[[:space:]]*$/d'
    fi
}

sim_python() {   # the interpreter that has the tools/requirements.txt packages
    if python3 -c 'import yaml' >/dev/null 2>&1; then echo python3; else echo python; fi
}
