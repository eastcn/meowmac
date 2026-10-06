#!/usr/bin/env python3
"""只读校准：记录面板压力百分比和内核档位，不制造内存压力。"""
import csv
import datetime
import os
import pathlib
import subprocess
import time

if os.environ.get('MEOWMAC_LIVE') != '1':
    raise SystemExit('实机校准需 MEOWMAC_LIVE=1')
path = pathlib.Path('build/acceptance/alert-rules/memory-calibration.csv')
path.parent.mkdir(parents=True, exist_ok=True)
start = time.monotonic()
count = 0
with path.open('w', newline='') as output:
    writer = csv.writer(output)
    writer.writerow(['timestamp', 'kernel_level', 'pressure_percent'])
    while True:
        values = []
        for key in ['kern.memorystatus_vm_pressure_level', 'kern.memorystatus_level']:
            result = subprocess.run(['/usr/sbin/sysctl', '-n', key], capture_output=True, text=True)
            try:
                values.append(int(result.stdout.strip()) if result.returncode == 0 else None)
                if result.returncode != 0 and count == 0:
                    print(f'{key} 读取失败：{result.stderr.strip()}', flush=True)
            except ValueError:
                print(f'{key} 返回值无效', flush=True)
                values.append(None)
        writer.writerow([datetime.datetime.now(datetime.timezone.utc).isoformat(), values[0],
                         100 - values[1] if values[1] is not None else None])
        output.flush()
        count += 1
        if time.monotonic() - start >= 900:
            break
        time.sleep(2)
print(f'校准完成：{count} 个样本，时长 {time.monotonic() - start:.1f} 秒；{path}')
