# Margin real-agent benchmark

4 of 4 models scored 100/100; all source-preservation checks passed: true.

Fastest: `openai/gpt-5.6-terra`. Lowest measured cost: `openai/gpt-5.6-luna`. Total measured cost: $0.2168.

The harness retained command shapes, scores, hashes, timing, and usage only. It did not persist model output, stderr, sessions, credentials, or environment values.

| Model | Score | Seconds | Input tokens | Output tokens | Cost | Source preserved |
|---|---:|---:|---:|---:|---:|:---:|
| openai/gpt-5.6-terra | 100/100 | 27.5 | 12575 | 1207 | $0.0584 | true |
| openai/gpt-5.6-luna | 100/100 | 31.53 | 14783 | 2030 | $0.0068 | true |
| openai/gpt-5.6-sol | 100/100 | 32.643 | 14528 | 1430 | $0.1432 | true |
| openrouter/deepseek/deepseek-v4-flash | 100/100 | 68.9 | 17787 | 4307 | $0.0083 | true |
