`timescale 1ns/1ps
// ============================================================
// gpu_net.v — Adapter layer: fifo_top ↔ gpu_core_min
//
// Presents the EXACT same interface as Lab 8 gpu_net.v so that
// fifo_top.v does not need ANY modification.
//
// fifo_top.v (Lab 8, unchanged) instantiates:
//   gpu_net gpu_inst (
//     .clk(clk), .rst_n(~reset),
//     .start(gpu_start), .done(gpu_done), .running(gpu_running),
//     .bram_addr(gpu_bram_addr),    [7:0]  output
//     .bram_wdata(gpu_bram_wdata),  [71:0] output
//     .bram_rdata(proc_rdata),      [71:0] input
//     .bram_we(gpu_bram_we)         output
//   );
//
// Internally routes to gpu_core_min which runs the programmable
// bf16_fma kernel using the GPU group's ISA + bf16_mac.
// ============================================================
module gpu_net (
    input  wire        clk,
    input  wire        rst_n,       // active-low from fifo_top

    // Control (Lab 8 interface — unchanged)
    input  wire        start,
    output wire        done,
    output wire        running,

    // Shared BRAM interface (Lab 8 interface — unchanged)
    output wire [7:0]  bram_addr,
    output wire [71:0] bram_wdata,
    input  wire [71:0] bram_rdata,
    output wire        bram_we
);
    // Convert active-low rst to active-high for gpu_core_min
    wire rst = ~rst_n;

    // Instantiate the programmable GPU core
    gpu_core_min gpu_core (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .done      (done),
        .running   (running),
        .bram_addr (bram_addr),
        .bram_wdata(bram_wdata),
        .bram_we   (bram_we),
        .bram_rdata(bram_rdata)
    );

endmodule
