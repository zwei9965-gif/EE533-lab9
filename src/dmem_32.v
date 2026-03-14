`timescale 1ns / 1ps
// dmem_32.v — Data Memory, Lab 9
// 256 x 32-bit true dual-port BRAM
// (* RAM_STYLE = "BLOCK" *) explicitly forces BRAM inference
// Standard synchronous read/write template — XST infers RAMB16

module dmem_32 (
    input  wire        clka,
    input  wire        wea,
    input  wire [7:0]  addra,
    input  wire [31:0] dina,
    output reg  [31:0] douta,
    input  wire        clkb,
    input  wire        web,
    input  wire [7:0]  addrb,
    input  wire [31:0] dinb,
    output reg  [31:0] doutb
);
    (* RAM_STYLE = "BLOCK" *)
    reg [31:0] mem [0:255];

    always @(posedge clka) begin
        if (wea) mem[addra] <= dina;
        douta <= mem[addra];
    end

    always @(posedge clkb) begin
        if (web) mem[addrb] <= dinb;
        doutb <= mem[addrb];
    end
endmodule
