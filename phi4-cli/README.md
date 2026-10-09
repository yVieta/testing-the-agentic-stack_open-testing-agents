# phi4-cli

Simple CLI tool to interact with the local models via the OpenAI-compatible API.
Defaults to the primary **phi-4-mini** (`:18080`); `--fast` switches to the fast
**phi-mini-moe** (`:18081`).

## Requirements
Python 3 (standard library only - http.client, json, argparse)

## Usage

Single query:
```bash
./phi4.py "What is sin(0)?"
```

With system message:
```bash
./phi4.py --system "Be concise" "Explain recursion"
```

Interactive mode:
```bash
./phi4.py -i
./phi4.py -i --system "You are a coding assistant"
```

Custom host/port/model:
```bash
./phi4.py --host 127.0.0.1 --port 18080 --model phi-4-mini "Hi"
./phi4.py --fast "condense this into one sentence"   # talk to phi-mini-moe on :18081
```

Or pipe input:
```bash
echo "Summarize this" | ./phi4.py
```

