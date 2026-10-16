#!/usr/bin/env python3
"""Execute the README workflow with synthetic fixtures and isolated outputs."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rscript', type=Path, required=True)
    args = parser.parse_args()
    executable = args.rscript.resolve()
    with tempfile.TemporaryDirectory(prefix='bmp-documented-') as directory:
        output = Path(directory)
        def call(*arguments):
            result = subprocess.run([str(executable), str(ROOT / 'BiomarkerCLI.R'), *map(str, arguments), '--json'],
                                    cwd=ROOT, text=True, capture_output=True, timeout=240)
            value = json.loads(result.stdout)
            if result.returncode or not value.get('ok'):
                raise AssertionError((arguments, value, result.stderr))
            return value
        subprocess.run([str(executable), str(ROOT / 'BiomarkerCLI.R'), '--help'], check=True, capture_output=True)
        call('doctor')
        for filename in ('test_quick.yaml', 'test_docker.yaml'):
            call('validate', '--config', ROOT / 'config' / filename)
        runs = []
        for kind, filename in [('binary', 'example_analysis.yaml'), ('survival', 'example_survival.yaml')]:
            qc = call('validate', '--config', ROOT / 'config' / filename)
            (output / f'{kind}-qc.json').write_text(json.dumps(qc))
            config = qc['config']
            config['output_dir'] = str(output / kind)
            path = output / f'{kind}.json'
            path.write_text(json.dumps(config))
            run = call('analyze', '--config', path)
            runs.append(run['run_dir'])
            assert Path(run['paths']['model']).is_file()
            manifest = json.loads((Path(run['run_dir']) / 'manifest.json').read_text())
            assert manifest['status'] == 'completed' and manifest['artifact_verification']['ok']
            time_options = ['--time-unit', 'years'] if kind == 'survival' else []
            call('predict', '--model', run['paths']['model'], '--data', config['data_file'], '--output', output / f'{kind}-predictions.csv', *time_options)
            evaluation = call('evaluate', '--model', run['paths']['model'], '--data', config['data_file'], '--output', output / f'{kind}-external', '--bootstrap-samples', '20', *time_options)
            call('report', '--run', run['run_dir'])
            call('resume', '--run', run['run_dir'])
            call('runs', '--output', config['output_dir'])
            call('compare', '--run', run['run_dir'], '--run', evaluation['run_dir'])
            if kind == 'binary':
                pathway = call('ora', '--run', run['run_dir'], '--gmt', ROOT / 'config/example_pathways.gmt', '--annotation-version', 'synthetic-v1', '--network', 'none', '--min-size', '1', '--permutations', '19')
                assert json.loads(Path(pathway['paths']['summary']).read_text())['annotation']['version'] == 'synthetic-v1'
        call('compare', '--run', runs[0], '--run', runs[1])
    print('Documented synthetic binary/survival workflow passed.')


if __name__ == '__main__':
    main()
