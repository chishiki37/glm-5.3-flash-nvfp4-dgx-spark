#!/usr/bin/env python3
"""GSM8K benchmark runner — works against any OpenAI-compatible endpoint.
Downloads canonical GSM8K from openai/grade-school-math, runs N questions,
extracts #### X format answers, compares against ground truth.

Usage:
  python3 gsm8k_benchmark.py --base-url http://100.102.97.64:8000/v1 --model glm-5.3-flash --temp 0.2 --questions 50

Key parameters for reasoning models:
  --max-tokens 8192    (reasoning models burn tokens on reasoning_content before answering)
  --timeout 1800       (at slow local decode, a hard problem can take 1000+ seconds)
"""
import json, time, sys, re, os, argparse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--base-url", required=True)
parser.add_argument("--model", required=True)
parser.add_argument("--temp", type=float, default=0.2)
parser.add_argument("--questions", type=int, default=50)
parser.add_argument("--max-tokens", type=int, default=8192)
parser.add_argument("--timeout", type=int, default=1800)
parser.add_argument("--api-key", default="")
parser.add_argument("--output", default="/tmp/gsm8k-results.json")
parser.add_argument("--thinking", default="off", choices=["on", "off"])
args = parser.parse_args()

GSM8K_URL = "https://raw.githubusercontent.com/openai/grade-school-math/master/grade_school_math/data/test.jsonl"
with urllib.request.urlopen(GSM8K_URL, timeout=30) as r:
    lines = r.read().decode().strip().split("\n")
questions = []
for line in lines[:args.questions]:
    d = json.loads(line)
    m = re.search(r'####\s*(-?[\d,.]+)', d['answer'])
    expected = m.group(1).replace(',', '') if m else ''
    questions.append({"question": d['question'], "expected": expected})

print(f"Loaded {len(questions)} canonical GSM8K questions", flush=True)
BASE = args.base_url.rstrip('/')

def chat(question):
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": f"Solve this math problem step by step. At the end, write '#### X' where X is your final numerical answer.\n\n{question}"}],
        "temperature": args.temp,
        "max_tokens": args.max_tokens,
        "chat_template_kwargs": {"enable_thinking": args.thinking == "on"},
    }
    req = urllib.request.Request(f"{BASE}/chat/completions", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {args.api_key}"})
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as r:
            d = json.loads(r.read().decode())
        return d["choices"][0]["message"].get("content", ""), d.get("usage", {})
    except Exception as e:
        return f"ERROR: {e}", {}

def extract_answer(text):
    m = re.findall(r'####\s*(-?[\d,.]+)', text)
    if m:
        return m[-1].replace(',', '').strip()
    lines = [l.strip() for l in text.split('\n') if l.strip()]
    for line in reversed(lines[-8:]):
        if re.search(r'\bkm\b|\bper\b|inciden|for reference', line, re.I):
            continue
        matches = re.findall(r'(?:=|answer is|total is|change is|profit is|interest is|left is)\s*\$?\s*(-?[\d,.]+)', line, re.I)
        if matches:
            return matches[-1].replace(',', '').replace('$', '').strip()
    m = re.findall(r'-?\d+(?:\.\d+)?', text.replace(',', ''))
    if m:
        return m[-1]
    return ""

correct = 0
results = []
for i, q in enumerate(questions):
    t0 = time.time()
    content, usage = chat(q["question"])
    elapsed = time.time() - t0
    got = extract_answer(content)
    try:
        ok = abs(float(got) - float(q["expected"])) < 0.01 if got else False
    except Exception:
        ok = False
    if ok:
        correct += 1
    toks = usage.get("completion_tokens", 0)
    is_timeout = toks == 0 or elapsed >= args.timeout - 5
    status = "OK" if ok else ("TIMEOUT" if is_timeout else "WRONG")
    print(f"  [{i+1}/{len(questions)}] {status} exp={q['expected']} got={got} ({elapsed:.1f}s, {toks}t)", flush=True)
    results.append({"i": i, "expected": q["expected"], "got": got, "correct": ok,
                    "time_s": round(elapsed, 1), "tokens": toks,
                    "answer_tail": content[-300:] if content else ""})

acc = correct / len(questions) * 100
print(f"\n{'='*50}\n  GSM8K: {correct}/{len(questions)} ({acc:.1f}%)\n{'='*50}")
out = {"benchmark": "GSM8K", "base_url": BASE, "model": args.model,
       "correct": correct, "total": len(questions), "accuracy": acc, "results": results}
with open(args.output, 'w') as f:
    json.dump(out, f, indent=2)
print(f"Saved to {args.output}")
