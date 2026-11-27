# Sharing the RTX 2080 Ti between Plex transcoding, Immich ML and a local LLM

Research date: 2026-11-26. Status: findings only, no decision taken.

Question: can one RTX 2080 Ti (11 GB GDDR6, Turing TU102, compute capability 7.5)
serve Plex hardware transcoding (NVENC/NVDEC), Immich machine learning and a light
local LLM at the same time on the new Docker Compose host? What does each workload
cost in VRAM, how is the GPU shared between containers, which LLM runtimes still
support Turing, which models fit, what does it cost in power, and how long will
NVIDIA keep supporting Turing?

Every claim carries its source. Figures marked "estimate" or "community report" are
not from a first-party source and must be measured on the real host with
`nvidia-smi` before they drive a decision.

## 1. Summary

- Turing is still a fully supported, current architecture in late 2026. The newest
  Linux driver (620.73.04, branch R620) lists the RTX 2080 Ti in its supported
  chips; the 580.xx branch is the legacy branch for Maxwell/Pascal/Volta, not for
  Turing. CUDA 13.5 still targets Turing and announces no deprecation for it.
- NVIDIA's support matrix now lists 12 concurrent NVENC sessions for GeForce
  cards, including the RTX 2080 Ti. That is far above what a family/friends Plex
  server needs, and Immich's own video transcoding shares the same pool.
- Containers share the GPU through the NVIDIA Container Toolkit with plain time
  slicing. There is no memory or fault isolation (MIG does not exist on Turing or
  GeForce). VRAM is the real constraint, not compute and not NVENC sessions.
- Ollama and llama.cpp support compute capability 7.5 in their current builds.
  vLLM still accepts 7.5 as its minimum, but its fast attention backends
  (FlashAttention, FlashInfer) are off on Turing and it pre-allocates most of the
  VRAM by default, which makes it a poor neighbour on a shared card.
- A rough budget leaves about 5-6 GB for the LLM while Plex and Immich are active,
  which fits a 4B model comfortably and an 8B Q4_K_M model with a short context.
- Idle draw of a reference 2080 Ti is about 13 W card-only (measured on Windows
  with a display attached). Passing the card to a VM gives that VM the GPU
  exclusively and removes it from every container on the host.

## 2. NVIDIA driver and CUDA support for Turing

| Fact | Source |
|---|---|
| Latest Linux x86_64 driver published: 620.73.04 (branches seen in the archive: 595, 610, 615, 620). | [download.nvidia.com latest.txt](https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt), [archive index](https://download.nvidia.com/XFree86/Linux-x86_64/) |
| The 620.73.04 README "supported chips" appendix lists "NVIDIA GeForce RTX 2080 Ti" (device IDs 1E04 and 1E07) among current GPUs. Its legacy section lists the legacy branches 304, 340, 367, 390, 470 and 580; the GTX 1080 Ti appears under the legacy GPUs. | [620.73.04 README, Appendix A](https://download.nvidia.com/XFree86/Linux-x86_64/620.73.04/README/supportedchips.html) |
| The R590 driver branch was the cutoff for Maxwell, Pascal and Volta; those GPUs stay on the 580 legacy branch. Turing (GTX 16 / RTX 20) and newer continue on the current branches. | [620.73.04 README legacy list](https://download.nvidia.com/XFree86/Linux-x86_64/620.73.04/README/supportedchips.html); press coverage: [Tom's Hardware](https://www.tomshardware.com/pc-components/gpu-drivers/nvidia-to-axe-maxwell-pascal-and-volta-gpus-with-end-of-driver-support-580-series-drivers-will-be-the-last-to-support-gtx-900-and-1000-cards), [Wccftech](https://wccftech.com/nvidia-bids-farewell-to-maxwell-pascal-volta-gpus-in-geforce-590-drivers/) |
| Current CUDA is 13.5 (driver branch R620). Its deprecation section on architectures only announces an ARM64-SBSA change for CUDA 14.0. The only Turing mentions are in cuFFT/cuSPARSE 13.0 notes that dropped support for "pre-Turing" GPUs. | [CUDA Toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html) |
| CUDA 13.x minor-version compatibility requires driver >= 580. | same page, Table 3 |
| NVIDIA still publishes a Turing Compatibility Guide for CUDA 13.4. | [Turing Compatibility Guide (13.4.2)](https://docs.nvidia.com/cuda/archive/13.4.2/pdf/Turing_Compatibility_Guide.pdf) |
| The open GPU kernel modules (which NVIDIA now ships as the default flavour) work on "any Turing or later GPU"; the repo is at version 620.73.04. | [open-gpu-kernel-modules README](https://github.com/NVIDIA/open-gpu-kernel-modules) |

What came before: Maxwell/Pascal/Volta were first marked "feature-complete" in CUDA
12.8 ([The Register](https://www.theregister.com/2025/01/27/nvidia_deprecates_cuda_support/)),
then lost offline compilation and library support in CUDA 13.0, and moved to a legacy
driver branch (580) about a year later. I found no equivalent "feature-complete"
notice for Turing in any CUDA 13.x release note up to 13.5. If NVIDIA follows the
same pattern for Turing, the first warning will appear in a CUDA release note,
roughly a year before Turing moves to a legacy branch. That legacy branch would
still get security fixes (as 580 does for Pascal), so the card would not stop
working overnight. This is an inference from the earlier pattern, not an
announcement.

Practical consequences:

- Keep the host on a current production branch with the open kernel modules.
  Containers built for CUDA 13 need driver >= 580; containers built for CUDA 12
  run on newer drivers too (backwards compatibility of the driver).
- Watch the "Deprecated architectures" section of each CUDA release note. Renovate
  will not warn about this; a manual check (or a recurring ticket) would.

## 3. Plex: NVENC/NVDEC transcoding

### Session limit

NVIDIA's Video Encode and Decode support matrix lists, for "GeForce RTX 2080Ti":
Turing, NVENC 7th gen, 1 chip, 1 NVENC, **12** max concurrent sessions; H.264
4:2:0/4:4:4/lossless and HEVC 4K 4:2:0/4:4:4/lossless/8K/10-bit/B-frames encode;
no AV1 encode. NVDEC is 4th gen: HEVC decode up to 12-bit 4:4:4, H.264 decode
8-bit 4:2:0 only, no AV1 decode
([NVIDIA support matrix](https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new)).

History: the GeForce limit was 3, then 5, then 8 in 2024
([Plex forum thread on the 5 to 8 change](https://forums.plex.tv/t/nvidia-increases-transcode-limits-from-5-to-8/867879)),
and the current matrix says 12. The limit counts encode sessions per system, so
Plex transcodes and Immich NVENC video transcodes come out of the same pool.

The 2080 Ti cannot decode AV1. AV1 sources will be decoded on the CPU (the
3900X has 12 cores, so it can do some of that) and then encoded on NVENC.

### Plex requirements

- Hardware-accelerated streaming needs Plex Pass (the owner has it). On Linux,
  Plex requires NVIDIA driver 450.66 or newer since PMS 1.20.2, and HEVC encoding
  needs PMS 1.41.3
  ([Plex: Using Hardware-Accelerated Streaming](https://support.plex.tv/articles/115002178853-using-hardware-accelerated-streaming/)).
- HDR to SDR tone mapping on NVIDIA under Linux and Docker needs PMS 1.29.2+
  and driver 470.141.03+
  ([Plex: HDR to SDR tone mapping](https://support.plex.tv/articles/hdr-to-sdr-tone-mapping/)).
- In Docker, the container needs `NVIDIA_DRIVER_CAPABILITIES` to include `video`
  (for NVENC/NVDEC) and `compute` (tone mapping). The variable replaces the default
  set (`utility,compute`) instead of adding to it
  ([NVIDIA Container Toolkit, specialized configurations](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html)).

### VRAM per stream

No first-party number exists. Community reports on the Plex forum vary widely:
about 350 MB for a 1080p transcode and about 0.6 to 1.5 GB for a 4K to 1080p
transcode, depending on GPU, driver, Plex version and tone mapping
([Plex forum, NVIDIA limit thread](https://forums.plex.tv/t/nvidia-increases-transcode-limits-from-5-to-8/867879),
[Plex forum, NVIDIA memory use on Linux](https://forums.plex.tv/t/nvidia-transcoding-on-linux-uses-insane-amount-of-memory/507065)).
Treat these as community reports. NVENC and NVDEC are fixed-function engines, so
an LLM saturating the CUDA cores mostly costs Plex VRAM, not encode throughput;
tone mapping runs on the shader cores and can contend with the LLM (inference
from the architecture, not measured).

## 4. Immich: machine learning and video transcoding

### Machine learning (CUDA)

- Requirements: compute capability 5.2 or greater, driver >= 545 (CUDA 12.3),
  NVIDIA Container Toolkit on Linux. Enable it with the `-cuda` image tag on
  `immich-machine-learning` and the `cuda` service from `hwaccel.ml.yml`
  ([Immich: ML hardware acceleration](https://docs.immich.app/features/ml-hardware-acceleration/)).
- "Each GPU must be able to load all models"; higher job concurrency raises VRAM
  use (same page).
- Model sizes: the Immich CLIP table gives peak process memory (RSS, CPU, f32) of
  1004 MiB for `ViT-B-32__openai`, 3622 MiB for `ViT-SO400M-14-SigLIP2__webli`,
  and 4014 MiB for the multilingual `XLM-Roberta-Large-ViT-H-14`. The page says
  these are estimates measured without acceleration
  ([Immich: searching](https://docs.immich.app/features/searching/)). VRAM on CUDA
  will be in the same range but must be measured, since the face detection and
  recognition models (and OCR, if enabled) load on top.
- Models unload after `MACHINE_LEARNING_MODEL_TTL` seconds of inactivity
  (default 300). `MACHINE_LEARNING_WORKERS` (default 1) duplicates models per
  worker, so it should stay at 1 on a shared card. `MACHINE_LEARNING_PRELOAD__*`
  keeps models loaded and should stay unset on a shared card
  ([Immich: environment variables](https://docs.immich.app/install/environment-variables/)).

Immich ML load is bursty: heavy during an initial library scan or a bulk upload,
close to zero otherwise. With the TTL, its VRAM is returned after 5 minutes idle.

### Video transcoding (NVENC)

Immich can also transcode uploaded videos with NVENC (`hwaccel.transcoding.yml`,
`nvenc` backend; by default only encoding is accelerated, decoding and tone
mapping stay on the CPU unless hardware decoding is enabled)
([Immich: hardware transcoding](https://docs.immich.app/features/hardware-transcoding/)).
These sessions count against the same 12-session NVENC limit as Plex.

## 5. Sharing the GPU: containers versus VM passthrough

### Several containers on one GPU (nvidia-container-toolkit)

- Each container gets the device through the toolkit; `NVIDIA_VISIBLE_DEVICES`
  selects GPUs by index or UUID and `NVIDIA_DRIVER_CAPABILITIES` selects driver
  features
  ([NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html)).
  Compose exposes the same thing through `deploy.resources.reservations.devices`
  ([Docker: GPU support in Compose](https://docs.docker.com/compose/how-tos/gpu-support/)).
  Nothing prevents several containers from requesting the same GPU.
- Concurrent CUDA processes are time-sliced by the driver. NVIDIA's own GPU
  sharing doc states that with time slicing "there is no memory or fault-isolation
  between replicas", whereas MIG gives hardware isolation on "the latest
  generations" of data-centre GPUs
  ([NVIDIA GPU Operator: GPU sharing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html)).
  The 2080 Ti has no MIG and GeForce cards have no vGPU/SR-IOV, so time slicing
  is the only option.
- Consequence: VRAM is first come, first served. If the LLM holds 8 GB and Plex
  then needs 1 GB for a 4K stream that is not there, the allocation fails in the
  Plex transcoder. Nothing in Docker or the driver enforces a per-container VRAM
  cap. Mitigation is on the application side: `OLLAMA_GPU_OVERHEAD` reserves VRAM
  per GPU (bytes) that Ollama will not plan for
  ([Ollama envconfig](https://github.com/ollama/ollama/blob/main/envconfig/config.go)),
  short keep-alive and TTL values free memory when idle, and the model size caps
  the rest.
- Each CUDA process creates its own context, which costs a few hundred MB of VRAM
  per process (estimate; measure with `nvidia-smi`).

### Exclusive passthrough to a VM

- NVIDIA has allowed GeForce passthrough to a VM since the R465 drivers (it used to
  trigger "Code 43" in Windows guests). Only one VM can own the card; GeForce has
  no SR-IOV ([StorageReview](https://www.storagereview.com/news/nvidia-enables-beta-support-for-virtualization-on-geforce-gpus),
  [vfio-users list](https://listman.redhat.com/archives/vfio-users/2021-March/005244.html)).
- With VFIO the host driver releases the device, so containers on the host (Plex,
  Immich) lose access to it. Sharing would then require all three workloads to run
  inside that VM, which brings back the container model one level down.
- The Ryzen 9 3900X has no integrated graphics, so the 2080 Ti is also the only
  local display output; passing it through leaves the host without a console on a
  screen (serial/IPMI-less boards make that a recovery problem).

Passthrough makes sense only if a hypervisor layer is chosen for other reasons
(for example a Windows gaming VM). For this workload mix it removes sharing
instead of enabling it.

## 6. LLM runtimes and Turing (compute capability 7.5)

| Runtime | Latest seen | Turing status | Sharing behaviour | Source |
|---|---|---|---|---|
| Ollama | v0.40.18 (2026-11-24) | Supported: CC 5.0+ with driver 550+; RTX 2080 Ti listed under 7.5. Ships a CUDA 12 build (native `75`) and a CUDA 13 build (`75-virtual`). | Loads on demand, unloads after `OLLAMA_KEEP_ALIVE` (default 5 min), checks free VRAM before loading, `OLLAMA_GPU_OVERHEAD` reserve, falls back to partial CPU offload when VRAM is short, flash attention enabled automatically where supported, KV cache quantization (`OLLAMA_KV_CACHE_TYPE=q8_0` halves KV memory). Default context 4096. | [gpu.mdx](https://github.com/ollama/ollama/blob/main/docs/gpu.mdx), [faq.mdx](https://github.com/ollama/ollama/blob/main/docs/faq.mdx), [CMakePresets](https://github.com/ollama/ollama/blob/main/llama/server/CMakePresets.json), [releases](https://github.com/ollama/ollama/releases) |
| llama.cpp (`llama-server`) | v1.1.0 (2026-11-26) | Supported: default CUDA build includes `75-virtual`; source defines `GGML_CUDA_CC_TURING` and uses Turing tensor-core (MMA) kernels. | Model stays loaded for the life of the process; VRAM use fixed by `-ngl`, context size and KV type. Most control, least automation. | [ggml-cuda CMakeLists](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-cuda/CMakeLists.txt), [common.cuh](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-cuda/common.cuh), [releases](https://github.com/ggml-org/llama.cpp/releases) |
| vLLM | v0.34.0 (2026-11-16) | Minimum CC 7.5 ("T4, RTX20xx"). Wheels are CUDA 13.0. FlashAttention backend requires CC >= 8.0; FlashInfer is temporarily disabled on SM75 (open bug); Turing falls back to the Triton attention backend. Quantization: AWQ, GPTQ, bitsandbytes, GGUF, INT8 W8A8 work on Turing; FP8 does not; Marlin works except MXFP4. | Pre-allocates GPU memory for the KV cache: `gpu_memory_utilization` defaults to 1.0 with the extensible KV cache (0.92 otherwise). The docs say to set it when other processes share the GPU. Built for throughput with many parallel users. | [vLLM GPU install](https://docs.vllm.ai/en/latest/getting_started/installation/gpu.html), [flash_attn.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/attention/backends/flash_attn.py), [flashinfer.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/attention/backends/flashinfer.py), [triton_attn.py](https://github.com/vllm-project/vllm/blob/main/vllm/v1/attention/backends/triton_attn.py), [quantization README](https://github.com/vllm-project/vllm/blob/main/docs/features/quantization/README.md), [cache config](https://github.com/vllm-project/vllm/blob/main/vllm/config/cache.py) |

Reading of the table:

- Ollama is built around the "load when asked, unload when idle" pattern that a
  shared card needs, and it is one container with an OpenAI-compatible API. It
  wraps llama.cpp, so it trails upstream llama.cpp a little on new models and
  kernels.
- llama.cpp directly gives full control (exact context, KV quantization, layers on
  GPU) but keeps the model resident; on-demand loading would need an extra
  component in front of it.
- vLLM is the wrong tool for this card: its fast kernels are Ampere+, its memory
  model assumes it owns the GPU, and its strength (batching many users) is not the
  need of a personal assistant.

## 7. Which models fit next to the other workloads

### VRAM budget (planning estimates)

| Consumer | Typical | Worst case | Basis |
|---|---|---|---|
| Driver/CUDA contexts (3 to 4 processes) | 0.5 GB | 1 GB | estimate, measure |
| Plex | 0.35 GB per 1080p transcode | about 1 to 1.5 GB per 4K transcode, times concurrent streams | community reports (section 3) |
| Immich ML (default CLIP + faces) | 0 GB idle (TTL) | about 1.5 to 2 GB during jobs; 4+ GB with a large CLIP model | Immich docs plus estimate (section 4) |
| Immich NVENC transcode | 0 GB idle | about 0.5 GB per upload being transcoded | estimate, same class as Plex |
| Total, non-LLM | about 1 GB | about 5 GB (2 x 4K Plex + Immich job) | |
| Left for the LLM | about 9.5 GB | about 5.5 GB | of 11 GB |

### Candidate models (Ollama library file sizes, Q4_K_M unless noted)

| Model | File size | Default context |
|---|---|---|
| `qwen3.5:4b-q4_K_M` | 3.3 GB | 256K max |
| `gemma3:4b` | 3.4 GB | 128K max |
| `phi4-mini:3.8b` | 2.5 GB | 128K max |
| `granite4:3b` (micro) | 2.1 GB | 128K max |
| `ministral-3:3b` | 3.0 GB | 256K max |
| `llama3.1:8b` | 4.9 GB | 128K max |
| `qwen3:8b` | 5.2 GB | 40K max |
| `ministral-3:8b` | 6.0 GB | 256K max |
| `qwen3.5:9b-q4_K_M` | 6.6 GB | 256K max |
| `gemma4:12b-it-qat` | 7.2 GB | 256K max |

Sources: tag pages on ollama.com for
[qwen3.5](https://ollama.com/library/qwen3.5/tags),
[qwen3](https://ollama.com/library/qwen3/tags),
[gemma3](https://ollama.com/library/gemma3/tags),
[gemma4](https://ollama.com/library/gemma4/tags),
[llama3.1](https://ollama.com/library/llama3.1/tags),
[ministral-3](https://ollama.com/library/ministral-3/tags),
[granite4](https://ollama.com/library/granite4/tags),
[phi4-mini](https://ollama.com/library/phi4-mini/tags).
The "max" context is what the model supports, not what Ollama allocates; Ollama
uses 4096 tokens unless `OLLAMA_CONTEXT_LENGTH` or `num_ctx` say otherwise
([faq.mdx](https://github.com/ollama/ollama/blob/main/docs/faq.mdx)).

VRAM at runtime = file size + KV cache (grows linearly with context; halved by
`q8_0` KV cache) + compute buffers. Rough fit against the 5.5 GB worst case:

- 3B to 4B models at Q4 (2 to 3.5 GB files) fit with room for 8K to 16K context.
- 8B models at Q4_K_M (4.9 to 6 GB files) fit only with a short context and a
  quantized KV cache, or when Plex is quiet. If VRAM runs out at load time, Ollama
  splits layers to the CPU (shown as `CPU/GPU` in `ollama ps`) and slows down.
- 9B to 12B models (6.6 to 8 GB) only fit when nothing else uses the GPU.
- Anything 27B and up does not fit; partial offload to the 32 GB of system RAM is
  possible but slow and competes with the rest of the stack for RAM.

The 2080 Ti has no FP8 or FP4 tensor-core support (FP8 needs Ada/Hopper per the
vLLM table), so the `nvfp4`/`mxfp8` tags in the Ollama library bring no benefit on
this card; GGUF Q4_K_M/Q5_K_M or QAT builds are the relevant formats.

## 8. Power and energy management

| Fact | Source |
|---|---|
| Reference RTX 2080 Ti, card only: 13 W idle, 22 W Blu-ray playback (Windows desktop, one display). Launch driver measured 20 W idle, which NVIDIA said a driver update would fix. | [TechPowerUp, MSI 2080 Ti Lightning Z review, power page](https://www.techpowerup.com/review/msi-geforce-rtx-2080-ti-lightning-z/30.html) (charts `power_idle.png`, `power_bluray.png`); [TechPowerUp 2080 Ti FE review, power page](https://www.techpowerup.com/review/nvidia-geforce-rtx-2080-ti-founders-edition/31.html) |
| Founders Edition: about 273 W gaming, sitting at its power limit (260 W board power). Factory-overclocked cards idle higher (19 W for the Lightning Z). | same TechPowerUp pages; [KitGuru FE review](https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-2080-ti-founders-edition-11gb-review/16/) |
| Without persistence, the Linux driver initializes and tears down the GPU state each time the last client goes away, which costs load time; NVIDIA replaces the legacy "persistence mode" with the `nvidia-persistenced` daemon. | [NVIDIA Driver Persistence: background](https://docs.nvidia.com/deploy/driver-persistence/background.html) |

Points for the owner (to measure on the host, not taken from a source):

- A headless Linux server is a different case from the Windows desktop above.
  Expected idle is in the same 10 to 20 W range, but it must be checked with
  `nvidia-smi --query-gpu=pstate,power.draw --format=csv` both with nothing loaded
  and with an LLM resident (a loaded model holds VRAM; it should not keep the GPU
  out of its low power state, but this is worth verifying).
- `nvidia-smi -pl <watts>` caps board power. LLM token generation is mostly
  memory-bandwidth bound, so a lower cap (for example 150 to 200 W) usually costs
  little generation speed; prompt processing and tone mapping lose more. Needs a
  test on this card.
- Ollama keep-alive and Immich model TTL return VRAM, not power: the card idles at
  the same P-state whether VRAM is full or empty (to verify).
- The power limit and persistence daemon are host settings, so they belong in the
  Ansible host role, not in a compose file.

## 9. Pitfalls

- **No VRAM isolation.** The worst failure is a 4K Plex stream that cannot start
  because the LLM holds the memory. Size the LLM for the worst case, or accept
  that Plex may fall back to CPU transcoding at peak.
- **Driver/container skew.** CUDA 13 images (vLLM, possibly future Ollama and
  Immich images) need driver >= 580. A Renovate update to an image can need a
  newer host driver than the one pinned by Ansible.
- **Host driver upgrades need a reboot or a module reload,** which stops all three
  GPU workloads at once. The Ubuntu driver packages and the kernel must move
  together.
- **Suspend/resume:** Ollama documents that after a suspend/resume the NVIDIA UVM
  module may need reloading before the GPU is found again
  ([gpu.mdx](https://github.com/ollama/ollama/blob/main/docs/gpu.mdx)). Relevant
  only if the server ever sleeps.
- **AV1 sources** cannot be hardware-decoded on Turing.
- **vLLM defaults** grab nearly all VRAM; if it is ever tried, it must be capped.

## 10. Implications for the decision

Options that stand out:

1. **All three workloads as containers on the host GPU, Ollama as the LLM
   runtime, a 3B to 4B model by default.** Fits the worst case with headroom,
   keeps everything in Docker Compose, matches "reliability first". Ollama's
   on-demand loading, keep-alive and `OLLAMA_GPU_OVERHEAD` are the levers that
   make sharing safe. Weak point: smaller models are less capable as an assistant.
2. **Same layout with an 8B Q4 model,** accepting that a large model plus several
   4K transcodes can run out of VRAM, mitigated by quantized KV cache, a short
   context and a VRAM reserve. Better assistant quality, more tuning, more risk at
   peak.
3. **llama.cpp server instead of Ollama,** for exact control of VRAM and earlier
   access to new kernels, at the cost of a resident model (no idle unload) unless
   another tool manages loading.
4. **VM passthrough:** only worth it if a hypervisor is wanted for other reasons;
   for this mix it removes the GPU from Plex and Immich.

vLLM does not stand out for this card (Ampere-only fast paths, owns the GPU).

Questions the owner needs to answer:

- How many simultaneous remote 4K transcodes are realistic (family plus friends),
  and is a CPU fallback for Plex at peak acceptable?
- Which Immich CLIP model: the default (about 1 GB) or a multilingual/large one
  (about 4 GB)? French content may argue for a multilingual model, which takes VRAM
  from the LLM.
- What does the assistant need: quick answers from a 3B to 4B model, or better
  reasoning from an 8B model with less headroom? Is it acceptable for the model to
  unload after a few idle minutes (cold start of a few seconds)?
- Should the LLM ever be allowed to spill onto system RAM (slower, uses part of the
  32 GB), or should it fail instead?
- Is a GPU power cap wanted to reduce heat and noise in the Define 7, at the cost
  of slower prompt processing?
- Who watches for the future Turing deprecation notice in CUDA release notes (a
  recurring ticket, or a Grafana note), and what is the replacement plan when it
  comes?
