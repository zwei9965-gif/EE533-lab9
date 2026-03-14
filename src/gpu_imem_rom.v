`timescale 1ns/1ps
// ============================================================
// gpu_imem_rom.v — GPU Instruction Memory (independent from ARM)
// Lab 7: own instruction memory, independent from ARM processor
// Encodes bf16_fma kernel (GPU group's hex program):
//   0: READ_TID  R1          — R1 = thread_id (=0)
//   1: LD64 R2, R0, 0        — R2 = dmem[0]  Vec A
//   2: LD64 R3, R0, 8        — R3 = dmem[8]  Vec B
//   3: LD64 R4, R0, 16       — R4 = dmem[16] Vec C
//   4: BF_MAC R5, R2, R3, R4 — R5 = A*B+C
//   5: ST64 R5, R1, 0        — dmem[0] = R5
// ============================================================
module gpu_imem_rom (
    input  wire [4:0]  pc,
    output reg  [31:0] instr
);
    always @(*) begin
        case (pc)
            5'd0: instr = 32'h04400000; // READ_TID  R1
            5'd1: instr = 32'h0C800000; // LD64 R2, R0, 0
            5'd2: instr = 32'h0CC00008; // LD64 R3, R0, 8
            5'd3: instr = 32'h0D000010; // LD64 R4, R0, 16
            5'd4: instr = 32'h8548D000; // BF_MAC R5, R2, R3, R4
            5'd5: instr = 32'h11440000; // ST64 R5, R1, 0
            default: instr = 32'h00000000; // NOP / halt
        endcase
    end
endmodule
