#!/usr/bin/env python3
"""Exercise the built installer against temporary files, never personal settings."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/Peeksy').resolve()
with tempfile.TemporaryDirectory(prefix='peeksy codex ') as scratch:
    root = Path(scratch)
    env = dict(os.environ, CODEX_HOME=str(root / 'custom codex'))
    config = root / 'custom codex' / 'hooks.json'
    config.parent.mkdir()
    original = {'description': 'preserve', 'hooks': {'Stop': [
        {'hooks': [{'type': 'command', 'command': '/other/observer'}]}
    ]}}
    config.write_text(json.dumps(original))
    observer = root / 'observer.sh'
    observer.write_text('#!/bin/sh\nexit 0\n')
    observer.chmod(0o755)

    def run(*args, status=0):
        result = subprocess.run([str(binary), *args], env=env,
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == status, (args, result.stdout, result.stderr)
        return result.stdout

    before = config.read_bytes()
    run('--install-hook', '--agent', 'codex', '--hook-path', str(observer), '--dry-run')
    assert config.read_bytes() == before
    run('--install-hook', '--agent', 'codex', '--hook-path', str(observer), '--yes')
    installed = json.loads(config.read_text())
    expected = {'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse',
                'PostToolUse', 'PermissionRequest', 'Stop', 'Interrupt'}
    assert set(installed['hooks']) == expected
    assert installed['description'] == original['description']
    assert installed['hooks']['Stop'][0] == original['hooks']['Stop'][0]
    command = "'" + str(observer).replace("'", "'\\''") + "'"
    for groups in installed['hooks'].values():
        assert groups[-1]['hooks'][0] == {'type': 'command', 'command': command, 'timeout': 3}
    assert list(config.parent.glob('*.peeksy-backup-*')), 'Installer must back up the existing file'
    before = config.read_bytes()
    run('--install-hook', '--agent', 'codex', '--hook-path', str(observer), '--yes')
    assert config.read_bytes() == before
    run('--uninstall-hook', '--agent', 'codex', '--hook-path', str(observer), '--yes')
    assert json.loads(config.read_text()) == original
    # Explicit --settings wins regardless of option order.
    alternate = root / 'alternate.json'
    run('--install-hook', '--settings', str(alternate), '--agent', 'codex',
        '--hook-path', str(observer), '--yes')
    assert set(json.loads(alternate.read_text())['hooks']) == expected
    assert json.loads(config.read_text()) == original
    # Printing a snippet must not read a broken settings file.
    config.write_text('broken JSON')
    assert set(json.loads(run('--print-hook-json', '--agent', 'codex'))['hooks']) == expected
    legacy = json.loads(run('--print-hook-json'))['hooks']
    assert len(legacy) == 9 and 'Notification' in legacy and 'Interrupt' not in legacy
    run('--print-hook-json', '--agent', 'unknown', status=2)
print('Codex CLI installation: preview, install, repeat, uninstall, paths, preservation, and legacy defaults passed.')
