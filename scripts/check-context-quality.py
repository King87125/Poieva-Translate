#!/usr/bin/env python3
"""Check recorded public-sample outputs. Does not call models or read credentials.

Rules are narrow regressions, not a complete assessment of translation quality.
Unrecorded cases stay untested, and explicit manual failures always fail.
"""
import argparse
import json
from pathlib import Path
import re


def check(suite, report):
    if suite['version'] != report['suiteVersion']:
        raise ValueError('Suite version mismatch; re-run with the current samples.')
    cases = {case['id']: case for case in suite['cases']}
    records = {}
    for record in report['records']:
        identifier = record['id']
        if identifier not in cases or identifier in records:
            raise ValueError('Unknown or duplicate case: ' + identifier)
        records[identifier] = record
    results = []
    for identifier, case in cases.items():
        record = records.get(identifier)
        if record is None:
            results.append({'id': identifier, 'status': 'untested', 'issues': []})
            continue
        if record.get('blockedReason'):
            results.append({'id': identifier, 'status': 'blocked', 'issues': [record['blockedReason']]})
            continue
        output = record.get('output', '')
        issues = []
        if not isinstance(output, str) or not output.strip():
            issues.append('No usable output')
            output = ''
        if record.get('source') != case['source']:
            issues.append('Recorded source differs from the sample')
        if record.get('before') != case['before'] or record.get('after') != case['after']:
            issues.append('Recorded reference differs from the sample')
        if record.get('contextApplied') is not True:
            issues.append('Context was not confirmed in the execution status')
        for pattern in case.get('mustMatch', []):
            if re.search(pattern, output, re.I | re.M) is None:
                issues.append('Missing expected pattern: ' + pattern)
        if case.get('matchAny') and not any(re.search(p, output, re.I | re.M) for p in case['matchAny']):
            issues.append('No expected referent found')
        for pattern in case.get('mustNotMatch', []):
            if re.search(pattern, output, re.I | re.M):
                issues.append('Unexpected pattern: ' + pattern)
        for literal in case.get('preserve', []):
            if literal not in output:
                issues.append('Missing protected text: ' + literal)
        if record.get('manualReview') != 'pass':
            issues.append('Manual semantic review not passed')
        results.append({'id': identifier, 'status': 'fail' if issues else 'pass', 'issues': issues})
    return results


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--suite', type=Path, default=root / 'Tests/Fixtures/context-regressions.json')
    args = parser.parse_args()
    suite = json.loads(args.suite.read_text())
    report = json.loads(args.report.read_text())
    results = check(suite, report)
    counts = {status: sum(row['status'] == status for row in results) for status in ['pass', 'fail', 'blocked', 'untested']}
    print(json.dumps({'counts': counts, 'results': results}, ensure_ascii=False, indent=2))
    raise SystemExit(1 if counts['fail'] else 2 if counts['blocked'] else 0)


if __name__ == '__main__':
    main()
