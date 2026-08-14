# Warm recorder prototype verdict

Question: can a continuously warm, memory-only recorder make F5 capture effectively instantaneous while Whisper remains the STT model?

Verdict: yes.

Measured on an M1 Pro:

- helper boot to first microphone buffer: 168 ms, paid once
- command received to recording armed: 0.001–0.074 ms across ten warm trials
- retained pre-roll: 250 ms
- STOP command to finalized 250 ms WAV: 0.9–1.5 ms
- persistent Whisper server inference for a 1.38-second WAV: approximately 872 ms

The validated production direction is a persistent AVAudioEngine recorder with an in-memory ring buffer plus a single persistent whisper.cpp server. Per-press FFmpeg and per-request `whisper-cli` processes should both be removed from the hot path.
