#!/usr/bin/env python3
"""Freeze inputs and the one shared Tcl preset into a fresh run; never launch Vivado."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import math
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tcl(value):
    value = str(value).replace('\\', '/')
    for old, new in [('"', '\\"'), ('$', '\\$'), ('[', '\\['), (']', '\\]'), ('\n', '\\n'), ('\r', '\\r')]:
        value = value.replace(old, new)
    return '"' + value + '"'


def win(path):
    return subprocess.check_output(['wslpath', '-w', str(Path(path).resolve())], text=True).strip().replace('\\', '/')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--top', required=True)
    parser.add_argument('--source-dir', type=Path)
    parser.add_argument('--checkpoint', type=Path, help='Report an existing DCP, without synthesis.')
    parser.add_argument('--part', default='xc7a200tsbg484-1')
    parser.add_argument('--generic', action='append', default=[])
    parser.add_argument('--clock-port', default='clk')
    parser.add_argument('--period-ns', type=float, default=20.0)
    parser.add_argument('--input-delay-ns', type=float, default=2.0)
    parser.add_argument('--output-delay-ns', type=float, default=2.0)
    parser.add_argument('--common-period-ns', type=float, action='append', default=None)
    parser.add_argument('--max-threads', type=int, default=8)
    parser.add_argument('--block', action='append', default=[], help='LABEL=hierarchical pin glob')
    parser.add_argument('--no-gui', action='store_true')
    parser.add_argument('--vivado-root', default='F:/AMDDesignTools/2026.1/Vivado')
    args = parser.parse_args()
    if bool(args.source_dir) == bool(args.checkpoint):
        parser.error('Choose exactly one of --source-dir or --checkpoint.')
    for name in ['top', 'clock_port']:
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*', getattr(args, name)):
            parser.error(f'Invalid {name}')
    if args.max_threads < 1 or not all(math.isfinite(x) for x in [args.period_ns, args.input_delay_ns, args.output_delay_ns]) or args.period_ns <= 0 or min(args.input_delay_ns, args.output_delay_ns) < 0:
        parser.error('Threads and period must be positive; I/O delays must be nonnegative.')
    periods = args.common_period_ns if args.common_period_ns is not None else [25.0]
    if any(not math.isfinite(value) or value <= 0 for value in periods):
        parser.error('Common clock periods must be positive.')
    blocks = {}
    for entry in args.block:
        label, sep, pattern = entry.partition('=')
        if not sep or not re.fullmatch(r'[A-Za-z0-9_]+', label) or '"' in pattern:
            parser.error('Block must be a safe LABEL=pin_glob.')
        blocks[label] = pattern
    for value in args.generic:
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=\S+', value):
            parser.error('Generic must be NAME=VALUE without whitespace.')
    sources = []
    if args.source_dir:
        source = args.source_dir.resolve(strict=True)
        sources = sorted(p for p in source.rglob('*') if p.is_file() and p.suffix in ['.v', '.sv', '.vh', '.svh'])
        if not any(p.suffix in ['.v', '.sv'] for p in sources):
            parser.error('No Verilog/SystemVerilog source files found.')
    else:
        args.checkpoint = args.checkpoint.resolve(strict=True)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    build_win = win(out)
    def output_win(path):
        suffix = Path(path).relative_to(out).as_posix()
        return build_win if suffix == '.' else build_win + '/' + suffix
    preset = out/'preset.tcl'
    shutil.copy2(HERE/'synth_preset.tcl', preset)
    manifest = {'preset_version':2, 'prepared_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'preset_origin':str(HERE/'synth_preset.tcl'), 'preset_sha256':sha(preset),
                'preparer_sha256':sha(Path(__file__)), 'mode':'synthesis' if sources else 'reports',
                'top':args.top, 'part':args.part, 'generics':args.generic,
                'clock_port':args.clock_port, 'synthesis_period_ns':args.period_ns,
                'input_delay_ns':args.input_delay_ns, 'output_delay_ns':args.output_delay_ns,
                'common_periods_ns':periods, 'max_threads':args.max_threads,
                'block_patterns':blocks, 'export_gui':not args.no_gui, 'files':{}}
    rtl_files, includes = [], set()
    for path in sources:
        target = out/'rtl'/path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        assert sha(target) == sha(path)
        manifest['files'][str(target.relative_to(out))] = {'origin':str(path), 'sha256':sha(target)}
        includes.add(output_win(target.parent))
        if path.suffix in ['.v', '.sv']:
            rtl_files.append(output_win(target))
    if args.checkpoint:
        shutil.copy2(args.checkpoint, out/'input.dcp')
        manifest['files']['input.dcp'] = {'origin':str(args.checkpoint), 'sha256':sha(out/'input.dcp')}
        assert sha(out/'input.dcp') == sha(args.checkpoint)
    xdc = '\n'.join([
        f'create_clock -name clk -period {args.period_ns} [get_ports {tcl(args.clock_port)}]',
        f'set_input_delay {args.input_delay_ns} -clock clk [get_ports -filter {{DIRECTION == IN && NAME != "{args.clock_port}"}}]',
        f'set_output_delay {args.output_delay_ns} -clock clk [get_ports -filter {{DIRECTION == OUT}}]', ''])
    (out/'timing.xdc').write_text(xdc)
    values = {**{k:tcl(v) for k,v in {'build_dir':build_win, 'mode':manifest['mode'], 'top':args.top,
              'part':args.part, 'clock_port':args.clock_port, 'clock_name':'clk',
              'xdc':output_win(out/'timing.xdc'), 'checkpoint':output_win(out/'input.dcp')}.items()},
              **{k:str(v) for k,v in {'synthesis_period_ns':args.period_ns, 'input_delay_ns':args.input_delay_ns,
              'output_delay_ns':args.output_delay_ns, 'max_threads':args.max_threads, 'export_gui':int(not args.no_gui)}.items()},
              'sources':'[list '+ ' '.join(map(tcl, rtl_files))+']',
              'include_dirs':'[list '+ ' '.join(map(tcl, sorted(includes)))+']',
              'generics':'[list '+ ' '.join(map(tcl, args.generic))+']',
              'common_periods_ns':'[list '+ ' '.join(map(str,periods))+']',
              'block_patterns':'[dict create '+ ' '.join(tcl(x) for pair in blocks.items() for x in pair)+']'}
    (out/'run_config.tcl').write_text('set preset_config [dict create \\\n'+ ''.join('    '+k+' '+v+' \\\n' for k,v in values.items())+']\n')
    tool = args.vivado_root.replace('/', '\\').rstrip('\\')
    command = '@echo off\r\nsetlocal\r\ncd /d "%~dp0"\r\ncall "'+tool+'\\bin\\vivado.bat" -mode batch -nojournal -log vivado.log -source preset.tcl -tclargs run_config.tcl > vivado_console.log 2>&1\r\nset "PRESET_EXIT_CODE=%errorlevel%"\r\n> vivado_exitcode.txt echo %PRESET_EXIT_CODE%\r\nexit /b %PRESET_EXIT_CODE%\r\n'
    (out/'launch.cmd').write_bytes(command.encode('utf-8'))
    for name in ['run_config.tcl', 'timing.xdc', 'launch.cmd']:
        manifest[name+'_sha256'] = sha(out/name)
    (out/'RUN_MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
