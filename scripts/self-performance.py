#!/usr/bin/env python3
"""性能记录、产物留存与固定门槛比较；所有原值只写忽略目录。"""
import argparse
import hashlib
import json
import math
import pathlib
import re
import plistlib
import shutil
import statistics
import subprocess
import sys

ROOT = pathlib.Path('build/acceptance/self-performance')
SCENES = ['closed-running', 'open-running', 'closed-stopped', 'open-stopped']

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')

def label(value):
    if not value or any(x not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for x in value):
        raise ValueError('label 只接受字母、数字、连字符和下划线')
    return value

def binary(args):
    if args.binary:
        result = pathlib.Path(args.binary)
    else:
        subprocess.run(['swift', 'build', '-c', 'release', '--product', 'MeowMacSelfTest'], check=True)
        directory = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], text=True).strip()
        result = pathlib.Path(directory) / 'MeowMacSelfTest'
    if result.name != 'MeowMacSelfTest' or pathlib.Path.cwd().resolve() not in result.resolve().parents:
        raise ValueError('只运行仓库内的MeowMacSelfTest测量产物')
    if not result.is_file():
        raise ValueError('测量二进制不存在')
    return result.resolve()

def capture(args):
    source = binary(args)
    directory = ROOT / label(args.label) / 'artifact'
    if directory.exists():
        raise ValueError('产物目录已存在，避免覆盖基线')
    directory.mkdir(parents=True)
    shutil.copy2(source, directory / source.name)
    for bundle in source.parent.glob('*.bundle'):
        shutil.copytree(bundle, directory / bundle.name)
    files = {str(x.relative_to(directory)): digest(x) for x in directory.rglob('*') if x.is_file()}
    save(directory / 'manifest.json', {'files': files, 'configuration': 'release', 'version': '0.1.0',
         'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()})
    print('release 测量产物和资源已留存：' + str(directory / source.name))

def validate(record, scene=None):
    main = record['main']
    for name in ['elapsed', 'cpuSeconds', 'cpuPercent', 'ri_pkg_idle_wkups', 'ri_interrupt_wkups', 'residentBytes', 'footprintBytes']:
        if isinstance(main[name], bool) or not isinstance(main[name], (int, float)) or not math.isfinite(main[name]) or main[name] < 0:
            raise ValueError('缺测、坏类型或非法计数')
    if main['elapsed'] <= 0 or abs(main['cpuPercent'] - main['cpuSeconds'] / main['elapsed'] * 100) > 1e-8:
        raise ValueError('CPU 时间口径不一致')
    start, end = record['mainStart'], record['mainEnd']
    for reading in [start, end]:
        for name in ['pid', 'identity', 'uptime', 'userNS', 'systemNS', 'packageIdleWakeups', 'interruptWakeups']:
            value = reading[name]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError('原读数缺测、坏类型或非法计数')
            if name != 'uptime' and (not isinstance(value, int) or (name in ['pid', 'identity'] and value <= 0)):
                raise ValueError('原身份或计数必须为合法整数')
    if start['pid'] != end['pid'] or start['identity'] != end['identity'] or start['identity'] <= 0:
        raise ValueError('PID 重启')
    for name in ['userNS', 'systemNS', 'packageIdleWakeups', 'interruptWakeups']:
        if end[name] < start[name]:
            raise ValueError('计数倒退')
    elapsed = end['uptime'] - start['uptime']
    cpu = (end['userNS']-start['userNS'] + end['systemNS']-start['systemNS']) / 1e9
    if abs(elapsed-main['elapsed']) > 1e-8 or abs(cpu-main['cpuSeconds']) > 1e-8:
        raise ValueError('原读数与差分不一致')
    for source, target in [('packageIdleWakeups', 'ri_pkg_idle_wkups'), ('interruptWakeups', 'ri_interrupt_wkups')]:
        if end[source]-start[source] != main[target]:
            raise ValueError('原计数器与差分不一致')
    if main['elapsed'] < record['requestedSeconds'] or main['elapsed'] > record['requestedSeconds'] * 1.2 + .5:
        raise ValueError('测量窗口时长不一致或阻塞过久')
    if scene:
        state = record['stateChecks']
        if state['panelShown'] != scene.startswith('open') or state['stopped'] != scene.endswith('stopped'):
            raise ValueError('实际状态错误')
        if state['reducedMotion'] != (scene == 'closed-reduced'):
            raise ValueError('减少动态效果状态错误')
        if state['panelShown'] and abs(state['width'] - 360) > 0.5:
            raise ValueError('面板宽度错误')
        if record['work']['frameTimer'] <= 0 or (not record.get('experiment', {}).get('omitImageAssignment') and record['work']['renderDraw'] <= 0):
            raise ValueError('没有实际生产定时器或延迟绘制')
        if record['work']['sampleTimer'] < int(record['requestedSeconds'] / 2) - 1:
            raise ValueError('生产采样没有按周期运行')
        if not scene.endswith('stopped') and scene != 'closed-reduced' and not record.get('experiment', {}).get('omitImageAssignment') and state['frameChanges'] <= 0:
            raise ValueError('奔跑帧没有变化')
        if any(record['isolation'][key] is not False for key in
               ['applicationDelegate', 'networkBridge', 'quotaCLI', 'notifications', 'agent', 'realCollector', 'realConfiguration']):
            raise ValueError('真实副作用依赖被构造')

def auxiliary_summary(record):
    values = [record['auxiliaryStart'], *record.get('childrenObserved', []), record['auxiliaryEnd']]
    groups = {}
    unavailable = []
    for value in values:
        if 'enumerationUnavailable' in value:
            unavailable.append(value['enumerationUnavailable'])
        for child in value.get('children', []):
            if 'reading' not in child:
                unavailable.append(child.get('unavailable', 'child reading unavailable'))
                continue
            r = child['reading']
            groups.setdefault((r['pid'], r['identity']), []).append(r)
    children = []
    for (pid, identity), readings in groups.items():
        readings.sort(key=lambda x: x['uptime'])
        first, last = readings[0], readings[-1]
        elapsed = last['uptime'] - first['uptime']
        cpu = (last['userNS']-first['userNS'] + last['systemNS']-first['systemNS']) / 1e9
        if elapsed < 0 or cpu < 0:
            raise ValueError('子进程时间或计数倒退')
        children.append({'pid': pid, 'identity': identity, 'observations': len(readings),
                         'observedCPUSeconds': cpu if elapsed > 0 else None,
                         'observedCPUPercent': cpu / elapsed * 100 if elapsed > 0 else None,
                         'coveredSeconds': elapsed, 'coverage': '观察区间下界，可能遗漏启动、退出和短命进程'})
    w1, w2 = record['auxiliaryStart'], record['auxiliaryEnd']
    a, b = w1.get('windowServer'), w2.get('windowServer')
    window = None
    if a and b and (a['pid'], a['identity']) == (b['pid'], b['identity']) and b['uptime'] > a['uptime']:
        cpu = (b['userNS']-a['userNS'] + b['systemNS']-a['systemNS']) / 1e9
        if cpu < 0:
            raise ValueError('WindowServer 计数倒退')
        window = {'cpuSeconds': cpu, 'cpuPercent': cpu / (b['uptime']-a['uptime']) * 100,
                  'scope': 'WindowServer 整体辅助量，不能归因给 MeowMac'}
    return {'children': children, 'enumerationUnavailable': unavailable, 'windowServer': window,
            'windowServerUnavailable': w1.get('windowServerUnavailable') or w2.get('windowServerUnavailable')}

def summarize(records):
    values = [x['main']['cpuPercent'] for x in records]
    median = statistics.median(values)
    return {'values': values, 'median': median, 'range': max(values)-min(values),
            'mad': statistics.median([abs(x-median) for x in values])}

def augment(path, measured_binary, live=False):
    record = json.loads(path.read_text())
    record['binarySHA256'] = digest(measured_binary)
    record['configuration'] = 'installed' if live else 'release'
    if not live:
        bundle_files = {}
        for bundle in measured_binary.parent.glob('*.bundle'):
            bundle_files.update({str(p.relative_to(measured_binary.parent)): digest(p) for p in bundle.rglob('*') if p.is_file()})
        record['resourceSHA256'] = hashlib.sha256(json.dumps(bundle_files, sort_keys=True).encode()).hexdigest()
    record['measuredBinary'] = str(measured_binary)
    if live:
        info = measured_binary.parent.parent / 'Info.plist'
        with info.open('rb') as stream:
            plist = plistlib.load(stream)
        if pathlib.Path(record['actualExecutable']).resolve() != measured_binary.resolve():
            raise ValueError('PID 与安装版程序不一致')
        record['version'] = plist.get('CFBundleShortVersionString')
        record['conditions'] = {'scene': 'live', 'installedBinarySHA256': record['binarySHA256'],
              'workCounters': 'unavailable', 'sampling': 'existing-production', 'display': record['display'], 'reducedMotion': record['reducedMotion']}
    if 'main' in record:
        record['auxiliarySummary'] = auxiliary_summary(record)
    save(path, record)
    return record

def measure(args):
    runner = binary(args)
    output = ROOT / label(args.label) / args.command
    if output.exists():
        raise ValueError('记录目录已存在，请换 label；不覆盖或挑选旧记录')
    output.mkdir(parents=True)
    scenes = ([args.only_scene] if args.only_scene else SCENES) if args.command == 'matrix' else ['live']
    if args.command == 'probe':
        scenes = [args.scene]
    elif args.command == 'collector':
        scenes = ['collector']
    if args.command == 'live':
        pids = subprocess.check_output(['pgrep', '-x', 'MeowMac'], text=True).split()
        if len(pids) != 1:
            raise ValueError('要求恰好一个现有 MeowMac 主进程')
        measured = pathlib.Path.home() / 'Applications/MeowMac.app/Contents/MacOS/MeowMac'
    else:
        measured = runner
    initial_hash = digest(measured)
    for scene in scenes:
        records = []
        for repeat in range(args.repeats):
            path = output / f'{scene}-{repeat+1}.json'
            command = [str(runner), '--profile', 'live' if scene == 'live' else args.command,
                       '--output', str(path), '--seconds', str(args.seconds), '--warmup', str(args.warmup)]
            if scene == 'live':
                command += ['--pid', pids[0]]
            else:
                command += ['--scene', scene, '--cat', args.cat]
            if args.notification_probe:
                command += ['--notification-probe']
            if args.omit_notification_process:
                command += ['--omit-notification-process']
            if args.omit_image_assignment:
                command += ['--omit-image-assignment']
            if args.omit_system_update:
                command += ['--omit-system-update']
            if args.expect_no_redundant_work:
                command += ['--expect-no-redundant-work']
            print(f'{scene}：第 {repeat+1}/{args.repeats} 次，预热 {0 if scene == "live" else args.warmup} 秒，测量 {args.seconds} 秒', flush=True)
            with (output / f'{scene}-{repeat+1}.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=log, check=True)
            if digest(measured) != initial_hash:
                raise ValueError('测量过程中二进制变化')
            record = augment(path, measured, scene == 'live')
            if args.command != 'collector':
                validate(record, None if scene == 'live' else scene)
            records.append(record)
        if args.command != 'collector':
            save(output / f'{scene}-summary.json', summarize(records))
    if args.command == 'live':
        print('主进程身份与读数校验通过；辅助量与计数缺口见JSON。')
    elif args.command == 'matrix':
        print('矩阵容器、动画与读数校验通过；原值及统计见忽略目录。')
    else:
        print('诊断记录已保存；不参与正式性能判定。')

def group(name, mode, scene):
    sources = ROOT / label(name) / 'group-sources.json'
    if sources.exists():
        mapping = json.loads(sources.read_text())
        name = mapping.get(scene, name)
    directory = ROOT / label(name) / mode
    paths = sorted(p for p in directory.glob(scene + '-*.json') if re.fullmatch(re.escape(scene) + r'-[0-9]+\.json', p.name))
    records = [json.loads(p.read_text()) for p in paths]
    if len(records) < 3:
        raise ValueError('至少需要3次完整测量')
    for row in records:
        validate(row, None if scene == 'live' else scene)
        if row['mode'] != ('live' if scene == 'live' else 'matrix'):
            raise ValueError('诊断记录不能参与正式比较')
        if any(row.get('experiment', {}).values()):
            raise ValueError('诊断省略路径不能参与正式比较')
    conditions = [(r['conditions'], r['configuration'], r['requestedSeconds'], r['version'],
                   None if scene == 'live' else r['stateChecks']['scale'], r.get('resourceSHA256')) for r in records]
    if any(c != conditions[0] for c in conditions):
        raise ValueError('组内条件不一致')
    if len({r['binarySHA256'] for r in records}) != 1:
        raise ValueError('组内二进制不一致')
    return records, conditions[0]

def verdict(before, after, primary):
    b, a = summarize(before), summarize(after)
    tolerance = max(b['median'] * .1, .05)
    stable = b['mad'] <= tolerance and a['mad'] <= tolerance
    improved = max(a['values']) < min(b['values']) if primary else a['median'] <= b['median'] + tolerance
    return {'before': b, 'after': a, 'tolerance': tolerance, 'stable': stable,
            'passed': stable and improved, 'primary': primary}

def compare(args):
    scenes = ['live'] if args.live else SCENES
    if not args.live and args.primary not in SCENES + ['live']:
        raise ValueError('必须指定预先声明的主场景 --primary')
    if args.live and args.primary not in [None, 'live']:
        raise ValueError('真实常驻的主场景只能是 live；不指定仅检查非退化')
    results = {}
    for scene in scenes:
        before, bc = group(args.before, 'live' if args.live else 'matrix', scene)
        after, ac = group(args.after, 'live' if args.live else 'matrix', scene)
        # 安装版哈希允许前后不同，其余比较条件必须一致。人工负载可比性另由 result 核对。
        if scene == 'live':
            bc = ({k: v for k, v in bc[0].items() if k != 'installedBinarySHA256'},) + bc[1:]
            ac = ({k: v for k, v in ac[0].items() if k != 'installedBinarySHA256'},) + ac[1:]
        if bc != ac:
            raise ValueError('前后测量条件不一致')
        results[scene] = verdict(before, after, scene == args.primary)
        print(scene + '：' + ('通过' if results[scene]['passed'] else '未通过'))
    save(ROOT / f'compare-{label(args.before)}-{label(args.after)}-{"live" if args.live else "matrix"}-{args.primary or "non-primary"}.json', results)
    return 0 if all(x['passed'] for x in results.values()) else 1

def selftest():
    def rows(values):
        return [{'main': {'cpuPercent': value}} for value in values]
    assert verdict(rows([1, 1.01, 1.02]), rows([.7, .71, .72]), True)['passed']
    assert not verdict(rows([1, 1.01, 1.02]), rows([1, 1.01, 1.02]), True)['passed']
    assert verdict(rows([1, 1.01, 1.02]), rows([1, 1.01, 1.02]), False)['passed']
    assert not verdict(rows([1, 1.01, 1.02]), rows([1.2, 1.21, 1.22]), False)['passed']
    assert not verdict(rows([.1, 1, 2]), rows([.1, .2, .3]), True)['passed']
    good = {'main': {'elapsed': 30, 'cpuSeconds': .3, 'cpuPercent': 1,
               'ri_pkg_idle_wkups': 3, 'ri_interrupt_wkups': 4, 'residentBytes': 100, 'footprintBytes': 100},
            'mainStart': {'pid': 42, 'identity': 10, 'uptime': 5, 'userNS': 100, 'systemNS': 100,
                          'packageIdleWakeups': 2, 'interruptWakeups': 3},
            'mainEnd': {'pid': 42, 'identity': 10, 'uptime': 35, 'userNS': 300_000_100, 'systemNS': 100,
                        'packageIdleWakeups': 5, 'interruptWakeups': 7}, 'requestedSeconds': 30,
            'stateChecks': {'panelShown': False, 'stopped': True, 'frameChanges': 0, 'reducedMotion': False},
            'work': {'frameTimer': 80, 'renderDraw': 80, 'sampleTimer': 15},
            'isolation': {key: False for key in ['applicationDelegate', 'networkBridge', 'quotaCLI', 'notifications', 'agent', 'realCollector', 'realConfiguration']}}
    validate(good, 'closed-stopped')
    bad = [{}, {'main': {'elapsed': None}}]
    for key, field, value in [('main', 'cpuSeconds', None), ('mainEnd', 'identity', 11),
                             ('mainEnd', 'userNS', 99), ('stateChecks', 'panelShown', True),
                             ('work', 'renderDraw', 0), ('isolation', 'realCollector', True),
                             ('main', 'ri_pkg_idle_wkups', 5), ('mainStart', 'userNS', float('nan')),
                             ('mainStart', 'pid', True), ('mainEnd', 'systemNS', -1)]:
        row = json.loads(json.dumps(good)); row[key][field] = value; bad.append(row)
    for record in bad:
        try:
            validate(record, 'closed-stopped')
        except (ValueError, KeyError, TypeError):
            pass
        else:
            raise AssertionError('缺测或违反条件没有失败')
    print('性能比较器：5组门槛、12组缺测与坏数据负控通过。')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ['capture', 'matrix', 'live', 'probe', 'collector']:
        p = sub.add_parser(name)
        p.add_argument('--label', required=True)
        p.add_argument('--binary')
        p.add_argument('--seconds', type=float, default=120 if name == 'live' else 30)
        p.add_argument('--warmup', type=float, default=10)
        p.add_argument('--repeats', type=int, default=3)
        p.add_argument('--scene', default='closed-stopped', choices=SCENES + ['closed-reduced', 'open-high'])
        p.add_argument('--only-scene', choices=SCENES)
        p.add_argument('--cat', default='builtin.slim')
        p.add_argument('--expect-no-redundant-work', action='store_true')
        p.add_argument('--omit-image-assignment', action='store_true')
        p.add_argument('--omit-system-update', action='store_true')
        p.add_argument('--notification-probe', action='store_true')
        p.add_argument('--omit-notification-process', action='store_true')
    p = sub.add_parser('compare')
    p.add_argument('--before', required=True); p.add_argument('--after', required=True)
    p.add_argument('--primary'); p.add_argument('--live', action='store_true')
    sub.add_parser('selftest')
    args = parser.parse_args()
    if args.command == 'compare':
        return compare(args)
    if args.command == 'selftest':
        selftest(); return 0
    if args.command == 'capture':
        capture(args)
    else:
        if args.repeats < 1 or args.repeats > 10:
            raise ValueError('repeats 无效')
        if args.command == 'matrix' and (args.seconds != 30 or args.warmup != 10 or args.repeats < 3):
            raise ValueError('正式矩阵须预热10秒、测量30秒、至少3次')
        if args.command != 'probe' and (args.omit_image_assignment or args.omit_system_update or args.expect_no_redundant_work or args.notification_probe or args.omit_notification_process):
            raise ValueError('诊断省略与负控只允许 probe')
        if args.omit_notification_process and not args.notification_probe:
            raise ValueError('省略通知处理须配合隔离诊断夹具')
        measure(args)
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print('性能测量拒绝通过：' + str(error), file=sys.stderr)
        sys.exit(1)
