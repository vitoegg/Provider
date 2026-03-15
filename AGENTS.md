# AGENTS.md

## Cursor Cloud specific instructions

### Repository overview

This is a **static configuration repository** ("Provider") for proxy tools (Surge/Loon). There is no traditional application server, build system, or package manager lockfile. The "application" is a set of rule-processing workflows run via GitHub Actions (or locally).

### Key components

| Component | Location | How to run |
|---|---|---|
| Proxy rule updater | `Script/Workflow/proxy_rules.sh` + `proxy_rules.py` | `GITHUB_WORKSPACE=/workspace bash Script/Workflow/proxy_rules.sh` |
| MosDNS rule updater | `Script/Workflow/mosdns_rules.sh` + `mosdns_rules.py` | `GITHUB_WORKSPACE=/workspace bash Script/Workflow/mosdns_rules.sh` |
| Upstream change checker | `Script/Workflow/upstream_tasks.py` | Requires `GITHUB_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` env vars |
| Python rule deduplicator | `Script/Workflow/proxy_rules.py` | `python3 Script/Workflow/proxy_rules.py <input_file>` |
| MosDNS rule converter | `Script/Workflow/mosdns_rules.py` | `python3 Script/Workflow/mosdns_rules.py <input_file>` |
| Network deploy scripts | `Script/Network/*.sh` | Require root access on a Linux server; not suitable for local/CI testing |
| Task scripts | `Script/Task/*.py` | Require `cloudscraper` (nodeseek) and env vars for credentials |

### Running workflows locally

All shell workflow scripts reference `$GITHUB_WORKSPACE` to locate config files and Python scripts. Set it to the repo root:

```bash
export GITHUB_WORKSPACE=/workspace
```

The workflow scripts also reference `$GITHUB_OUTPUT` for GitHub Actions output variables. Create a temp file:

```bash
export GITHUB_OUTPUT=$(mktemp)
```

### System dependencies

- Python 3.x (pre-installed)
- `jq` (pre-installed)
- `curl` (pre-installed)
- `requests` Python package (pre-installed)

### Linting / testing

There are no formal lint or test suites in this repository. Validation is done by:

1. **Bash syntax check**: `bash -n Script/Workflow/*.sh`
2. **Python syntax check**: `python3 -m py_compile Script/Workflow/*.py Script/Task/*.py`
3. **Functional test**: Run the workflow scripts with `GITHUB_WORKSPACE=/workspace` and verify they complete without errors

### Gotchas

- The workflow shell scripts use `git add` / `git restore --staged` internally. Running them locally will modify git staging. Reset with `git restore --staged .` after testing.
- Temp log files (`*.tmp.log`) and `__pycache__/` directories are created during workflow runs. Clean them up before committing.
- `Script/Network/` scripts are deployment tools for VPS servers — they install system services and modify system configs. Do **not** run them in this environment.
