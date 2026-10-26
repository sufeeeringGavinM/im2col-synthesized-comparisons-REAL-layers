`timescale 1ns / 1ps

// Synchronous-read pseudo-dual-port (1W1R) SRAM model matching SKY130 OpenRAM macro behavior
// LOCAL SRAM MODEL: one word write and one synchronous word read.
// A read consumes an edge before its value is available; callers align enables
// and addresses accordingly. This storage has no reset that clears its contents.
// DATA_WIDTH describes a word: a FIFO input word can contain BUS_WORDS operands.
module row_sram #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 8,
    parameter integer DEPTH = 1 << ADDR_WIDTH
) (
    input  wire                  clk,
    input  wire                  we,
    input  wire                  read_enable,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output reg  [DATA_WIDTH-1:0] rdata
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        if (read_enable) rdata <= mem[raddr];
    end

endmodule
