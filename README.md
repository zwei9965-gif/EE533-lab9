# EE533 Lab 9 — ARM CPU + Programmable GPU on NetFPGA

**lab9-merge CPU and GPU from 2 subteams (Team 10 & Team 2)**

USC EE533 Spring 2026 | Platform: NetFPGA xc2vp50 | Toolchain: Xilinx ISE 10.1

---

## Hardware Demo Result

```
PASS: 6   FAIL: 0   ALL PASS
Board: nf4.usc.edu
```

---

## Project Overview

This lab integrates two independently developed processors onto a single NetFPGA board:

- **Team 10 (CPU group)** — 4-thread in-order ARM pipeline processor
- **Team 2 (GPU group)** — programmable BF16 tensor core GPU

Both processors share a dual-port BRAM and are controlled via the NetFPGA UDP register interface. The ARM core handles integer packet header processing; the GPU core performs 4-lane BF16 fused multiply-accumulate (A×B+C) operations.

Each group also developed a complete software toolchain: the CPU group provides an ARM assembler (`asm2bin_v3.py`) that compiles GCC-generated ARM assembly to machine code; the GPU group provides a CUDA PTX compiler (`ptx_parser.py`) that translates real NVCC output into the custom GPU ISA.

---

## Repository Structure

```
├── CPU/                        # Team 10 — ARM pipeline (original subteam source)
├── GPU/                        # Team 2 — GPU pipeline (original subteam source)
├── armisatoolchain/            # Team 10 — ARM software toolchain
│   ├── sort_simple.c           # Bubble sort C source (-O1, no stack frame)
│   ├── sort_gcc.s              # GCC 15.2 ARM assembly output (armv4t)
│   └── asm2bin_v3.py           # ARM32 assembler: .s → machine code hex
├── kernel/                     # Team 2 — GPU software toolchain
│   ├── kernel.cu               # CUDA source (bf16_fma, int16_vector_add, etc.)
│   ├── kernel.ptx              # Real NVCC 13.1 PTX output (sm_80)
│   ├── ptx_parser.py           # PTX → GPU ISA compiler
│   └── bf16_utils.py           # BFloat16 ↔ float32 conversion utilities
├── src/                        # Integrated NetFPGA synthesis source
│   ├── fifo_top.v              # NetFPGA top-level (Lab 8, unchanged)
│   ├── arm_cpu_wrapper.v       # ARM BRAM bridge state machine
│   ├── arm_pipeline.v          # 4-thread ARM pipeline (IF pre-fetch fix)
│   ├── arm_regfile.v           # Dual mirrored BRAM register file
│   ├── convertible_fifo.v      # 256×72-bit shared dual-port BRAM
│   ├── gpu_net.v               # Adapter: Lab 8 → gpu_core_min
│   ├── gpu_core_min.v          # Programmable GPU: 7-state multi-cycle FSM
│   ├── gpu_imem_rom.v          # GPU instruction ROM (bf16_fma kernel, 6 instrs)
│   ├── gpu_regfile_min.v       # GPU 8×64-bit BRAM register file
│   ├── gpu_ldst.v              # GPU LD64/ST64 load-store unit
│   ├── tensor_unit.v           # 4-lane parallel BF16 MAC
│   ├── bf16_mac.v              # BF16 fused multiply-accumulate
│   └── isa_defines.vh          # GPU ISA opcode definitions
├── include/                    # Shared header files
├── results/                    # Bitfile, simulation screenshots, test logs
├── fifoctl_lab9                # NetFPGA register access utility
├── lab9_joint_test_final.pl    # Hardware test script (PASS: 6 / FAIL: 0)
├── lab9_architecture_spec.docx     # Architecture specification (initial)
├── lab9_architecture_spec_v2.docx  # Architecture specification (updated, final)
├── Lab9_Report_Team10&2_Final.docx # Lab report
└── README.md
```

---

## Software Toolchains

### ARM Toolchain (Team 10 — armisatoolchain/)

Compiles a C bubble sort program to ARM machine code for the processor.

```bash
# Step 1: Compile C to ARM assembly (requires arm-none-eabi-gcc)
arm-none-eabi-gcc -O1 -S -march=armv4t -marm sort_simple.c

# Step 2: Assemble to machine code hex with annotated disassembly
python3 asm2bin_v3.py sort_gcc.s --dump

# Step 3: Generate COE file for ISE BRAM initialization
python3 asm2bin_v3.py sort_gcc.s --format coe -o imem.coe --dmem-out dmem.coe
```

The assembler handles the full GCC -O1 instruction set: conditional execution (`strgt`, `suble`), pre/post-index addressing (`[Rn,#off]!`, `[Rn],#off`), PC-relative literal pool loads, register-shifted operands (`add r0,r0,r3,lsl #2`), `push`/`pop`, `bl`, `subs`, and separate `.text`/`.data` sections.

**Bubble sort memory dump** — array `{323, 123, -455, 2, 98, 125, 10, 65, -56, 0}`:
```
Before: [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]
After:  [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]  ✓ sorted
```

### GPU Toolchain (Team 2 — kernel/)

Compiles a CUDA kernel through PTX to the custom GPU ISA.

```bash
# Step 1: Compile CUDA to PTX (requires NVIDIA CUDA Toolkit)
nvcc --ptx -arch=sm_80 kernel.cu

# Step 2: Compile PTX to GPU ISA machine code
python3 ptx_parser.py kernel.ptx
# Output: gpu_program.hex (6 instructions)

# Step 3: Verify BF16 arithmetic
python3 bf16_utils.py
```

The ptx_parser.py output matches gpu_imem_rom.v exactly:

| PC | Hex | GPU ISA | Operation |
|----|-----|---------|-----------|
| 0 | 04400000 | READ_TID R1 | R1 = threadIdx.x = 0 |
| 1 | 0C800000 | LD64 R2, R0, 0 | R2 = BRAM[0] (Vec A) |
| 2 | 0CC00008 | LD64 R3, R0, 8 | R3 = BRAM[1] (Vec B) |
| 3 | 0D000010 | LD64 R4, R0, 16 | R4 = BRAM[2] (Vec C) |
| 4 | 8548D000 | BF_MAC R5,R2,R3,R4 | R5 = 2.0×1.5+0.5 = 3.5 |
| 5 | 11440000 | ST64 R5, R1, 0 | BRAM[0] = R5 (0x4060×4) |

> **Note on static ROM:** Both instruction memories are currently hardcoded as case ROMs synthesized into the bitfile (106% Slice utilization left no room for writable RAMs). The toolchains validate the full compilation flow; dynamic program loading is the primary planned future enhancement.

---

## System Architecture

```
Host (lab9_joint_test_final.pl)
        |  UDP register interface
        v
   fifo_top.v  (Lab 8 top-level, unchanged)
   +------------------------------------------+
   |   convertible_fifo  (256x72 BRAM)        |
   |          +-----------+-----------+        |
   |   arm_cpu_wrapper         gpu_net         |
   |          |                    |           |
   |   arm_pipeline          gpu_core_min      |
   |   (4-thread ARM)        (7-state FSM)     |
   +------------------------------------------+
```

---

## Register Map

| Register | Address | Description |
|----------|---------|-------------|
| CMD | 0x2000100 | [2]=reset, [3]=ARM_start, [4]=GPU_start |
| PROC_ADDR | 0x2000104 | BRAM word address |
| WDATA_HI | 0x2000108 | Write data [63:32] |
| WDATA_LO | 0x200010C | Write data [31:0] |
| WDATA_CTRL | 0x2000110 | Write enable toggle (bit[8]) |
| STATUS | 0x2000114 | FIFO status |
| RDATA_HI | 0x2000118 | Read data [63:32] |
| RDATA_LO | 0x200011C | Read data [31:0] |
| RDATA_CTRL | 0x2000120 | Read control |
| POINTERS | 0x2000124 | [0]=arm_done, [2]=gpu_done |

---

## Running the Hardware Test

```bash
# On NetFPGA node
nf_download results/nf2_top_par.bit
rkd &
perl lab9_joint_test_final.pl
```

Expected output:
```
PASS  Header word 0 (+1)
PASS  Header word 1 (+1)
PASS  GPU2 Vec A readback
PASS  GPU2 Vec B readback
PASS  GPU2 Vec C readback
PASS  GPU2 BF_MAC result (3.5)
================================================================
  PASS: 6   FAIL: 0
================================================================
  ALL PASS
```

---

## Team Members

**Team 10 — CPU Group**
- Yijin Chen
- Chenyang Zhang
- Zhenglin Wei

**Team 2 — GPU Group**
- Kevelyn Lin
- Yuxiang Luo
- Ian Chen
