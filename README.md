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

- **Team 10 (CPU group)** contributed a 4-thread in-order ARM pipeline processor
- **Team 2 (GPU group)** contributed a programmable BF16 tensor core GPU

Both processors share a dual-port BRAM and are controlled via the NetFPGA UDP register interface. The ARM core handles integer packet header processing; the GPU core performs 4-lane BF16 floating-point fused multiply-accumulate (FMA) operations.

---

## Repository Structure

```
├── CPU/                        # Team 10 — ARM pipeline (original subteam source)
├── GPU/                        # Team 2 — GPU pipeline (original subteam source)
├── src/                        # Integrated NetFPGA synthesis source (merged)
│   ├── fifo_top.v              # NetFPGA top-level (Lab 8, unchanged)
│   ├── arm_cpu_wrapper.v       # ARM BRAM bridge state machine
│   ├── arm_pipeline.v          # 4-thread ARM pipeline (IF/ID/EX/MEM/WB)
│   ├── arm_regfile.v           # Dual mirrored BRAM register file
│   ├── arm_alu.v
│   ├── imem.v / dmem_32.v      # ARM memories
│   ├── convertible_fifo.v      # 256x72-bit shared dual-port BRAM
│   ├── gpu_net.v               # Adapter: Lab 8 interface -> gpu_core_min
│   ├── gpu_core_min.v          # Programmable GPU: 7-state multi-cycle FSM
│   ├── gpu_imem_rom.v          # GPU instruction ROM (bf16_fma kernel)
│   ├── gpu_regfile_min.v       # GPU 8x64-bit BRAM register file
│   ├── gpu_ldst.v              # GPU LD64/ST64 load-store unit
│   ├── tensor_unit.v           # 4-lane parallel BF16 MAC
│   ├── bf16_mac.v              # BF16 fused multiply-accumulate
│   └── isa_defines.vh          # GPU ISA definitions
├── include/                    # Shared header files
├── results/                    # Bitfile, simulation screenshots, test logs
├── fifoctl_lab9                # NetFPGA register access utility
├── lab9_joint_test_final.pl    # Hardware test script (PASS: 6 / FAIL: 0)
├── Lab9_Report_Team10&2.docx   # Lab report
├── lab9_architecture_spec.docx # Architecture specification
└── README.md
```

> **Note:** `GPU/` contains Team 2's original 5-stage pipeline GPU, verified in ISim simulation (PASS: 6/0). The `src/` directory contains the hardware-integrated version adapted to fit the NetFPGA xc2vp50 resource constraints.



---

## GPU Kernel (bf16_fma)

The GPU executes a 6-instruction kernel that computes `A x B + C` in BF16 across 4 parallel lanes:

```
PC=0  READ_TID  R1           -- R1 = threadIdx.x (= 0)
PC=1  LD64 R2, R0, 0         -- R2 = BRAM[0]  (Vec A: 2.0 x 4)
PC=2  LD64 R3, R0, 8         -- R3 = BRAM[1]  (Vec B: 1.5 x 4)
PC=3  LD64 R4, R0, 16        -- R4 = BRAM[2]  (Vec C: 0.5 x 4)
PC=4  BF_MAC R5, R2, R3, R4  -- R5 = 2.0*1.5+0.5 = 3.5  (BF16 x 4)
PC=5  ST64 R5, R1, 0         -- BRAM[0] = R5  (result: 0x4060 x 4)
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
| RDATA_CTRL | 0x2000120 | Read control (port select) |
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
