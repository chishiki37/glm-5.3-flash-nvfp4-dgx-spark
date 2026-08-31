#!/usr/bin/env python3
"""Corruption probe for GLM-5.3-Flash NVFP4 quants (per tonyd2wild repos / vLLM #54150).
Korean + English prompts, temperature 0, non-streaming, N passes; counts U+FFFD and
non-printable garbage. Verdict: PASS if 0 corrupted across all passes.
Usage: korean_probe.py [--url URL] [--passes 3]"""
import json, subprocess, argparse, sys

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://10.10.10.14:8000/v1/chat/completions")
ap.add_argument("--model", default="glm-5.3-flash")
ap.add_argument("--passes", type=int, default=3)
a = ap.parse_args()

PROMPTS = [
    "한국어로 간단한 자기소개를 작성하세요. 안녕하세요, 저는 도움이 되는 AI 어시스턴트입니다.",
    "Write a Python function that checks whether a number is prime.",
    "다음 문장을 영어로 번역하세요: 오늘 날씨가 정말 좋네요.",
]

bad = 0
for p in range(a.passes):
    for i, content in enumerate(PROMPTS):
        body = json.dumps({"model": a.model,
                           "messages": [{"role": "user", "content": content}],
                           "max_tokens": 200, "temperature": 0,
                           "chat_template_kwargs": {"enable_thinking": False}})
        r = subprocess.run(["curl", "-sS", "--max-time", "180", a.url,
                            "-H", "Content-Type: application/json", "-d", body],
                           capture_output=True, text=True, timeout=190)
        try:
            d = json.loads(r.stdout)
            txt = d["choices"][0]["message"]["content"] or ""
            finish = d["choices"][0].get("finish_reason", "?")
        except Exception as e:
            print(f"pass{p} prompt{i}: PARSE-FAIL {str(e)[:80]}: {r.stdout[:120]!r}")
            bad += 1
            continue
        ufffd = txt.count("\ufffd")
        ctrl = sum(1 for ch in txt if ord(ch) < 9 or (13 < ord(ch) < 32))
        status = "OK" if ufffd == 0 and ctrl == 0 else "CORRUPT"
        if status == "CORRUPT":
            bad += 1
        print(f"pass{p} prompt{i}: {status} ufffd={ufffd} ctrl={ctrl} finish={finish} len={len(txt)} sample={txt[:60]!r}")

print(f"\nVERDICT: {'PASS - no corruption detected' if bad == 0 else f'FAIL - {bad} corrupted/failed responses'}")
sys.exit(0 if bad == 0 else 1)
