#!/usr/bin/env python3
"""Offline checks only: never opens an ALSA card or executes mixer commands."""
import argparse
import ctypes
import hashlib
import json
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FW = 'qcom/x1e80100/X1P42100-Microsoft-Surface-Laptop-13-tplg.bin'
EXPECTED = '89b731f3f98fc2b84699bca39a56e390925a44a26d5aea80382cf617e00c08d8'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def topology(path, out):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    require(len(data) == 11320 and digest == EXPECTED, 'Unapproved topology (possibly headset experiment)')
    require(json.loads((ROOT / 'drivers/firmware-manifest.json').read_text())['files'][FW]
            == {'bytes': len(data), 'sha256': digest}, 'Manifest mismatch')
    run('alsatplg', '-d', str(path), '-o', str(out / 'topology.conf'))
    decoded = (out / 'topology.conf').read_text()
    for name in ['MultiMedia1 Playback', 'MultiMedia2 Capture', 'WSA_CODEC_DMA_RX_0', 'VA_CODEC_DMA_TX_0']:
        require(name in decoded, 'Missing topology path: ' + name)
    for name in ['RX_CODEC_DMA_RX_0', 'TX_CODEC_DMA_TX_3', 'MultiMedia3', 'MultiMedia4']:
        require(name not in decoded, 'Experimental topology path: ' + name)
    print(f'topology: {len(data)} bytes SHA256={digest}')
    return data


def dtb(path):
    def get(node, prop, kind='s'):
        return run('fdtget', '-t', kind, str(path), node, prop)
    va = '/soc@0/codec@6d44000'
    pins = '/soc@0/pinctrl@6e80000'
    ldo = '/soc@0/rsc@17500000/regulators-0/ldo1'
    smps = '/soc@0/rsc@17500000/regulators-1/smps4'
    require(get(va, 'qcom,dmic-sample-rate', 'u') == '2400000', 'PDM clock must be 2.4 MHz baseline')
    require(get(va, 'pinctrl-names') == 'default', 'Missing default pinctrl')
    require(get('/soc@0/codec@6b00000', 'sound-name-prefix') == 'WSA', 'Wrong WSA control prefix')
    states = [pins + '/surface-audio-dmic01-state', pins + '/surface-audio-dmic23-state']
    require(get(va, 'pinctrl-0', 'x').split() == [get(s, 'phandle', 'x') for s in states], 'Wrong pinctrl phandles')
    for i, state in enumerate(states):
        for suffix, gpio, function in [('clk-pins', 6 + i * 2, f'dmic{i+1}_clk'), ('data-pins', 7 + i * 2, f'dmic{i+1}_data')]:
            node = state + '/' + suffix
            require(get(node, 'pins') == f'gpio{gpio}' and get(node, 'function') == function, 'Wrong DMIC pin mux')
            require(get(node, 'drive-strength', 'u') == '8', 'Wrong pin drive')
    require(get(va, 'vdd-micb-supply', 'x') == get(ldo, 'phandle', 'x'), 'Wrong micb phandle')
    require(get(ldo, 'regulator-name') == 'vreg_l1b_1p8', 'Wrong micb regulator')
    require(get(ldo, 'regulator-min-microvolt', 'u') == get(ldo, 'regulator-max-microvolt', 'u') == '1800000', 'Wrong micb voltage')
    require(get(ldo.rsplit('/', 1)[0], 'vdd-l1-l4-l10-supply', 'x') == get(smps, 'phandle', 'x'), 'Wrong micb parent supply')
    for node in [ldo, smps]:
        require('regulator-always-on' not in run('fdtget', '-p', str(path), node).split(), 'Audio rail forced always-on')
    routes = get('/sound', 'audio-routing')
    for mic in range(4):
        require(f'VA DMIC{mic} vdd-micb' in routes, 'Missing DMIC DAPM supply route')
    require(set(run('fdtget', '-l', str(path), '/sound').split()) == {'va-dai-link', 'wsa-dai-link'}, 'Unexpected sound DAI links')
    for link, ident in [('va', '6e'), ('wsa', '69')]:
        require(get(f'/sound/{link}-dai-link/cpu', 'sound-dai', 'x').split()[1:] == [ident], 'Wrong DMA backend')
    require('audio-codec' not in run('fdtget', '-l', str(path), '/').split(), 'Experimental headset codec')
    print(f'DTB {path.name}: PDM=2400000 GPIO6–9 pinctrl/micb/DAPM/DMA checked; WSA/VA only')


def ucm(root, out):
    # Parse with libasound itself; follow static UCM includes without touching hardware.
    lib = ctypes.CDLL('libasound.so.2')
    ptr = ctypes.c_void_p
    lib.snd_config_top.argtypes = [ctypes.POINTER(ptr)]
    lib.snd_input_stdio_open.argtypes = [ctypes.POINTER(ptr), ctypes.c_char_p, ctypes.c_char_p]
    lib.snd_config_load.argtypes = [ptr, ptr]
    lib.snd_config_delete.argtypes = [ptr]
    lib.snd_input_close.argtypes = [ptr]
    seen = set()
    def parse(path):
        path = path.resolve()
        if path in seen:
            return
        seen.add(path)
        conf, inp = ptr(), ptr()
        require(lib.snd_config_top(ctypes.byref(conf)) >= 0, 'snd_config_top failed')
        require(lib.snd_input_stdio_open(ctypes.byref(inp), str(path).encode(), b'r') >= 0, f'Cannot open {path}')
        try:
            require(lib.snd_config_load(conf, inp) >= 0, f'UCM syntax error: {path}')
        finally:
            lib.snd_input_close(inp)
            lib.snd_config_delete(conf)
        for name in re.findall(r'(?:File|FileName)\s+"([^"]+)"', path.read_text()):
            require('$' not in name, 'Dynamic include needs an explicit validation rule')
            parse(root / name.lstrip('/') if name.startswith('/') else path.parent / name)
    profile = root / 'Qualcomm/x1e80100/SurfaceLaptop13-HiFi.conf'
    parse(profile)
    master = root / 'conf.d/x1e80100/MicrosoftCorporation-SurfaceLaptopforBusiness13in1stEdwithSnapdragon-124I00124.conf'
    parse(master)
    master_text = master.read_text()
    require('/codecs/qcom-lpass/wsa-macro/init.conf' not in master_text,
            'Generic boot controls lack the DT WSA prefix')
    for control in ['WSA WSA_RX0 Digital Volume', 'WSA WSA_RX1 Digital Volume',
                    'WSA WSA_COMP1 Switch', 'WSA WSA_COMP2 Switch']:
        require(f"name='{control}'" in master_text, 'Missing prefixed boot control: ' + control)
    text = profile.read_text()
    require('65535' not in text and "Playback Volu' 8192" in text, 'Unsafe UCM gain')
    require('hw:${CardId},0' in text and 'hw:${CardId},1' in text, 'Wrong UCM PCM mapping')
    print(f'UCM: libasound parsed {len(seen)} files including codec sequences (hardware controls not exercised)')
    require('Before.EnableSequence "0"' in text, 'Generic PA sequence must precede local baseline')
    # A virtual master has no BootSequence and strict: skips card discovery.
    # Replace only CardId metadata; retain every actual HiFi sequence/include.
    with tempfile.TemporaryDirectory(prefix='surface-ucm-') as temp:
        virtual = Path(temp)
        (virtual / 'codecs').symlink_to((root / 'codecs').resolve(), target_is_directory=True)
        (virtual / 'ucm.conf').write_text('Syntax 4\nUseCasePath.offline { Directory "." File "Offline.conf" }\n')
        (virtual / 'Offline.conf').write_text('Syntax 4\nSectionUseCase.HiFi { File "/HiFi.conf" Comment "Offline parse only" }\n')
        (virtual / 'HiFi.conf').write_text(text.replace('${CardId}', 'Offline'))
        result = subprocess.run(['alsaucm', '-c', 'strict:Offline', 'dump', 'text'],
                                env={**os.environ, 'ALSA_CONFIG_UCM2': temp},
                                text=True, capture_output=True, check=True)
        require('PlaybackPCM hw:Offline,0' in result.stdout and 'CapturePCM hw:Offline,1' in result.stdout,
                'Expanded UCM has incorrect PCM mapping')
        (out / 'ucm-expanded.txt').write_text(result.stdout)
    print('UCM: virtual HiFi import/Include expansion passed; no sequences executed')


def embedded(vmlinux, image, data, out):
    from elftools.elf.elffile import ELFFile
    with vmlinux.open('rb') as f:
        elf = ELFFile(f)
        require(elf.elfclass == 64 and elf.little_endian, 'Expected little-endian arm64 ELF')
        def read(addr, size):
            for seg in elf.iter_segments():
                start = seg['p_vaddr']
                if seg['p_type'] == 'PT_LOAD' and start <= addr and addr + size <= start + seg['p_filesz']:
                    f.seek(seg['p_offset'] + addr - start)
                    return f.read(size)
            raise RuntimeError('Unmapped firmware address')
        sym = elf.get_section_by_name('.symtab')
        start = sym.get_symbol_by_name('__start_builtin_fw')[0]['st_value']
        end = sym.get_symbol_by_name('__end_builtin_fw')[0]['st_value']
        require((end-start) % 24 == 0, 'Unexpected builtin_fw layout')
        matches = []
        for addr in range(start, end, 24):
            name, payload, size = struct.unpack('<QQQ', read(addr, 24))
            name = read(name, 256).split(b'\0', 1)[0].decode()
            if name.endswith('-tplg.bin'):
                matches.append(name)
                require(name == FW and size == len(data) and read(payload, size) == data, 'Wrong registered built-in topology')
        require(matches == [FW], 'Missing or extra registered topology')
    require(data in image.read_bytes(), 'Verified payload missing from boot Image')
    (out / 'embedded-topology.bin').write_bytes(data)
    print('kernel: builtin_fw name, size and pointed-to bytes match; boot Image contains identical payload')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--firmware', type=Path, default=ROOT / 'archlinux/firmware-tree' / FW)
    p.add_argument('--dtb', type=Path, action='append', default=[])
    p.add_argument('--ucm-root', type=Path, required=True)
    # The kernel firmware table is part of the acceptance criteria.  Keep
    # these arguments mandatory so a CI invocation cannot silently validate
    # only the topology/DTB/UCM inputs.
    p.add_argument('--vmlinux', type=Path, required=True)
    p.add_argument('--image', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    data = topology(a.firmware, a.output)
    ucm(a.ucm_root, a.output)
    script = ROOT / 'archlinux/profile/airootfs/usr/local/sbin/surface-audio-init'
    run('bash', '-n', str(script))
    service_text = script.read_text()
    require("Playback Volu' 8192" in service_text and '65535\n' not in service_text, 'Unsafe service gain')
    for control in [
        'WSA WSA_RX0 Digital Volume', 'WSA WSA_RX1 Digital Volume',
        'WSA WSA_COMP1 Switch', 'WSA WSA_COMP2 Switch',
        'VA_DEC0 Volume', 'VA_DEC1 Volume',
    ]:
        require(f"'{control}'" in service_text,
                'Service uses an incomplete ALSA control name: ' + control)
    for control in ['COMP Switch', 'BOOST Switch', 'DAC Switch', 'PBR Switch',
                    'VISENSE Switch', 'CPS Switch', 'PA Volume']:
        require(f'"$side {control}"' in service_text,
                'Service uses an incomplete speaker control name: ' + control)
    for abbreviated in ["WSA WSA_RX0 Digital'", "WSA WSA_RX1 Digital'", "VA_DEC0'", "VA_DEC1'"]:
        require(abbreviated not in service_text, 'Service retained abbreviated ALSA control: ' + abbreviated)
    require('"$side COMP"' not in service_text and '"$side PA"' not in service_text,
            'Service retained abbreviated speaker controls')
    print('service helper: bash syntax OK')
    for path in a.dtb:
        dtb(path)
    require(a.vmlinux.is_file(), f'vmlinux is missing: {a.vmlinux}')
    require(a.image.is_file(), f'boot Image is missing: {a.image}')
    embedded(a.vmlinux, a.image, data, a.output)
    print('PASS: static consistency only; acoustic output, physical DMIC wiring and headset remain unverified')


if __name__ == '__main__':
    main()
