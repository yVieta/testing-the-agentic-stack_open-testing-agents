#!/usr/bin/env python3
import argparse
import json
import sys
import http.client

def main():
    parser = argparse.ArgumentParser(description='Interact with local phi-4-mini model')
    parser.add_argument('prompt', nargs='*', help='Prompt to send')
    parser.add_argument('--system', '-s', default='', help='System message')
    parser.add_argument('--temp', type=float, default=0.2, help='Temperature')
    parser.add_argument('--max-tokens', type=int, default=256, help='Max tokens')
    parser.add_argument('--host', default='127.0.0.1', help='Model host')
    parser.add_argument('--port', type=int, default=18080, help='Model port')
    parser.add_argument('--model', default='phi-4-mini', help='Model name')
    parser.add_argument('--interactive', '-i', action='store_true', help='Interactive chat mode')
    args = parser.parse_args()

    if args.interactive:
        print(f'Interactive chat with {args.model} at {args.host}:{args.port} (Ctrl+C to exit)')
        messages = []
        if args.system:
            messages.append({'role': 'system', 'content': args.system})
        try:
            while True:
                try:
                    user = input('> ').strip()
                except EOFError:
                    break
                if not user:
                    continue
                if user.lower() in ('/quit', '/exit'):
                    break
                messages.append({'role': 'user', 'content': user})
                resp = query(messages, args.host, args.port, args.model, args.temp, args.max_tokens)
                if resp:
                    print(resp)
                    messages.append({'role': 'assistant', 'content': resp})
                else:
                    messages.pop()
        except KeyboardInterrupt:
            pass
        return

    prompt = ' '.join(args.prompt) if args.prompt else sys.stdin.read().strip()
    if not prompt:
        parser.print_help()
        return
    messages = []
    if args.system:
        messages.append({'role': 'system', 'content': args.system})
    messages.append({'role': 'user', 'content': prompt})
    resp = query(messages, args.host, args.port, args.model, args.temp, args.max_tokens)
    if resp:
        print(resp)

def query(messages, host, port, model, temp, max_tokens):
    try:
        conn = http.client.HTTPConnection(host, port, timeout=300)
        payload = {
            'model': model,
            'messages': messages,
            'temperature': temp,
            'max_tokens': max_tokens,
        }
        conn.request('POST', '/v1/chat/completions', body=json.dumps(payload),
                     headers={'Content-Type': 'application/json'})
        resp = conn.getresponse()
        data = json.loads(resp.read())
        return data['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f'Error: {e}', file=sys.stderr)
        return None

if __name__ == '__main__':
    main()
