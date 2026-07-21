# Contributing / Вклад в проект

Спасибо за улучшения faster-ubuntu-mirror. Issues и pull requests можно писать на русском или английском.

Before opening a pull request:

1. Keep changes compatible with Bash on supported Ubuntu releases.
2. Do not change a system APT source without a backup and a validation path.
3. Run the local checks:

   ```bash
   bash -n run.sh tests/test_transform.sh
   bash tests/test_transform.sh
   ```

4. Update the Russian and English wording in `README.md` when changing the CLI or behavior.

For a bug report, include the Ubuntu version, source-file format (`sources.list` or `ubuntu.sources`), command used, and redacted terminal output. Never include private repository URLs or credentials.
