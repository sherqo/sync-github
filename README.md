# gh-sync

A lightweight, concurrent, and configurable Bash script that automatically mirrors and updates all GitHub repositories from your account.

It clones repositories as bare mirrors (`--mirror`), fetches updates across **all branches and tags**, handles API rate limits via exponential backoff, and provides desktop notifications (`notify-send`).

## Prerequisites

- [Git](https://git-scm.com/)
- [GitHub CLI (`gh`)](https://cli.github.com/) authenticated with `gh auth login`
- `notify-send` _(optional, for Linux desktop notifications)_

## Installation

1. Clone or download `sync-github.sh`:

   ```bash
   git clone https://github.com/your-username/sync-github.git
   cd sync-github
   ```

2. Make the script executable:

   ```bash
   chmod +x sync-github.sh
   ```

## Usage

Run the script directly with default parameters:

```bash
./sync-github.sh -d $HOME/github_backups -c 8 -b 10 -m 3000 -r 10 --notify true -v 2
```

### CLI Options

| Flag | Long Flag       | Description                                                    | Default                |
| ---- | --------------- | -------------------------------------------------------------- | ---------------------- |
| `-d` | `--dir`         | Target folder for backups                                      | `$HOME/github_backups` |
| `-c` | `--concurrency` | Number of parallel sync jobs                                   | `8`                    |
| `-b` | `--base-delay`  | Initial backoff wait time in seconds                           | `10`                   |
| `-m` | `--max-delay`   | Maximum backoff wait cap in seconds                            | `3000` (50 mins)       |
| `-r` | `--max-retries` | Maximum retry attempts per repo                                | `10`                   |
|      | `--notify`      | Enable/disable desktop alerts (`true` / `false`)               | `true`                 |
| `-v` | `--verbosity`   | Log level: `0` (Silent), `1` (Errors), `2` (Info), `3` (Debug) | `2`                    |
| `-h` | `--help`        | Show help message                                              |                        |

## How It Works

1. Fetches the repository list via `gh repo list --limit 1000 --json name`.
2. For each repo, checks if `<repo>.git` exists in the backup directory:
   - If exists: runs `git -C <repo>.git remote update --prune`
   - If not: runs `gh repo clone <repo> <repo>.git -- --mirror`
3. Executes jobs in parallel via `xargs -P <concurrency>`.
4. On failure (rate limit `403`/`503`, network error), retries with exponential backoff: `delay = min(delay * 2, MAX_DELAY)`.
5. Sends desktop notifications on start, completion, and permanent failure.

## License

MIT
