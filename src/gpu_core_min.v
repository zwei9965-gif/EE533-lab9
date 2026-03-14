`timescale 1ns/1ps
// ============================================================
// gpu_core_min.v — Minimal Programmable GPU Core
//
// Fixes in this version:
//   [1] ISA fields: 4-bit per isa_defines.vh
//   [2] PC managed internally, advances only after WB
//   [3] ST64 uses Rd (4th regfile read port) as store source
//       matching ISA: Mem[Rs_base + Imm] <- Rd
//   [4] BRANCH unified to word-index semantics:
//       target_pc = current_pc + sign_ext(imm18)
//       (consistent with gpu_imem_rom case(pc) word index)
//   [5] cmp_flag register set by OP_CMP_I16, used by BRANCH
//       (replaces rs1_data[0] hack)
//   [6] gpu_ldst instantiated and used for LD/ST
//
// Branch implementation note (Lab 7 / Lab 9 report):
//   cmp_flag is a single bit set by CMP_I16 (lane 0 comparison).
//   This is a simplified flag mechanism — not a full NZCV register.
//   Current thread support: single thread (threadIdx.x = 0).
//   These are documented design choices, not bugs.
// ============================================================
`include "isa_defines.vh"

module gpu_core_min (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         done,
    output reg         running,

    // Shared convertible_fifo BRAM interface
    output wire [7:0]  bram_addr,
    output wire [71:0] bram_wdata,
    output wire        bram_we,
    input  wire [71:0] bram_rdata
);
    // -------------------------------------------------------
    // FSM states
    // -------------------------------------------------------
    localparam S_IDLE   = 3'd0;
    localparam S_FETCH  = 3'd1;
    localparam S_DECODE = 3'd2;
    localparam S_EXEC   = 3'd3;
    localparam S_MEM    = 3'd4;
    localparam S_MEM2   = 3'd5;  // extra cycle for BRAM LD64 latency
    localparam S_WB     = 3'd6;
    localparam S_DONE   = 3'd7;

    reg [2:0] state;
    localparam PROG_LEN = 6;

    // -------------------------------------------------------
    // [FIX 2] PC: internal register, advances only after WB
    // -------------------------------------------------------
    reg [4:0] pc;

    // -------------------------------------------------------
    // Instruction Memory (independent from ARM, per Lab 7)
    // -------------------------------------------------------
    wire [31:0] instr_from_mem;
    reg  [31:0] instr_reg;

    gpu_imem_rom imem_inst (
        .pc    (pc),
        .instr (instr_from_mem)
    );

    // -------------------------------------------------------
    // [FIX 1] ISA field decode — 4-bit per isa_defines.vh
    // R-Type: [31:26]op [25:22]Rd [21:18]Rs1 [17:14]Rs2 [13:10]Rs3
    // I-Type: [31:26]op [25:22]Rd [21:18]Rs_base [17:0]Imm18
    // -------------------------------------------------------
    wire [5:0]  opcode    = instr_reg[31:26];
    wire [3:0]  rd_4b     = instr_reg[25:22];
    wire [3:0]  rs1_4b    = instr_reg[21:18];
    wire [3:0]  rs2_4b    = instr_reg[17:14];
    wire [3:0]  rs3_4b    = instr_reg[13:10];
    wire [17:0] imm18     = instr_reg[17:0];
    wire [63:0] imm_sext  = {{46{imm18[17]}}, imm18};

    // Map 4-bit addr → 3-bit 8-entry regfile
    wire [2:0] rd_addr  = rd_4b[2:0];
    wire [2:0] rs1_addr = rs1_4b[2:0];
    wire [2:0] rs2_addr = rs2_4b[2:0];
    wire [2:0] rs3_addr = rs3_4b[2:0];

    // -------------------------------------------------------
    // Register File (8 x 64-bit, BRAM, 4 read ports)
    // -------------------------------------------------------
    reg         rf_we;
    reg  [2:0]  rf_wr_addr;
    reg  [63:0] rf_wr_data;
    wire [63:0] rs1_data, rs2_data, rs3_data;
    wire [63:0] rd_src_data;  // [FIX 3] 4th port for ST64

    gpu_regfile_min regfile_inst (
        .clk         (clk),
        .we          (rf_we),
        .rd_addr     (rf_wr_addr),
        .rd_data     (rf_wr_data),
        .rs1_addr    (rs1_addr),
        .rs2_addr    (rs2_addr),
        .rs3_addr    (rs3_addr),
        .rd_src_addr (rd_addr),    // read Rd for ST64
        .rs1_out     (rs1_data),
        .rs2_out     (rs2_data),
        .rs3_out     (rs3_data),
        .rd_src_out  (rd_src_data)
    );

    // -------------------------------------------------------
    // Tensor Unit (4 x bf16_mac, multi-cycle)
    // -------------------------------------------------------
    reg         tensor_start;
    wire        tensor_busy, tensor_done;
    wire [63:0] tensor_result;

    tensor_unit tensor_inst (
        .clk    (clk),
        .rst    (rst),
        .start  (tensor_start),
        .rs1    (rs1_data),
        .rs2    (rs2_data),
        .rs3    (rs3_data),
        .busy   (tensor_busy),
        .done   (tensor_done),
        .result (tensor_result)
    );

    // -------------------------------------------------------
    // Execution Unit (combinational ALU)
    // [FIX 4] BRANCH uses word-index offset (no <<2)
    // -------------------------------------------------------
    wire signed [15:0] a0=rs1_data[15:0],  a1=rs1_data[31:16],
                       a2=rs1_data[47:32], a3=rs1_data[63:48];
    wire signed [15:0] b0=rs2_data[15:0],  b1=rs2_data[31:16],
                       b2=rs2_data[47:32], b3=rs2_data[63:48];

    reg [63:0] alu_result;
    always @(*) begin
        case (opcode)
            `OP_ADD_I16:  alu_result = {a3+b3, a2+b2, a1+b1, a0+b0};
            `OP_SUB_I16:  alu_result = {a3-b3, a2-b2, a1-b1, a0-b0};
            `OP_CMP_I16:  alu_result = {63'd0, (a0 < b0)}; // flag in [0]
            `OP_RELU:     alu_result = {(a3>0?a3:16'd0),(a2>0?a2:16'd0),
                                        (a1>0?a1:16'd0),(a0>0?a0:16'd0)};
            `OP_LDI:      alu_result = imm_sext;
            `OP_READ_TID: alu_result = 64'd0;        // single thread
            `OP_LD64:     alu_result = rs1_data + imm_sext; // byte addr
            `OP_ST64:     alu_result = rs1_data + imm_sext; // byte addr
            default:      alu_result = 64'd0;
        endcase
    end

    // -------------------------------------------------------
    // [FIX 5] cmp_flag register — set by CMP_I16, used by BRANCH
    // Replaces rs1_data[0] hack with proper flag register
    // -------------------------------------------------------
    reg cmp_flag;

    // -------------------------------------------------------
    // LD/ST Unit — actually instantiated (gpu_ldst.v)
    // -------------------------------------------------------
    reg  [31:0] ldst_byte_addr;
    reg  [63:0] ldst_st_data;
    reg         ldst_st_en;

    wire [7:0]  ld_bram_addr;
    wire [63:0] ld_data;
    wire [7:0]  st_bram_addr;
    wire [71:0] st_bram_wdata;
    wire        st_bram_we;

    gpu_ldst ldst_inst (
        .ld_byte_addr  (ldst_byte_addr),
        .rd_bram_addr  (ld_bram_addr),
        .bram_rdata    (bram_rdata),
        .ld_data       (ld_data),
        .st_byte_addr  (ldst_byte_addr),
        .st_data       (ldst_st_data),
        .wr_bram_addr  (st_bram_addr),
        .wr_bram_wdata (st_bram_wdata),
        .wr_bram_we    (st_bram_we),
        .st_en         (ldst_st_en)
    );

    // BRAM interface MUX: ST or LD address
    assign bram_addr  = ldst_st_en ? st_bram_addr  : ld_bram_addr;
    assign bram_wdata = st_bram_wdata;
    assign bram_we    = st_bram_we;

    // -------------------------------------------------------
    // Intermediate result register
    // -------------------------------------------------------
    reg [63:0] exec_result;

    // -------------------------------------------------------
    // FSM — PC advances only after instruction completes
    // -------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= S_IDLE;
            pc             <= 5'd0;
            done           <= 1'b0;
            running        <= 1'b0;
            instr_reg      <= 32'd0;
            exec_result    <= 64'd0;
            ldst_byte_addr <= 32'd0;
            ldst_st_data   <= 64'd0;
            ldst_st_en     <= 1'b0;
            rf_we          <= 1'b0;
            tensor_start   <= 1'b0;
            cmp_flag       <= 1'b0;
        end else begin
            // Default: clear one-cycle pulses
            rf_we        <= 1'b0;
            ldst_st_en   <= 1'b0;
            tensor_start <= 1'b0;

            case (state)
                // ----------------------------------------
                S_IDLE: begin
                    done    <= 1'b0;
                    running <= 1'b0;
                    pc      <= 5'd0;
                    if (start) begin
                        state   <= S_FETCH;
                        running <= 1'b1;
                    end
                end

                // ----------------------------------------
                // FETCH: latch instr at current PC (PC frozen)
                S_FETCH: begin
                    if (pc >= PROG_LEN) begin
                        state <= S_DONE;
                    end else begin
                        instr_reg <= instr_from_mem;
                        state     <= S_DECODE;
                    end
                end

                // ----------------------------------------
                // DECODE: issue regfile reads (result next cycle)
                S_DECODE: begin
                    state <= S_EXEC;
                end

                // ----------------------------------------
                // EXEC: compute, issue mem/branch ops
                S_EXEC: begin
                    case (opcode)
                        `OP_BF_MAC: begin
                            tensor_start <= 1'b1;
                            state        <= S_MEM;
                        end
                        `OP_LD64: begin
                            ldst_byte_addr <= alu_result[31:0];
                            state          <= S_MEM;
                        end
                        `OP_ST64: begin
                            // [FIX 3] store Rd value (rd_src_data), not rs2
                            ldst_byte_addr <= alu_result[31:0];
                            ldst_st_data   <= rd_src_data;
                            ldst_st_en     <= 1'b1;
                            pc    <= pc + 5'd1;
                            state <= S_FETCH;
                        end
                        `OP_CMP_I16: begin
                            // [FIX 5] set cmp_flag from lane 0 comparison
                            cmp_flag <= alu_result[0];
                            pc    <= pc + 5'd1;
                            state <= S_FETCH;
                        end
                        `OP_BRANCH: begin
                            // Word-index branch: pc = pc + signed(imm18[4:0])
                            // PC is instruction index (matches gpu_imem_rom case(pc))
                            // Sign bit = imm18[4], offset range = -16 to +15 instrs
                            if (cmp_flag)
                                pc <= pc + $signed(imm18[4:0]);
                            else
                                pc <= pc + 5'd1;
                            state <= S_FETCH;
                        end
                        `OP_NOP: begin
                            pc    <= pc + 5'd1;
                            state <= S_FETCH;
                        end
                        default: begin
                            exec_result <= alu_result;
                            state       <= S_WB;
                        end
                    endcase
                end

                // ----------------------------------------
                // MEM: tensor wait or LD64 BRAM addr setup
                // For LD64: S_EXEC sets ldst_byte_addr (register).
                // BRAM sees address at start of S_MEM, but sync read
                // means data is valid at END of S_MEM (i.e. next cycle).
                // So we stay S_MEM one cycle (addr setup), then S_MEM2
                // to capture the now-valid bram_rdata.
                S_MEM: begin
                    if (opcode == `OP_BF_MAC) begin
                        if (tensor_done) begin
                            exec_result <= tensor_result;
                            state       <= S_WB;
                        end
                        // else: stay, wait for tensor
                    end else begin
                        // LD64: address presented to BRAM this cycle.
                        // Data will be valid next cycle → go to S_MEM2.
                        state <= S_MEM2;
                    end
                end

                // ----------------------------------------
                // MEM2: capture BRAM read data (now valid after 1-cycle latency)
                S_MEM2: begin
                    exec_result <= ld_data;
                    state       <= S_WB;
                end

                // ----------------------------------------
                // WB: write result to regfile, advance PC
                S_WB: begin
                    if (rd_addr != 3'd0) begin
                        rf_we      <= 1'b1;
                        rf_wr_addr <= rd_addr;
                        rf_wr_data <= exec_result;
                    end
                    pc    <= pc + 5'd1;
                    state <= S_FETCH;
                end

                // ----------------------------------------
                S_DONE: begin
                    done    <= 1'b1;
                    running <= 1'b0;
                    if (start) begin
                        state <= S_IDLE;
                        done  <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
